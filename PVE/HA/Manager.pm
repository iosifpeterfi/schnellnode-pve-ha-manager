package PVE::HA::Manager;

use strict;
use warnings;

use Data::Dumper;

use PVE::HA::NodeStatus;

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $ms = $haenv->read_manager_status();

    $ms->{master_node} = $haenv->nodename();

    my $ns = PVE::HA::NodeStatus->new($haenv, $ms->{node_status} || {});

    my $self = bless {
	haenv => $haenv,
	ms => $ms, # master status
	ns => $ns, # PVE::HA::NodeStatus
    }, $class;

    return $self;
}

sub cleanup {
    my ($self) = @_;

    # todo: ?
}

sub flush_master_status {
    my ($self) = @_;

    my $haenv = $self->{haenv};
    my $ms = $self->{ms};
    my $ns = $self->{ns};

    $ms->{node_status} = $ns->{status};
    $haenv->write_manager_status($ms);
} 

sub manage {
    my ($self) = @_;

    my $haenv = $self->{haenv};
    my $ms = $self->{ms};
    my $ns = $self->{ns};

    $ns->update($haenv->get_node_info());
    
    $self->flush_master_status();
}


1;
