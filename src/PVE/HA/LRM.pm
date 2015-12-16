package PVE::HA::LRM;

# Local Resource Manager

use strict;
use warnings;
use Data::Dumper;
use POSIX qw(:sys_wait_h);

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::HA::Tools ':exit_codes';

# Server can have several states:

my $valid_states = {
    wait_for_agent_lock => "waiting for agent lock",
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
	restart_tries => {},
	shutdown_request => 0,
	# mode can be: active, reboot, shutdown, restart
	mode => 'active',
    }, $class;

    $self->set_local_status({ state => 	'wait_for_agent_lock' });   

    return $self;
}

sub shutdown_request {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $shutdown = $haenv->is_poweroff();

    if ($shutdown) {
	$haenv->log('info', "shutdown LRM, stop all services");
	$self->{mode} = 'shutdown';
    } else {
	$haenv->log('info', "restart LRM, freeze all services");
	$self->{mode} = 'restart';
    }

    $self->{shutdown_request} = 1;

    eval { $self->update_lrm_status(); };
    if (my $err = $@) {
	$self->log('err', "unable to update lrm status file - $err");
    }
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

sub update_lrm_status {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    return 0 if !$haenv->quorate();
    
    my $lrm_status = {	
	mode => $self->{mode},
	results => $self->{results},
	timestamp => $haenv->get_time(),
    };
    
    eval { $haenv->write_lrm_status($lrm_status); };
    if (my $err = $@) {
	$haenv->log('err', "unable to write lrm status file - $err");
	return 0;
    }

    return 1;
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

sub active_service_count {
    my ($self) = @_;
    
    my $haenv = $self->{haenv};

    my $nodename = $haenv->nodename();

    my $ss = $self->{service_status};

    my $count = 0;
    
    foreach my $sid (keys %$ss) {
	my $sd = $ss->{$sid};
	next if !$sd->{node};
	next if $sd->{node} ne $nodename;
	my $req_state = $sd->{state};
	next if !defined($req_state);
	next if $req_state eq 'stopped';
	next if $req_state eq 'freeze';

	$count++;
    }
    
    return $count;
}

my $wrote_lrm_status_at_startup = 0;

sub do_one_iteration {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    if (!$wrote_lrm_status_at_startup) {
	if ($self->update_lrm_status()) {
	    $wrote_lrm_status_at_startup = 1;
	} else {
	    # do nothing
	    $haenv->sleep(5);
	    return $self->{shutdown_request} ? 0 : 1;
	}
    }
    
    my $status = $self->get_local_status();
    my $state = $status->{state};

    my $ms = $haenv->read_manager_status();
    $self->{service_status} =  $ms->{service_status} || {};

    my $fence_request = PVE::HA::Tools::count_fenced_services($self->{service_status}, $haenv->nodename());
    
    # do state changes first 

    my $ctime = $haenv->get_time();

    if ($state eq 'wait_for_agent_lock') {

	my $service_count = $self->active_service_count();

	if (!$fence_request && $service_count && $haenv->quorate()) {
	    if ($self->get_protected_ha_agent_lock()) {
		$self->set_local_status({ state => 'active' });
	    }
	}
	
    } elsif ($state eq 'lost_agent_lock') {

	if (!$fence_request && $haenv->quorate()) {
	    if ($self->get_protected_ha_agent_lock()) {
		$self->set_local_status({ state => 'active' });
	    }
	}

    } elsif ($state eq 'active') {

	if ($fence_request) {		
	    $haenv->log('err', "node need to be fenced - releasing agent_lock\n");
	    $self->set_local_status({ state => 'lost_agent_lock'});	
	} elsif (!$self->get_protected_ha_agent_lock()) {
	    $self->set_local_status({ state => 'lost_agent_lock'});
	}
    }

    $status = $self->get_local_status();
    $state = $status->{state};

    # do work

    if ($state eq 'wait_for_agent_lock') {

	return 0 if $self->{shutdown_request};
	
	$self->update_lrm_status();
	
	$haenv->sleep(5);
	   
    } elsif ($state eq 'active') {

	my $startime = $haenv->get_time();

	my $max_time = 10;

	my $shutdown = 0;

	# do work (max_time seconds)
	eval {
	    # fixme: set alert timer

	    if ($self->{shutdown_request}) {

		if ($self->{mode} eq 'restart') {

		    my $service_count = $self->active_service_count();

		    if ($service_count == 0) {

			if ($self->{ha_agent_wd}) {
			    $haenv->watchdog_close($self->{ha_agent_wd});
			    delete $self->{ha_agent_wd};
			}

			$shutdown = 1;
		    }
		} else {
		    # fixme: stop all services
		    $shutdown = 1;
		}
	    } else {

		$self->manage_resources();

	    }
	};
	if (my $err = $@) {
	    $haenv->log('err', "got unexpected error - $err");
	}

	$self->update_lrm_status();
	
	return 0 if $shutdown;

	$haenv->sleep_until($startime + $max_time);

    } elsif ($state eq 'lost_agent_lock') {
	
	# Note: watchdog is active an will triger soon!

	# so we hope to get the lock back soon!

	if ($self->{shutdown_request}) {

	    my $service_count = $self->active_service_count();

	    if ($service_count > 0) {
		$haenv->log('err', "get shutdown request in state 'lost_agent_lock' - " . 
			    "detected $service_count running services");

	    } else {

		# all services are stopped, so we can close the watchdog

		if ($self->{ha_agent_wd}) {
		    $haenv->watchdog_close($self->{ha_agent_wd});
		    delete $self->{ha_agent_wd};
		}
		
		return 0;
	    }
	}

	$haenv->sleep(5);

    } else {

	die "got unexpected status '$state'\n";

    }

    return 1;
}

sub manage_resources {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $nodename = $haenv->nodename();

    my $ss = $self->{service_status};

    foreach my $sid (keys %$ss) {
	my $sd = $ss->{$sid};
	next if !$sd->{node};
	next if !$sd->{uid};
	next if $sd->{node} ne $nodename;
	my $req_state = $sd->{state};
	next if !defined($req_state);
	next if $req_state eq 'freeze';
	eval {
	    $self->queue_resource_command($sid, $sd->{uid}, $req_state, $sd->{target});
	};
	if (my $err = $@) {
	    $haenv->log('err', "unable to run resource agent for '$sid' - $err"); # fixme
	}
    }

    my $starttime = $haenv->get_time();

    # start workers
    my $max_workers = 4;

    my $sc = $haenv->read_service_config();

    while (($haenv->get_time() - $starttime) < 5) {
	my $count =  $self->check_active_workers();

	foreach my $sid (keys %{$self->{workers}}) {
	    last if $count >= $max_workers;
	    my $w = $self->{workers}->{$sid};
	    my $cd = $sc->{$sid};
	    if (!$cd) {
		$haenv->log('err', "missing resource configuration for '$sid'");
		next;
	    }
	    if (!$w->{pid}) {
		if ($haenv->can_fork()) {
		    my $pid = fork();
		    if (!defined($pid)) {
			$haenv->log('err', "fork worker failed");
			$count = 0; last; # abort, try later
		    } elsif ($pid == 0) {
			# do work
			my $res = -1;
			eval {
			    $res = $haenv->exec_resource_agent($sid, $cd, $w->{state}, $w->{target});
			};
			if (my $err = $@) {
			    $haenv->log('err', $err);
			    POSIX::_exit(-1);
			}  
			POSIX::_exit($res); 
		    } else {
			$count++;
			$w->{pid} = $pid;
		    }
		} else {
		    my $res = -1;
		    eval {
			$res = $haenv->exec_resource_agent($sid, $cd, $w->{state}, $w->{target});
		    };
		    if (my $err = $@) {
			$haenv->log('err', $err);
		    }		    
		    $self->resource_command_finished($sid, $w->{uid}, $res);
		}
	    }
	}

	last if !$count;

	$haenv->sleep(1);
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

    $exit_code = $self->handle_service_exitcode($sid, $w->{state}, $exit_code);

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
}

# processes the exit code from a finished resource agent, so that the CRM knows
# if the LRM wants to retry an action based on the current recovery policies for
# the failed service, or the CRM itself must try to recover from the failure.
sub handle_service_exitcode {
    my ($self, $sid, $cmd, $exit_code) = @_;

    my $haenv = $self->{haenv};
    my $tries = $self->{restart_tries};

    my $sc = $haenv->read_service_config();
    my $cd = $sc->{$sid};

    if ($cmd eq 'started') {

	if ($exit_code == SUCCESS) {

	    $tries->{$sid} = 0;

	    return $exit_code;

	} elsif ($exit_code == ERROR) {

	    $tries->{$sid} = 0 if !defined($tries->{$sid});

	    $tries->{$sid}++;
	    if ($tries->{$sid} >= $cd->{max_restart}) {
		$haenv->log('err', "unable to start service $sid on local node".
			   " after $tries->{$sid} retries");
		$tries->{$sid} = 0;
		return ERROR;
	    }

	    # tell CRM that we retry the start
	    return ETRY_AGAIN;
	}
    }

    return $exit_code;

}

1;
