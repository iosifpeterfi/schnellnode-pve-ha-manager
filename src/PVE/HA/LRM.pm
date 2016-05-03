package PVE::HA::LRM;

# Local Resource Manager

use strict;
use warnings;
use Data::Dumper;
use POSIX qw(:sys_wait_h);

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::HA::Tools ':exit_codes';
use PVE::HA::Resources;

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
	shutdown_errors => 0,
	# mode can be: active, reboot, shutdown, restart
	mode => 'active',
    }, $class;

    $self->set_local_status({ state => 	'wait_for_agent_lock' });   

    return $self;
}

sub shutdown_request {
    my ($self) = @_;

    return if $self->{shutdown_request}; # already in shutdown mode

    my $haenv = $self->{haenv};

    my $nodename = $haenv->nodename();

    my $shutdown = $haenv->is_node_shutdown();

    if ($shutdown) {
	$haenv->log('info', "shutdown LRM, stop all services");
	$self->{mode} = 'shutdown';

	# queue stop jobs for all services

	my $ss = $self->{service_status};

	foreach my $sid (keys %$ss) {
	    my $sd = $ss->{$sid};
	    next if !$sd->{node};
	    next if $sd->{node} ne $nodename;
	    # Note: use undef uid to mark shutdown/stop jobs
	    $self->queue_resource_command($sid, undef, 'request_stop');
	}

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
	state => $self->{status}->{state},
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

			if ($self->run_workers() == 0) {
			    if ($self->{ha_agent_wd}) {
				$haenv->watchdog_close($self->{ha_agent_wd});
				delete $self->{ha_agent_wd};
			    }

			    $shutdown = 1;

			    # restart with no or freezed services, release the lock
			    $haenv->release_ha_agent_lock();
			}
		    }
		} else {

		    if ($self->run_workers() == 0) {
			if ($self->{shutdown_errors} == 0) {
			    if ($self->{ha_agent_wd}) {
				$haenv->watchdog_close($self->{ha_agent_wd});
				delete $self->{ha_agent_wd};
			    }

			    # shutdown with all services stopped thus release the lock
			    $haenv->release_ha_agent_lock();
			}

			$shutdown = 1;
		    }
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

sub run_workers {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $starttime = $haenv->get_time();

    # number of workers to start, if 0 we exec the command directly witouth forking
    my $max_workers = $haenv->get_max_workers();

    my $sc = $haenv->read_service_config();

    while (($haenv->get_time() - $starttime) < 5) {
	my $count =  $self->check_active_workers();

	foreach my $sid (keys %{$self->{workers}}) {
	    last if $count >= $max_workers && $max_workers > 0;

	    my $w = $self->{workers}->{$sid};
	    if (!$w->{pid}) {
		# only fork if we may else call exec_resource_agent
		# directly (e.g. for regression tests)
		if ($max_workers > 0) {
		    my $pid = fork();
		    if (!defined($pid)) {
			$haenv->log('err', "fork worker failed");
			$count = 0; last; # abort, try later
		    } elsif ($pid == 0) {
			$haenv->after_fork(); # cleanup

			# do work
			my $res = -1;
			eval {
			    $res = $self->exec_resource_agent($sid, $sc->{$sid}, $w->{state}, $w->{target});
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
			$res = $self->exec_resource_agent($sid, $sc->{$sid}, $w->{state}, $w->{target});
			$res = $res << 8 if $res > 0;
		    };
		    if (my $err = $@) {
			$haenv->log('err', $err);
		    }
		    if (defined($w->{uid})) {
			$self->resource_command_finished($sid, $w->{uid}, $res);
		    } else {
			$self->stop_command_finished($sid, $res);
		    }
		}
	    }
	}

	last if !$count;

	$haenv->sleep(1);
    }

    return scalar(keys %{$self->{workers}});
}

sub manage_resources {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $nodename = $haenv->nodename();

    my $ss = $self->{service_status};

    foreach my $sid (keys %{$self->{restart_tries}}) {
	delete $self->{restart_tries}->{$sid} if !$ss->{$sid};
    }

    foreach my $sid (keys %$ss) {
	my $sd = $ss->{$sid};
	next if !$sd->{node};
	next if !$sd->{uid};
	next if $sd->{node} ne $nodename;
	my $req_state = $sd->{state};
	next if !defined($req_state);
	next if $req_state eq 'freeze';
	$self->queue_resource_command($sid, $sd->{uid}, $req_state, $sd->{target});
    }

    return $self->run_workers();
}

sub queue_resource_command {
    my ($self, $sid, $uid, $state, $target) = @_;

    # do not queue the excatly same command twice as this may lead to
    # an inconsistent HA state when the first command fails but the CRM
    # does not process its failure right away and the LRM starts a second
    # try, without the CRM knowing of it (race condition)
    # The 'stopped' command is an exception as we do not process its result
    # in the CRM and we want to execute it always (even with no active CRM)
    return if $state ne 'stopped' && $uid && defined($self->{results}->{$uid});

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
		if (defined($w->{uid})) {
		    $self->resource_command_finished($sid, $w->{uid}, $?);
		} else {
		    $self->stop_command_finished($sid, $?);
		}
	    } else {
		$count++;
	    }
	}
    }
    
    return $count;
}

