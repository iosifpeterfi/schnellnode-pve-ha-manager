package PVE::HA::NodeStatus;

use strict;
use warnings;

use Data::Dumper;

sub new {
    my ($this, $env) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	env => $env,
	status => {},
    }, $class;

    return $self;
}

# possible node state:
my $valid_node_states = {
    online => "no online, or possibly online (no info so far)",
    fenced => "node was fenced",
    needs_fence => "node needs to be fenced",
};

sub get_node_state {
    my ($self, $node) = @_;

    $self->{status}->{$node} = 'online' 
	if !$self->{status}->{$node};

    return $self->{status}->{$node};
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

	if ($state eq 'fenced') {
	    &$set_node_state($self, $node, 'online');
	}
    }

    foreach my $node (keys %{$self->{status}}) {
	my $d = $node_info->{$node};
	next if $d && $d->{online};

	my $state = $self->get_node_state($node);

	# node is possibly not active - no nothing
   }
}

1;
