package PVE::HA::Env::PVE2;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::Cluster;

use PVE::HA::Tools;
use PVE::HA::Env;

my $manager_status_filename = "/etc/pve/manager_status";

sub new {
    my ($this, $nodename) = @_;

    die "missing nodename" if !$nodename;

    my $class = ref($this) || $this;

    my $self = bless {}, $class;

    $self->{nodename} = $nodename;

    return $self;
}

sub nodename {
    my ($self) = @_;

    return $self->{nodename};
}

sub read_manager_status {
    my ($self) = @_;
    
    my $filename = $manager_status_filename;

    return PVE::HA::Tools::read_json_from_file($filename, {});  
}

sub write_manager_status {
    my ($self, $status_obj) = @_;
    
    my $filename = $manager_status_filename;

    PVE::HA::Tools::write_json_to_file($filename, $status_obj); 
}

sub read_lrm_status {
    my ($self, $node) = @_;

    $node = $self->{nodename} if !defined($node);

    my $filename = "/etc/pve/nodes/$node/lrm_status";

    return PVE::HA::Tools::read_json_from_file($filename, {});  
}

sub write_lrm_status {
    my ($self, $status_obj) = @_;

    $node = $self->{nodename};

    my $filename = "/etc/pve/nodes/$node/lrm_status";

    PVE::HA::Tools::write_json_to_file($filename, $status_obj); 
}

sub manager_status_exists {
    my ($self) = @_;
    
    return -f $manager_status_filename ? 1 : 0;
}

sub read_service_config {
    my ($self) = @_;

    die "implement me";
}

# this should return a hash containing info
# what nodes are members and online.
sub get_node_info {
    my ($self) = @_;

    die "implement me";
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    syslog($level, $msg);
}

sub get_ha_manager_lock {
    my ($self) = @_;

    my $lockid = "ha_manager";

    my $lockdir = "/etc/pve/priv/lock";
    my $filename = "$lockdir/$lockid";

    my $res = 0;

    eval {

	mkdir $lockdir;

	return if ! -d $lockdir; # pve cluster filesystem not online

	# fixme: ?
    };

    return $res;
}

sub get_ha_agent_lock {
    my ($self) = @_;

    die "implement me";
}

sub test_ha_agent_lock {
    my ($self, $node) = @_;

    die "implement me";
}

sub quorate {
    my ($self) = @_;

    my $quorate = 0;
    eval { 
	$quorate = PVE::Cluster::check_cfs_quorum(); 
    };
   
    return $quorate;
}

sub get_time {
    my ($self) = @_;

    return time();
}

sub sleep {
    my ($self, $delay) = @_;

    CORE::sleep($delay);
}

sub sleep_until {
   my ($self, $end_time) = @_;

   for (;;) {
       my $cur_time = time();

       last if $cur_time >= $end_time;

       $self->sleep(1);
   }
}

sub loop_start_hook {
    my ($self) = @_;

    PVE::Cluster::cfs_update();
    
    $self->{loop_start} = $self->get_time();
}

sub loop_end_hook {
    my ($self) = @_;

    my $delay = $self->get_time() - $self->{loop_start};
 
    warn "loop take too long ($delay seconds)\n" if $delay > 30;
}

sub watchdog_open {
    my ($self) = @_;

    # Note: when using /dev/watchdog, make sure perl does not close
    # the handle automatically at exit!!

    die "implement me";
}

sub watchdog_update {
    my ($self, $wfh) = @_;

    die "implement me";
}

sub watchdog_close {
    my ($self, $wfh) = @_;

    die "implement me";
}

sub exec_resource_agent {
    my ($self, $sid, $cmd, @params) = @_;

    die "implement me";
}

1;