sub stop_command_finished {
    my ($self, $sid, $status) = @_;

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

    if ($exit_code != 0) {
	$self->{shutdown_errors}++;
    }
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

    return if $exit_code == ETRY_AGAIN; # tell nobody, simply retry

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

    my $max_restart = 0;

    if (my $cd = $sc->{$sid}) {
	$max_restart = $cd->{max_restart};
    }

    if ($cmd eq 'started') {

	if ($exit_code == SUCCESS) {

	    $tries->{$sid} = 0;

	    return $exit_code;

	} elsif ($exit_code == ERROR) {

	    $tries->{$sid} = 0 if !defined($tries->{$sid});

	    if ($tries->{$sid} >= $max_restart) {
		$haenv->log('err', "unable to start service $sid on local node".
			   " after $tries->{$sid} retries");
		$tries->{$sid} = 0;
		return ERROR;
	    }

	    $tries->{$sid}++;

	    $haenv->log('warning', "restart policy: retry number $tries->{$sid}" .
			" for service '$sid'");
	    # tell CRM that we retry the start
	    return ETRY_AGAIN;
	}
    }

    return $exit_code;

}

sub exec_resource_agent {
    my ($self, $sid, $service_config, $cmd, @params) = @_;

    # setup execution environment

    $ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';

    my $haenv = $self->{haenv};

    my $nodename = $haenv->nodename();

    my (undef, $service_type, $service_name) = PVE::HA::Tools::parse_sid($sid);

    my $plugin = PVE::HA::Resources->lookup($service_type);
    if (!$plugin) {
	$haenv->log('err', "service type '$service_type' not implemented");
	return EUNKNOWN_SERVICE_TYPE;
    }

    if (!$service_config) {
	$haenv->log('err', "missing resource configuration for '$sid'");
	return EUNKNOWN_SERVICE;
    }

    # process error state early
    if ($cmd eq 'error') {

	$haenv->log('err', "service $sid is in an error state and needs manual " .
		    "intervention. Look up 'ERROR RECOVERY' in the documentation.");

	return SUCCESS; # error always succeeds
    }

    if ($service_config->{node} ne $nodename) {
	$haenv->log('err', "service '$sid' not on this node");
	return EWRONG_NODE;
    }

    my $id = $service_name;

    my $running = $plugin->check_running($haenv, $id);

    if ($cmd eq 'started') {

	return SUCCESS if $running;

	$haenv->log("info", "starting service $sid");

	$plugin->start($haenv, $id);

	$running = $plugin->check_running($haenv, $id);

	if ($running) {
	    $haenv->log("info", "service status $sid started");
	    return SUCCESS;
	} else {
	    $haenv->log("warning", "unable to start service $sid");
	    return ERROR;
	}

    } elsif ($cmd eq 'request_stop' || $cmd eq 'stopped') {

	return SUCCESS if !$running;

	$haenv->log("info", "stopping service $sid");

	$plugin->shutdown($haenv, $id);

	$running = $plugin->check_running($haenv, $id);

	if (!$running) {
	    $haenv->log("info", "service status $sid stopped");
	    return SUCCESS;
	} else {
	    $haenv->log("info", "unable to stop stop service $sid (still running)");
	    return ERROR;
	}

    } elsif ($cmd eq 'migrate' || $cmd eq 'relocate') {

	my $target = $params[0];
	if (!defined($target)) {
	    die "$cmd '$sid' failed - missing target\n" if !defined($target);
	    return EINVALID_PARAMETER;
	}

	if ($service_config->{node} eq $target) {
	    # already there
	    return SUCCESS;
	}

	my $online = ($cmd eq 'migrate') ? 1 : 0;

	my $res = $plugin->migrate($haenv, $id, $target, $online);

	# something went wrong if service is still on this node
	if (!$res) {
	    $haenv->log("err", "service $sid not moved (migration error)");
	    return ERROR;
	}

	return SUCCESS;

    }

    $haenv->log("err", "implement me (cmd '$cmd')");
    return EUNKNOWN_COMMAND;
}


1;
