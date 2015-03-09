package PVE::HA::LRM;

# Local Resource Manager

use strict;
use warnings;
use Data::Dumper;
use POSIX qw(:sys_wait_h);

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::HA::Tools;

# Server can have several states:

my $valid_states = {
    wait_for_agent_lock => "waiting for agnet lock",
    active => "got agent_lock",
    lost_agent_lock => "lost agent_lock",
};

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	haenv => $haenv,
	status => { state => 'startup' },
	workers => {},
	results => {},
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

    $haenv->log('info', "status change $old->{state} => $new->{state}");

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
	    if ($self->get_protected_ha_agent_lock()) {
		$self->set_local_status({ state => 'active' });
	    }
	}
	
    } elsif ($state eq 'lost_agent_lock') {

	if ($haenv->quorate()) {
	    if ($self->get_protected_ha_agent_lock()) {
		$self->set_local_status({ state => 'active' });
	    }
	}

    } elsif ($state eq 'active') {

	if (!$self->get_protected_ha_agent_lock()) {
	    $self->set_local_status({ state => 'lost_agent_lock'});
	}
    }

    $status = $self->get_local_status();
    $state = $status->{state};

    # do work

    $self->{service_status} = {};

    if ($state eq 'wait_for_agent_lock') {

	return 0 if $self->{shutdown_request};

	$haenv->sleep(5);
	   
    } elsif ($state eq 'active') {

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
	    } else {
		my $ms = $haenv->read_manager_status();

		$self->{service_status} =  $ms->{service_status} || {};

		$self->manage_resources();
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

sub manage_resources {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $nodename = $haenv->nodename();

    my $ms = $haenv->read_manager_status();

    my $ss = $self->{service_status};

    foreach my $sid (keys %$ss) {
	my $sd = $ss->{$sid};
	next if !$sd->{node};
	next if !$sd->{uid};
	next if $sd->{node} ne $nodename;
	my $req_state = $sd->{state};
	next if !defined($req_state);

	eval {
	    $self->queue_resource_command($sid, $sd->{uid}, $req_state, $sd->{target});
	};
	if (my $err = $@) {
	    warn "unable to run resource agent for '$sid' - $err"; # fixme
	}
    }

    my $starttime = time();

    # start workers
    my $max_workers = 4;

    while ((time() - $starttime) < 5) {
	my $count =  $self->check_active_workers();

	foreach my $sid (keys %{$self->{workers}}) {
	    last if $count >= $max_workers;
	    my $w = $self->{workers}->{$sid};
	    if (!$w->{pid}) {
		my $pid = fork();
		if (!defined($pid)) {
		    warn "fork worker failed\n";
		    $count = 0; last; # abort, try later
		} elsif ($pid == 0) {
		    # do work
		    my $res = -1;
		    eval {
			$res = $haenv->exec_resource_agent($sid, $w->{state}, $w->{target});
		    };
		    if (my $err = $@) {
			warn $err;
			POSIX::_exit(-1);
		    }  
		    POSIX::_exit($res); 
		} else {
		    $count++;
		    $w->{pid} = $pid;
		}
	    }
	}

	last if !$count;

	sleep(1);
    }
}

# fixme: use a queue an limit number of parallel workers?
sub queue_resource_command {
    my ($self, $sid, $uid, $state, $target) = @_;

    if (my $w = $self->{workers}->{$sid}) {
	return if $w->{pid}; # already started
	# else, delete and overwrite queue entry with new command
	delete $self->{workers}->{$sid};
    }

    $self->{workers}->{$sid} = {
	sid => $sid,
	uid => $uid,
	state => $state,
    };

    $self->{workers}->{$sid}->{target} = $target if $target;
}

sub check_active_workers {
    my ($self) = @_;

    # finish/count workers
    my $count = 0;
    foreach my $sid (keys %{$self->{workers}}) {
	my $w = $self->{workers}->{$sid};
	if (my $pid = $w->{pid}) {
	    # check status
	    my $waitpid = waitpid($pid, WNOHANG);
	    if (defined($waitpid) && ($waitpid == $pid)) {
		$self->resource_command_finished($sid, $w->{uid}, $?);
	    } else {
		$count++;
	    }
	}
    }
    
    return $count;
}

sub resource_command_finished {
    my ($self, $sid, $uid, $status) = @_;

    my $haenv = $self->{haenv};

    my $w = delete $self->{workers}->{$sid};
    return if !$w; # should not happen

    my $exit_code = -1;

    if ($status == -1) {
	$haenv->log('err', "resource agent $sid finished - failed to execute");    
    }  elsif (my $sig = ($status & 127)) {
	$haenv->log('err', "resource agent $sid finished - got signal $sig");
    } else {
	$exit_code = ($status >> 8);
    }

    $self->{results}->{$uid} = {
	sid => $w->{sid},
	state => $w->{state},
	exit_code => $exit_code,
    };

    my $ss = $self->{service_status};

    # compute hash of valid/existing uids
    my $valid_uids = {};
    foreach my $sid (keys %$ss) {
	my $sd = $ss->{$sid};
	next if !$sd->{uid};
	$valid_uids->{$sd->{uid}} = 1;
    }

    my $results = {};
    foreach my $id (keys %{$self->{results}}) {
	next if !$valid_uids->{$id};
	$results->{$id} = $self->{results}->{$id};
    }
    $self->{results} = $results;

    $haenv->write_lrm_status($results);
}

1;
