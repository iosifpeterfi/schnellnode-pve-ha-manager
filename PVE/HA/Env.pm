package PVE::HA::Env;

use strict;
use warnings;

use PVE::SafeSyslog;

# abstract out the cluster environment

sub new {
    my ($this) = @_;

    my $class = ref($this) || $this;

    my $self = bless {}, $class;

    return $self;
}

# this should return a hash containing info
# what nodes are members and online.
sub get_node_info {
    my ($self) = @_;

    die "implement me";   

    # return { node1 => { online => 1, join_time => X }, node2 => ... }
}

sub log {
    my ($self, $level, $msg) = @_;

    syslog($level, $msg);
}

# aquire a cluster wide lock 
sub get_ha_manager_lock {
    my ($self) = @_;

    die "implement me";
}

# return current time
# overwrite that if you want to simulate
sub get_time {
    my ($self) = @_;

    return time();
}

sub sleep {
   my ($self, $delay) = @_;

   sleep($delay);
}

sub loop_start_hook {
    my ($self) = @_;

    # do nothing
}

sub loop_end_hook {
    my ($self) = @_;

    # do nothing
}


1;
