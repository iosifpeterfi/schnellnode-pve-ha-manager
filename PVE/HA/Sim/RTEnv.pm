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

    my $nodename = $self->{nodename};

    my $sc = $hardware->read_service_config($nodename);

    # fixme: return valid_exit code (instead of using die)
    my $cd = $sc->{$sid};
    die "no such service" if !$cd;

    my $ss = $hardware->read_service_status($nodename);

    if ($cmd eq 'started') {

	# fixme: return valid_exit code
	die "service '$sid' not on this node" if $cd->{node} ne $nodename;

	if ($ss->{$sid}) {
	    $self->log("info", "service status $sid: running");
	    return 0;
	}
	$self->log("info", "starting service $sid");
	
	$self->sleep(2);

	$ss->{$sid} = 1;
	$hardware->write_service_status($nodename, $ss);

	$self->log("info", "service $sid started");

	return 0;

    } elsif ($cmd eq 'request_stop' || $cmd eq 'stopped') {

	# fixme: return valid_exit code
	die "service '$sid' not on this node" if $cd->{node} ne $nodename;

	if (!$ss->{$sid}) {
	    $self->log("info", "service status $sid: stopped");
	    return 0;
	}
	$self->log("info", "stopping service $sid");
	
	$self->sleep(2);

	$ss->{$sid} = 0;
	$hardware->write_service_status($nodename, $ss);

	$self->log("info", "service $sid stopped");

	return 0;

    } elsif ($cmd eq 'migrate') {

	my $target = $params[0];
	die "migrate '$sid' failed - missing target\n" if !defined($target);

	if ($cd->{node} eq $target) {
	    # already migrate
	    return 0;
	} elsif ($cd->{node} eq $nodename) {

	    $self->log("info", "service $sid - start migrtaion to node '$target'");
	    $self->sleep(2);
	    $self->change_service_location($sid, $target);
	    $self->log("info", "service $sid - end migrtaion to node '$target'");

	    return 0;

	} else {
	    die "migrate '$sid'  failed - service is not on this node\n";
	}
	
	
    }

    die "implement me (cmd '$cmd')";
}

1;
