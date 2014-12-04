package PVE::HA::Env;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;

# abstract out the cluster environment

sub new {
    my ($this, $statusdir, $nodename) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	statusdir => $statusdir,
	nodename => $nodename,
    }, $class;

    return $self;
}

sub nodename {
    my ($self) = @_;

    return $self->{nodename};
}

sub read_local_status {
    my ($self) = @_;

    my $node = $self->{nodename};
    my $filename = "$self->{statusdir}/local_status_$node";
    return PVE::Tools::file_read_firstline($filename);  
}

sub write_local_status {
    my ($self, $status) = @_;

    my $node = $self->{nodename};
    my $filename = "$self->{statusdir}/local_status_$node";
    PVE::Tools::file_set_contents($filename, $status);
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

# we use this to enable/disbale ha
sub manager_status_exists {
    my ($self) = @_;

    die "implement me";

    return {};
}

sub parse_service_config {
    my ($self, $raw) = @_;

    die "implement me";

    return {};
}

sub read_service_config {
    my ($self) = @_;

    die "implement me";

    return {};
}

# this should return a hash containing info
# what nodes are members and online.
sub get_node_info {
    my ($self) = @_;

    die "implement me";   

    # return { node1 => { online => 1 }, node2 => ... }
}

sub log {
    my ($self, $level, @args) = @_;

    syslog($level, @args);
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

sub sleep_until {
   my ($self, $end_time) = @_;

   for (;;) {
       my $cur_time = $self->get_time();
       return if $cur_time >= $end_time;
       $self->sleep($end_time - $cur_time);
   }
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
