package PVE::HA::LRM;

# Local Resource Manager

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::HA::Tools;

# Server can have several states:

my $valid_states = {
    wait_for_agent_lock => "waiting for agnet lock",
    locked => "got agent_lock",
    lost_agent_lock => "lost agent_lock",
};

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	haenv => $haenv,
	status => { state => 'startup' },
    }, $class;

    $self->set_local_status({ state => 'wait_for_agent_lock' });   
    
    return $self;
}

sub shutdown_request {
    my ($self) = @_;

    $self->{shutdown_request} = 1;
}

sub get_local_status {
    my ($self) = @_;

    return $self->{status};
}

sub set_local_status {
    my ($self, $new) = @_;

    die "invalid state '$new->{state}'" if !$valid_states->{$new->{state}};

    my $haenv = $self->{haenv};

    my $old = $self->{status};

    # important: only update if if really changed 
    return if $old->{state} eq $new->{state};

    $haenv->log('info', "LRM status change $old->{state} => $new->{state}");

    $new->{state_change_time} = $haenv->get_time();

    $self->{status} = $new;
}

sub get_protected_ha_agent_lock {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $count = 0;
    my $starttime = $haenv->get_time();

    for (;;) {
	
	if ($haenv->get_ha_agent_lock()) {
	    if ($self->{ha_agent_wd}) {
		$haenv->watchdog_update($self->{ha_agent_wd});
	    } else {
		my $wfh = $haenv->watchdog_open();
		$self->{ha_agent_wd} = $wfh;
	    }
	    return 1;
	}
	    
	last if ++$count > 5; # try max 5 time

	my $delay = $haenv->get_time() - $starttime;
	last if $delay > 5; # for max 5 seconds

	$haenv->sleep(1);
    }
    
    return 0;
}

sub do_one_iteration {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $status = $self->get_local_status();
    my $state = $status->{state};

    # do state changes first 

    my $ctime = $haenv->get_time();

    if ($state eq 'wait_for_agent_lock') {

	my $service_count = 1; # todo: correctly compute

	if ($service_count && $haenv->quorate()) {
	    if ($self->get_protectedt_ha_agent_lock()) {
		$self->set_local_status({ state => 'locked' });
	    }
	}
	
    } elsif ($state eq 'lost_agent_lock') {

	if ($haenv->quorate()) {
	    if ($self->get_protectedt_ha_agent_lock()) {
		$self->set_local_status({ state => 'locked' });
	    }
	}

    } elsif ($state eq 'locked') {

	if (!$self->get_protectedt_ha_agent_lock()) {
	    $self->set_local_status({ state => 'lost_agent_lock'});
	}
    }

    $status = $self->get_local_status();
    $state = $status->{state};

    # do work

    if ($state eq 'wait_for_agent_lock') {

	return 0 if $self->{shutdown_request};

	$haenv->sleep(5);
	   
    } elsif ($state eq 'locked') {

	my $startime = $haenv->get_time();

	my $max_time = 10;

	my $shutdown = 0;

	# do work (max_time seconds)
	eval {
	    # fixme: set alert timer

	    if ($self->{shutdown_request}) {

		# fixme: request service stop or relocate ?

		my $service_count = 0; # fixme

		if ($service_count == 0) {

		    if ($self->{ha_agent_wd}) {
			$haenv->watchdog_close($self->{ha_agent_wd});
			delete $self->{ha_agent_wd};
		    }

		    $shutdown = 1;
		}
	    }
	};
	if (my $err = $@) {
	    $haenv->log('err', "got unexpected error - $err");
	}

	return 0 if $shutdown;

	$haenv->sleep_until($startime + $max_time);

    } elsif ($state eq 'lost_agent_lock') {
	
	# Note: watchdog is active an will triger soon!

	# so we hope to get the lock back soon!

	if ($self->{shutdown_request}) {

	    my $running_services = 0; # fixme: correctly compute

	    if ($running_services > 0) {
		$haenv->log('err', "get shutdown request in state 'lost_agent_lock' - " . 
			    "killing running services");

		# fixme: kill all services as fast as possible
	    }

	    # now all services are stopped, so we can close the watchdog

	    if ($self->{ha_agent_wd}) {
		$haenv->watchdog_close($self->{ha_agent_wd});
		delete $self->{ha_agent_wd};
	    }

	    return 0;
	}

    } else {

	die "got unexpected status '$state'\n";

    }

    return 1;
}

1;
