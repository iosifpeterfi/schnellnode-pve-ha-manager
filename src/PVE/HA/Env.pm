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

# manager status is stored on cluster, protected by ha_manager_lock
sub read_manager_status {
    my ($self) = @_;

    return $self->{plug}->read_manager_status();
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    return $self->{plug}->write_manager_status($status_obj);
}

# lrm status is written by LRM, protected by ha_agent_lock,
# but can be read by any node (CRM)

sub read_lrm_status {
    my ($self, $node) = @_;

    return $self->{plug}->read_lrm_status($node);
}

sub write_lrm_status {
    my ($self, $status_obj) = @_;

    return $self->{plug}->write_lrm_status($status_obj);
}

# we use this to enable/disbale ha
sub manager_status_exists {
    my ($self) = @_;

    die "this is not used?!"; # fixme:
    
    return $self->{plug}->manager_status_exists();
}

# implement a way to send commands to the CRM master
sub queue_crm_commands {
    my ($self, $cmd) = @_;

    return $self->{plug}->queue_crm_commands($cmd);
}

sub read_crm_commands {
    my ($self) = @_;

    return $self->{plug}->read_crm_commands();
}

sub read_service_config {
    my ($self) = @_;

    return $self->{plug}->read_service_config();
}

sub change_service_location {
    my ($self, $sid, $node) = @_;

    return $self->{plug}->change_service_location($sid, $node);
}

sub read_group_config {
    my ($self) = @_;

    return $self->{plug}->read_group_config();
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

# same as get_ha_agent_lock(), but immeditaley release the lock on success
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

    # Note: when using /dev/watchdog, make sure perl does not close
    # the handle automatically at exit!!

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

sub exec_resource_agent {
    my ($self, $sid, $service_config, $cmd, @params) = @_;

    return $self->{plug}->exec_resource_agent($sid, $service_config, $cmd, @params)
}

1;
