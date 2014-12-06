package PVE::HA::CRM;

# Cluster Resource Manager

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;

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

    $self->{status} = $haenv->read_local_status() || 'wait_for_quorum';
    # can happen after crash?
    if ($self->{status} eq 'master') {
	$self->set_local_status('recover');
    } else {
	$self->set_local_status('wait_for_quorum');   
    }
    
    return $self;
}

sub get_local_status {
    my ($self) = @_;

    return $self->{status};
}

sub set_local_status {
    my ($self, $new_status) = @_;

    die "invalid state '$new_status'" 
	if !$valid_states->{$new_status};

    my $haenv = $self->{haenv};

    my $status = $self->{status};

    return if $status eq $new_status;

    $haenv->log('info', "manager status change $status => $new_status");

    $status = $new_status;

    $haenv->write_local_status($status);

    $self->{status} = $status;

    if ($status eq 'master') {
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

    if ($status eq 'recover') {

	$haenv->log('info', "waiting for 5 seconds");

	$haenv->sleep(5);

	$self->set_local_status('wait_for_quorum');

    } elsif ($status eq 'wait_for_quorum') {

	$haenv->sleep(5);
	   
	if ($haenv->quorate()) {
	    if ($self->get_manager_locks()) {
		$self->set_local_status('master');
	    } else {
		$self->set_local_status('slave');
	    }
	}

    } elsif ($status eq 'master') {

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

	    # fixme: cleanup?
	    $haenv->log('err', "got unexpected error - $err");
	    $self->set_local_status('error');

	} else {
	    $haenv->sleep_until($startime + $max_time);
	}

	if (!$self->get_manager_locks()) {
	    if ($haenv->quorate()) {
		$self->set_local_status('slave');
	    } else {
		$self->set_local_status('wait_for_quorum');
		# set_local_status('lost_quorum');
	    }
	}
    } elsif ($status eq 'slave') {

	$haenv->sleep(5);

	if ($haenv->quorate()) {
	    if ($self->get_manager_locks()) {
		$self->set_local_status('master');
	    }
	} else {
	    $self->set_local_status('wait_for_quorum');
	}

    } elsif ($status eq 'error') {
	die "stopping due to errors\n";
    } elsif ($status eq 'lost_quorum') {
	die "lost_quorum\n";
    } elsif ($status eq 'halt') {
	die "halt\n";
    } else {
	die "got unexpected status '$status'\n";
    }

    return 1;
}

1;
