package PVE::HA::CRM;

# Cluster Resource Manager

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::HA::Tools;

use PVE::HA::Manager;

# Server can have several state:

my $valid_states = {
    wait_for_quorum => "cluster is not quorate, waiting",
    master => "quorate, and we got the ha_manager lock",
    lost_manager_lock => "we lost the ha_manager lock (watchdog active)",
    slave => "quorate, but we do not own the ha_manager lock",
};

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	haenv => $haenv,
	manager => undef,
	status => { state => 'startup' },
    }, $class;

    $self->set_local_status({ state => 'wait_for_quorum' });
    
    return $self;
}

sub shutdown_request {
    my ($self) = @_;

    syslog('info' , "server received shutdown request")
	if !$self->{shutdown_request};

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

    # fixme: do not use extra class
    if ($new->{state} eq 'master') {
	$self->{manager} = PVE::HA::Manager->new($haenv);
    } else {
	if ($self->{manager}) {
	    # fixme: what should we do here?
	    $self->{manager}->cleanup();
	    $self->{manager} = undef;
	}
    }
}

sub get_protected_ha_manager_lock {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $count = 0;
    my $starttime = $haenv->get_time();

    for (;;) {
	
	if ($haenv->get_ha_manager_lock()) {
	    if ($self->{ha_manager_wd}) {
		$haenv->watchdog_update($self->{ha_manager_wd});
	    } else {
		my $wfh = $haenv->watchdog_open();
		$self->{ha_manager_wd} = $wfh;
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

sub check_pending_fencing {
    my ($manager_status, $node) = @_;

    my $ss = $manager_status->{service_status};

    return 1 if PVE::HA::Tools::count_fenced_services($ss, $node);

    return 0;
}

sub do_one_iteration {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $status = $self->get_local_status();
    my $state = $status->{state};

    my $manager_status = $haenv->read_manager_status();
    my $pending_fencing = check_pending_fencing($manager_status, $haenv->nodename());
    
    # do state changes first 

    if ($state eq 'wait_for_quorum') {

	if (!$pending_fencing && $haenv->quorate() &&
	    PVE::HA::Tools::has_services($haenv)) {
	    if ($self->get_protected_ha_manager_lock()) {
		$self->set_local_status({ state => 'master' });
	    } else {
		$self->set_local_status({ state => 'slave' });
	    }
	}

    } elsif ($state eq 'slave') {

	if (!$pending_fencing && $haenv->quorate() &&
	    PVE::HA::Tools::has_services($haenv)) {
	    if ($self->get_protected_ha_manager_lock()) {
		$self->set_local_status({ state => 'master' });
	    }
	} else {
	    $self->set_local_status({ state => 'wait_for_quorum' });
	}

    } elsif ($state eq 'lost_manager_lock') {

	if (!$pending_fencing && $haenv->quorate()) {
	    if ($self->get_protected_ha_manager_lock()) {
		$self->set_local_status({ state => 'master' });
	    }
	}

    } elsif ($state eq 'master') {

	if (!$self->get_protected_ha_manager_lock()) {
	    $self->set_local_status({ state => 'lost_manager_lock'});
	}
    }
   
    $status = $self->get_local_status();
    $state = $status->{state};

    # do work

    if ($state eq 'wait_for_quorum') {

	return 0 if $self->{shutdown_request};

	$haenv->sleep(5);
	   
    } elsif ($state eq 'master') {

	my $manager = $self->{manager};

	die "no manager" if !defined($manager);

	my $startime = $haenv->get_time();

	my $max_time = 10;

	my $shutdown = 0;

	# do work (max_time seconds)
	eval {
	    # fixme: set alert timer

	    if ($self->{shutdown_request}) {

		if ($self->{ha_manager_wd}) {
		    $haenv->watchdog_close($self->{ha_manager_wd});
		    delete $self->{ha_manager_wd};
		}

		# release the manager lock, so another CRM slave can get it
		# and continue to work without waiting for the lock timeout
		$haenv->log('info', "voluntary release CRM lock");
		if (!$haenv->release_ha_manager_lock()) {
		    $haenv->log('notice', "CRM lock release failed, let the" .
				" lock timeout");
		}

		$shutdown = 1;

	    } else {
		$manager->manage();
	    }
	};
	if (my $err = $@) {
	    $haenv->log('err', "got unexpected error - $err");
	}

	return 0 if $shutdown;

	$haenv->sleep_until($startime + $max_time);

    } elsif ($state eq 'lost_manager_lock') {
	
	if ($self->{ha_manager_wd}) {
	    $haenv->watchdog_close($self->{ha_manager_wd});
	    delete $self->{ha_manager_wd};
	}

	return 0 if $self->{shutdown_request};

	$self->set_local_status({ state => 'wait_for_quorum' });

    } elsif ($state eq 'slave') {

	return 0 if $self->{shutdown_request};

	# wait until we get master

    } else {

	die "got unexpected status '$state'\n";
    }

    return 1;
}

1;
