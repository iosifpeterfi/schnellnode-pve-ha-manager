package PVE::HA::Env;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;

# abstract out the cluster environment for a single node

sub new {
    my ($this, $baseclass, $node, @args) = @_;

    my $class = ref($this) || $this;

    my $plug = $baseclass->new($node, @args);

    my $self = bless { plug => $plug }, $class;

    return $self;
}

sub nodename {
    my ($self) = @_;

    return $self->{plug}->nodename();
}

sub read_local_status {
    my ($self) = @_;

    return $self->{plug}->read_local_status();
}

sub write_local_status {
    my ($self, $status) = @_;

    return $self->{plug}->write_local_status($status);
}

# manager status is stored on cluster, protected by ha_manager_lock
sub read_manager_status {
    my ($self) = @_;

    return $self->{plug}->read_manager_status();
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    return $self->{plug}->write_manager_status($status_obj);
}

# we use this to enable/disbale ha
sub manager_status_exists {
    my ($self) = @_;

    return $self->{plug}->manager_status_exists();
}

sub read_service_config {
    my ($self) = @_;

    return $self->{plug}->read_service_config();
}

# this should return a hash containing info
# what nodes are members and online.
sub get_node_info {
    my ($self) = @_;

    return $self->{plug}->get_node_info();
}

sub log {
    my ($self, $level, @args) = @_;

    return $self->{plug}->log($level, @args);
}

# aquire a cluster wide manager lock 
sub get_ha_manager_lock {
    my ($self) = @_;

    return $self->{plug}->get_ha_manager_lock();
}

# aquire a cluster wide node agent lock 
sub get_ha_agent_lock {
    my ($self) = @_;

    return $self->{plug}->get_ha_agent_lock();
}

sub test_ha_agent_lock {
    my ($self, $node) = @_;

    return $self->{plug}->test_ha_agent_lock($node);
}

# return true when cluster is quorate
sub quorate {
    my ($self) = @_;

    return $self->{plug}->quorate();
}

# return current time
# overwrite that if you want to simulate
sub get_time {
    my ($self) = @_;

    return $self->{plug}->get_time();
}

sub sleep {
   my ($self, $delay) = @_;

   return $self->{plug}->sleep($delay);
}

sub sleep_until {
   my ($self, $end_time) = @_;

   return $self->{plug}->sleep_until($end_time);
}

sub loop_start_hook {
    my ($self, @args) = @_;

    return $self->{plug}->loop_start_hook(@args);
}

sub loop_end_hook {
    my ($self, @args) = @_;
    
    return $self->{plug}->loop_end_hook(@args);
}

sub watchdog_open {
    my ($self) = @_;

    return $self->{plug}->watchdog_open();
}

sub watchdog_update {
    my ($self, $wfh) = @_;

    return $self->{plug}->watchdog_update($wfh);
}

sub watchdog_close {
    my ($self, $wfh) = @_;

    return $self->{plug}->watchdog_close($wfh);
}

1;
