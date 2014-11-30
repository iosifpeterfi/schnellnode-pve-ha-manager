package PVE::HA::Env;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;

# abstract out the cluster environment

sub new {
    my ($this, $statusdir) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	statusdir => $statusdir,
    }, $class;

    return $self;
}

sub read_local_status {
    my ($self) = @_;

    return PVE::Tools::file_read_firstline("$self->{statusdir}/status");  
}

sub write_local_status {
    my ($self, $status) = @_;

    PVE::Tools::file_set_contents("$self->{statusdir}/status", $status);
}

# manager status is stored on cluster, protected by ha_manager_lock
sub read_manager_status {
    my ($self) = @_;

    die "implement me";

    return {};
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    die "implement me";
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

# return true when cluster is quorate
sub quorate {
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
