package PVE::HA::Manager;

use strict;
use warnings;

use Data::Dumper;

use PVE::HA::NodeStatus;

sub new {
    my ($this, $env) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	env => $env,
    }, $class;

    return $self;
}

sub cleanup {
    my ($self) = @_;

    # todo: ?
}

sub manage {
    my ($self) = @_;

    my $haenv = $self->{env};

    my $ms = $haenv->read_manager_status();

    $ms->{node_status} = {} if !$ms->{node_status};

    my $node_status = PVE::HA::NodeStatus->new($haenv, $ms->{node_status});

    $ms->{master_node} = $haenv->nodename();

    my $node_info = $haenv->get_node_info();
    
    $node_status->update($node_info);
    

    $ms->{node_status} = $node_status->{status};
    $haenv->write_manager_status($ms);

}


1;
