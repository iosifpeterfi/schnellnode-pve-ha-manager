package PVE::HA::NodeStatus;

use strict;
use warnings;

use JSON;
use Data::Dumper;

my $fence_delay = 60;

sub new {
    my ($this, $haenv, $status) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	haenv => $haenv,
	status => $status,
	last_online => {},
    }, $class;

    return $self;
}

# possible node state:
my $valid_node_states = {
    online => "node online and member of quorate partition",
    unknown => "not member of quorate partition, but possibly still running",
    fence => "node needs to be fenced",
    gone => "node vanished from cluster members list, possibly deleted"
};

sub get_node_state {
    my ($self, $node) = @_;

    $self->{status}->{$node} = 'unknown' 
	if !$self->{status}->{$node};

    return $self->{status}->{$node};
}

sub node_is_online {
    my ($self, $node) = @_;

    return $self->get_node_state($node) eq 'online';
}

sub node_is_offline_delayed {
    my ($self, $node, $delay) = @_;

    $delay = $fence_delay if !defined($delay);

    my $haenv = $self->{haenv};

    return undef if $self->get_node_state($node) eq 'online';

    my $last_online = $self->{last_online}->{$node};

    my $ctime = $haenv->get_time();

    if (!defined($last_online)) {
	$self->{last_online}->{$node} = $ctime;
	return undef;
    }

    return ($ctime - $last_online) >= $delay;
}

sub list_nodes {
    my ($self) = @_;

    return [sort keys %{$self->{status}}];
}

sub list_online_nodes {
    my ($self) = @_;

    my $res = [];

    foreach my $node (sort keys %{$self->{status}}) {
	next if $self->{status}->{$node} ne 'online';
	push @$res, $node;
    }

    return $res;
}

my $delete_node = sub {
    my ($self, $node) = @_;

    return undef if $self->get_node_state($node) ne 'gone';

    my $haenv = $self->{haenv};

    delete $self->{last_online}->{$node};
    delete $self->{status}->{$node};

    $haenv->log('notice', "deleting gone node '$node', not a cluster member".
		" anymore.");
};

my $set_node_state = sub {
    my ($self, $node, $state) = @_;

    my $haenv = $self->{haenv};

    die "unknown node state '$state'\n"
	if !defined($valid_node_states->{$state});

    my $last_state = $self->get_node_state($node);

    return if $state eq $last_state;

    $self->{status}->{$node} = $state;

    $haenv->log('info', "node '$node': state changed from " .
		"'$last_state' => '$state'\n");
};

sub update {
    my ($self, $node_info) = @_;

    my $haenv = $self->{haenv};

    foreach my $node (sort keys %$node_info) {
	my $d = $node_info->{$node};
	next if !$d->{online};

	# record last time the node was online (required to implement fence delay)
	$self->{last_online}->{$node} = $haenv->get_time();

	my $state = $self->get_node_state($node);

	if ($state eq 'online') {
	    # &$set_node_state($self, $node, 'online');
	} elsif ($state eq 'unknown' || $state eq 'gone') {
	    &$set_node_state($self, $node, 'online');
	} elsif ($state eq 'fence') {
	    # do nothing, wait until fenced
	} else {
	    die "detected unknown node state '$state";
	}
    }

    foreach my $node (keys %{$self->{status}}) {
	my $d = $node_info->{$node};
	next if $d && $d->{online};

	my $state = $self->get_node_state($node);

	# node is not inside quorate partition, possibly not active

	if ($state eq 'online') {
	    &$set_node_state($self, $node, 'unknown');
	} elsif ($state eq 'unknown') {

	    # node isn't in the member list anymore, deleted from the cluster?
	    &$set_node_state($self, $node, 'gone') if(!defined($d));

	} elsif ($state eq 'fence') {
	    # do nothing, wait until fenced
	} elsif($state eq 'gone') {
	    if($self->node_is_offline_delayed($node, 3600)) {
		&$delete_node($self, $node);
	    }
	} else {
	    die "detected unknown node state '$state";
	}

   }
}

# assembles a commont text for fence emails
my $send_fence_state_email = sub {
    my ($self, $subject_prefix, $subject, $node) = @_;

    my $haenv = $self->{haenv};

    my $mail_text = <<EOF
The node '$node' failed and needs manual intervention.

The PVE HA manager tries  to fence it and recover the
configured HA resources to a healthy node if possible.

Current fence status:  $subject_prefix
$subject


Overall Cluster status:
-----------------------

EOF
;
    my $mail_subject = $subject_prefix . ': ' . $subject;

    my $status = $haenv->read_manager_status();
    my $data = { manager_status => $status, node_status => $self->{status} };

    $mail_text .= to_json($data, { pretty => 1, canonical => 1});

    $haenv->sendmail($mail_subject, $mail_text);
};


# start fencing
sub fence_node {
    my ($self, $node) = @_;

    my $haenv = $self->{haenv};

    my $state = $self->get_node_state($node);

    if ($state ne 'fence') {
	&$set_node_state($self, $node, 'fence');
	my $msg = "Try to fence node '$node'";
	&$send_fence_state_email($self, 'FENCE', $msg, $node);
    }

    my $success = $haenv->get_ha_agent_lock($node);

    if ($success) {
	my $msg = "fencing: acknowleged - got agent lock for node '$node'";
	$haenv->log("info", $msg);
	&$set_node_state($self, $node, 'unknown');
	&$send_fence_state_email($self, 'SUCEED', $msg, $node);
    }

    return $success;
}

1;
