package PVE::HA::Manager;

use strict;
use warnings;
use Digest::MD5 qw(md5_base64);

use Data::Dumper;

use PVE::HA::NodeStatus;

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $ms = $haenv->read_manager_status();

    $ms->{master_node} = $haenv->nodename();

    my $ns = PVE::HA::NodeStatus->new($haenv, $ms->{node_status} || {});

    # fixme: use separate class  PVE::HA::ServiceStatus
    my $ss = $ms->{service_status} || {};

    my $self = bless {
	haenv => $haenv,
	ms => $ms, # master status
	ns => $ns, # PVE::HA::NodeStatus
	ss => $ss, # service status
    }, $class;

    return $self;
}

sub cleanup {
    my ($self) = @_;

    # todo: ?
}

sub flush_master_status {
    my ($self) = @_;

    my ($haenv, $ms, $ns, $ss) = ($self->{haenv}, $self->{ms}, $self->{ns}, $self->{ss});

    $ms->{node_status} = $ns->{status};
    $ms->{service_status} = $ss;

    $haenv->write_manager_status($ms);
} 

# Attention: must be idempotent (alway return the same result for same input!)
sub select_service_node {
    my ($self, $service_conf) = @_;

    my $ns = $self->{ns};
    
    my $pref_node = $service_conf->{node};

    return $pref_node if $ns->node_is_online($pref_node);

    my $online_nodes = $ns->list_online_nodes();

    return shift @$online_nodes;
}

my $uid_counter = 0;

my $valid_service_states = {
    stopped => 1,
    request_stop => 1,
    started => 1,
    fence => 1,
    move => 1,
    migrate => 1,
    error => 1,
};

my $change_service_state = sub {
    my ($self, $sid, $new_state, %params) = @_;

    my ($haenv, $ss) = ($self->{haenv}, $self->{ss});

    my $sd = $ss->{$sid} || die "no such service '$sid";

    my $old_state = $sd->{state};

    die "no state change" if $old_state eq $new_state; # just to be sure

    die "invalid CRM service state '$new_state'\n" if !$valid_service_states->{$new_state};

    my $changes = '';
    foreach my $k (keys %params) {
	my $v = $params{$k};
	next if defined($sd->{$k}) && $sd->{$k} eq $v;
	$changes .= ", " if $changes;
	$changes .= "$k = $v";
	$sd->{$k} = $v;
    }
    
    $sd->{state} = $new_state;
    $uid_counter++;
    $sd->{uid} = md5_base64($new_state . $$ . time() . $uid_counter);

    # fixme: cleanup state (remove unused values)

    $changes = " ($changes)" if $changes;
    $haenv->log('info', "service '$sid': state changed to '$new_state' $changes\n");
};

# read LRM status for all active nodes 
sub read_lrm_status {
    my ($self) = @_;

    my $nodes = $self->{ns}->list_online_nodes();
    my $haenv = $self->{haenv};

    my $res = {};

    foreach my $node (@$nodes) {
	my $ls = $haenv->read_lrm_status($node);
	foreach my $uid (keys %$ls) {
	    next if $res->{$uid}; # should not happen
	    $res->{$uid} = $ls->{$uid};
	}
    }

    return $res;
}

sub manage {
    my ($self) = @_;

    my ($haenv, $ms, $ns, $ss) = ($self->{haenv}, $self->{ms}, $self->{ns}, $self->{ss});

    $ns->update($haenv->get_node_info());

    if (!$ns->node_is_online($haenv->nodename())) {
	$haenv->log('info', "master seems offline\n");
	return;
    }

    my $lrm_status = $self->read_lrm_status();

    my $sc = $haenv->read_service_config();

    # compute new service status

    # add new service
    foreach my $sid (keys %$sc) {
	next if $ss->{$sid}; # already there
	$haenv->log('info', "Adding new service '$sid'\n");
	# assume we are running to avoid relocate running service at add
	$ss->{$sid} = { state => 'started', node => $sc->{$sid}->{node}};
    }

    for (;;) {
	my $repeat = 0;

	foreach my $sid (keys %$ss) {
	    my $sd = $ss->{$sid};
	    my $cd = $sc->{$sid} || { state => 'disabled' };

	    my $lrm_res = $sd->{uid} ? $lrm_status->{$sd->{uid}} : undef;

	    my $last_state = $sd->{state};

	    if ($last_state eq 'stopped') {

		$self->next_state_stopped($sid, $cd, $sd);

	    } elsif ($last_state eq 'started') {

		$self->next_state_started($sid, $cd, $sd);

	    } elsif ($last_state eq 'migrate') {

		die "implement me";

	    } elsif ($last_state eq 'move') {

		#die "implement me";

	    } elsif ($last_state eq 'fence') {

		# do nothing here - wait until fenced

	    } elsif ($last_state eq 'request_stop') {

		# check result from LRM daemon
		if ($lrm_res) {
		    my $exit_code = $lrm_res->{exit_code};
		    if ($exit_code == 0) {
			&$change_service_state($self, $sid, 'stopped');
		    } else {
			&$change_service_state($self, $sid, 'error'); # fixme: what state?
		    }
		}

	    } else {

		die "unknown service state '$last_state'";
	    }

	    $repeat = 1 if $sd->{state} ne $last_state;
	}

	# handle fencing
	my $fenced_nodes = {};
	foreach my $sid (keys %$ss) {
	    my $sd = $ss->{$sid};
	    next if $sd->{state} ne 'fence';

	    if (!defined($fenced_nodes->{$sd->{node}})) {
		$fenced_nodes->{$sd->{node}} = $ns->fence_node($sd->{node}) || 0;
	    }

	    next if !$fenced_nodes->{$sd->{node}};

	    # node fence was sucessful - mark service as stopped
	    &$change_service_state($self, $sid, 'stopped');	    
	}

	last if !$repeat;
    }

    # remove stale services
    # fixme:

    $self->flush_master_status();
}

# functions to compute next service states
# $cd: service configuration data (read only)
# $sd: service status data (read only)
#
# Note: use change_service_state() to alter state
#

sub next_state_stopped {
    my ($self, $sid, $cd, $sd) = @_;

    my $haenv = $self->{haenv};

    if ($cd->{state} eq 'disabled') {
	# do nothing
    } elsif ($cd->{state} eq 'enabled') {
	if (my $node = $self->select_service_node($cd)) {
	    if ($node && ($sd->{node} ne $node)) {
		$haenv->change_service_location($sid, $node);
	    }
	    &$change_service_state($self, $sid, 'started', node => $node);
	} else {
	    # fixme: warn 
	}
    } else {
	# do nothing - todo: log something?
    }
}

sub next_state_started {
    my ($self, $sid, $cd, $sd) = @_;

    my $haenv = $self->{haenv};
    my $ns = $self->{ns};

    if (!$ns->node_is_online($sd->{node})) {

	&$change_service_state($self, $sid, 'fence');
	
    } else {
	
	if ($cd->{state} eq 'disabled') {
	    &$change_service_state($self, $sid, 'request_stop');
	} elsif ($cd->{state} eq 'enabled') {
	    my $node = $self->select_service_node($cd);
	    if ($node && ($sd->{node} ne $node)) {
		&$change_service_state($self, $sid, 'migrate');
	    } else {
		# do nothing
	    }
	} else {
	    # do nothing - todo: log something?
	}
    }
}

1;
