package PVE::HA::Sim::TestEnv;

use strict;
use warnings;
use POSIX qw(strftime EINTR);
use Data::Dumper;
use JSON; 
use IO::File;
use Fcntl qw(:DEFAULT :flock);

use PVE::HA::Tools;

use base qw(PVE::HA::Sim::Env);

sub new {
    my ($this, $nodename, $hardware, $log_id) = @_;
    
    my $class = ref($this) || $this;

    my $self = $class->SUPER::new($nodename, $hardware, $log_id);

    $self->{cur_time} = 0;
    $self->{loop_delay} = 0;

    my $statusdir = $self->{hardware}->statusdir();
    my $logfile = "$statusdir/log";
    $self->{logfh} = IO::File->new(">>$logfile") ||
	die "unable to open '$logfile' - $!";

    return $self;
}

sub get_time {
    my ($self) = @_;

    return $self->{cur_time};
}

sub log {
    my ($self, $level, $msg) = @_;

    return if $level eq 'debug';

    chomp $msg;

    my $time = $self->get_time();
    $level = substr( $level, 0, 4 );

    my $line = sprintf("%-5s %5d %12s: $msg\n", $level, $time, "$self->{nodename}/$self->{log_id}");
    print $line;
    
    $self->{logfh}->print($line);
    $self->{logfh}->flush();
}

sub sleep {
   my ($self, $delay) = @_;

   $self->{loop_delay} += $delay;
}

sub sleep_until {
   my ($self, $end_time) = @_;

   my $cur_time = $self->{cur_time} + $self->{loop_delay};

   return if $cur_time >= $end_time;

   $self->{loop_delay} += $end_time - $cur_time;
}

sub get_ha_manager_lock {
    my ($self) = @_;

    my $res = $self->SUPER::get_ha_manager_lock();
    ++$self->{loop_delay};
    return $res;
}

sub get_ha_agent_lock {
    my ($self, $node) = @_;

    my $res = $self->SUPER::get_ha_agent_lock($node);
    ++$self->{loop_delay};

    return $res;
}

sub loop_start_hook {
    my ($self, $starttime) = @_;

    $self->{loop_delay} = 0;

    die "no starttime" if !defined($starttime);
    die "strange start time" if $starttime < $self->{cur_time};

    $self->{cur_time} = $starttime;

    # do nothing
}

sub loop_end_hook {
    my ($self) = @_;

    my $delay = $self->{loop_delay};
    $self->{loop_delay} = 0;

    die "loop take too long ($delay seconds)\n" if $delay > 30;

    # $self->{cur_time} += $delay;

    $self->{cur_time} += 1; # easier for simulation
}

sub is_node_shutdown {
    my ($self) = @_;

    my $node = $self->{nodename};
    my $cstatus = $self->{hardware}->read_hardware_status_nolock();

    die "undefined node status for node '$node'" if !defined($cstatus->{$node});

    return defined($cstatus->{$node}->{shutdown}) ? 1 : 0;
}

# must be 0 as we do not want to fork in the regression tests
sub get_max_workers {
    my ($self) = @_;

    return 0;
}

1;
