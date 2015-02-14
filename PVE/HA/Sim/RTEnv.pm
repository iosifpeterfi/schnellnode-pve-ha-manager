package PVE::HA::Sim::RTEnv;

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

    return $self;
}

sub get_time {
    my ($self) = @_;

    return time();
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    my $time = $self->get_time();

    printf("%-5s %10s %12s: $msg\n", $level, strftime("%H:%M:%S", localtime($time)), 
	   "$self->{nodename}/$self->{log_id}");
}

sub sleep {
    my ($self, $delay) = @_;

    CORE::sleep($delay);
}

sub sleep_until {
   my ($self, $end_time) = @_;

   for (;;) {
       my $cur_time = time();

       last if $cur_time >= $end_time;

       $self->sleep(1);
   }
}

sub loop_start_hook {
    my ($self) = @_;

    $self->{loop_start} = $self->get_time();
}

sub loop_end_hook {
    my ($self) = @_;

    my $delay = $self->get_time() - $self->{loop_start};
 
    die "loop take too long ($delay seconds)\n" if $delay > 30;
}

sub exec_resource_agent {
    my ($self, $sid, $cmd, @params) = @_;

    my $hardware = $self->{hardware};

    my $ss = $hardware->read_service_status();

    if ($cmd eq 'request_stop') {

	if (!$ss->{$sid}) {
	    print "WORKER status $sid: stopped\n";
	    return 0;
	} else {
	    print "WORKER status $sid: running\n";
	    return 1;
	}

    } elsif ($cmd eq 'start') {

	if ($ss->{$sid}) {
	    print "WORKER status $sid: running\n";
	    return 0;
	}
	print "START WORKER $sid\n";
	
	$self->sleep(2);

	$ss->{$sid} = 1;
	$hardware->write_service_status($ss);

	print "END WORKER $sid\n";

	return 0;

    } elsif ($cmd eq 'stop') {

	if (!$ss->{$sid}) {
	    print "WORKER status $sid: stopped\n";
	    return 0;
	}
	print "STOP WORKER $sid\n";
	
	$self->sleep(2);

	$ss->{$sid} = 0;
	$hardware->write_service_status($ss);

	print "END WORKER $sid\n";

	return 0;
    } 

    die "implement me";
}

1;
