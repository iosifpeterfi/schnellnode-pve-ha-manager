package PVE::HA::CRM;

# Cluster Resource Manager

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::HA::Tools;

use PVE::HA::Manager;

# Server can have several state:
#
# wait_for_quorum: cluster is not quorate, waiting
# recover: fixme?
# master:
# slave:
# lost_quorum:
# error:
# halt:

my $valid_states = {
    wait_for_quorum => 1,
    recover => 1,
    master => 1,
    slave => 1,
    lost_quorum => 1,
    error => 1,
    halt => 1,
};

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	haenv => $haenv,
	manager => undef,
    }, $class;

    $self->{status} = $haenv->read_local_status();
    # can happen after crash?
    if ($self->{status}->{state} eq 'master') {
	$self->set_local_status({ state => 'recover' });
    } else {
	$self->set_local_status({ state => 'wait_for_quorum' });   
    }
    
    return $self;
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

    return if $old->{state} eq $new->{state}; # important

    $haenv->log('info', "manager status change $old->{state} => $new->{state}");

    $new->{state_change_time} = $haenv->get_time();

    $haenv->write_local_status($new);

    $self->{status} = $new;

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

sub get_manager_locks {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $count = 0;
    my $agent_lock = 0;
    my $manager_lock = 0;

    for (;;) {

	if (!$manager_lock) {
	    if ($manager_lock = $haenv->get_ha_manager_lock()) {
		if ($self->{ha_manager_wd}) {
		    $haenv->watchdog_update($self->{ha_manager_wd});
		} else {
		    my $wfh = $haenv->watchdog_open();
		    $self->{ha_manager_wd} = $wfh;
		}
	    }
	}

	if (!$agent_lock) {
	    if ($agent_lock = $haenv->get_ha_agent_lock()) {
		if ($self->{ha_agent_wd}) {
		    $haenv->watchdog_update($self->{ha_agent_wd});
		} else {
		    my $wfh = $haenv->watchdog_open();
		    $self->{ha_agent_wd} = $wfh;
		}
	    }
	}
	    
	last if ++$count > 5;

	last if $manager_lock && $agent_lock;

	$haenv->sleep(1);
    }

    return 1 if $manager_lock;

    return 0;
}

sub do_one_iteration {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $status = $self->get_local_status();
    my $state = $status->{state};

    # do state changes first 

    my $ctime = $haenv->get_time();

    if ($state eq 'recover') {

	if (($ctime - $status->{state_change_time}) > 5) {
	    $self->set_local_status({ state => 'wait_for_quorum' });
	}

    } elsif ($state eq 'wait_for_quorum') {

	if ($haenv->quorate()) {
	    if ($self->get_manager_locks()) {
		$self->set_local_status({ state => 'master' });
	    } else {
		$self->set_local_status({ state => 'slave' });
	    }
	}

    } elsif ($state eq 'master') {

	if (!$self->get_manager_locks()) {
	    if ($haenv->quorate()) {
		$self->set_local_status({ state => 'slave' });
	    } else {
		$self->set_local_status({ state => 'wait_for_quorum'});
		# set_local_status({ state => 'lost_quorum' });
	    }
	}

    } elsif ($state eq 'slave') {

	if ($haenv->quorate()) {
	    if ($self->get_manager_locks()) {
		$self->set_local_status({ state => 'master' });
	    }
	} else {
	    $self->set_local_status({ state => 'wait_for_quorum' });
	}

    }
   
    $status = $self->get_local_status();
    $state = $status->{state};

    # do work

    if ($state eq 'recover') {

	$haenv->sleep(5);

    } elsif ($state eq 'wait_for_quorum') {

	$haenv->sleep(5);
	   
    } elsif ($state eq 'master') {

	my $manager = $self->{manager};

	die "no manager" if !defined($manager);

	my $startime = $haenv->get_time();

	my $max_time = 10;

	# do work (max_time seconds)
	eval {
	    # fixme: set alert timer
	    $manager->manage();
	};
	if (my $err = $@) {

	    $haenv->log('err', "got unexpected error - $err");
	    $self->set_local_status({ state => 'error' });

	} else {
	    $haenv->sleep_until($startime + $max_time);
	}

    } elsif ($state eq 'slave') {
	# do nothing
    } elsif ($state eq 'error') {
	die "stopping due to errors\n";
    } elsif ($state eq 'lost_quorum') {
	die "lost_quorum\n";
    } elsif ($state eq 'halt') {
	die "halt\n";
    } else {
	die "got unexpected status '$state'\n";
    }

    return 1;
}

1;
