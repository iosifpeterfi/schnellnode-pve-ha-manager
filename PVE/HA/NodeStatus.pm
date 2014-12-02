package PVE::HA::NodeStatus;

use strict;
use warnings;

use Data::Dumper;

sub new {
    my ($this, $env, $status) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	env => $env,
	status => $status,
    }, $class;

    return $self;
}

# possible node state:
my $valid_node_states = {
    online => "node online and member of quorate partition",
    unknown => "not member of quorate partition, but possibly still running",
    fence => "node needs to be fenced",
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

sub list_online_nodes {
    my ($self) = @_;

    my $res = [];

    foreach my $node (keys %{$self->{status}}) {
	next if $self->{status}->{$node} ne 'online';
	push @$res, $node;
    }

    return $res;
}

my $set_node_state = sub {
    my ($self, $node, $state) = @_;

    die "unknown node state '$state'\n"
	if !defined($valid_node_states->{$state});

    my $last_state = $self->get_node_state($node);

    return if $state eq $last_state;

    $self->{status}->{$node} = $state;

    $self->{env}->log('info', "node '$node' status change: " .
		    "'$last_state' => '$state'\n");

};

sub update {
    my ($self, $node_info) = @_;

    foreach my $node (keys %$node_info) {
	my $d = $node_info->{$node};
	next if !$d->{online};

	my $state = $self->get_node_state($node);

	if ($state eq 'online') {
	    # &$set_node_state($self, $node, 'online');
	} elsif ($state eq 'unknown') {
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
	    # &$set_node_state($self, $node, 'unknown');
	} elsif ($state eq 'fence') {
	    # do nothing, wait until fenced
	} else {
	    die "detected unknown node state '$state";
	}

   }
}

sub fence_node {
    my ($self, $node) = @_;

    my $state = $self->get_node_state($node);

    if ($state eq 'fence') {
	die "return ID of existing fence task";
    } else {
	die "return ID of new fence task";
    }

    return "fixme:TASKID";
}

1;
