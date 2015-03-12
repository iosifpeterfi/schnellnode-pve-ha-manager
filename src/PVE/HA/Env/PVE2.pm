package PVE::HA::Env::PVE2;

use strict;
use warnings;
use POSIX qw(:errno_h :fcntl_h);
use IO::File;
use IO::Socket::UNIX;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file);

use PVE::HA::Tools;
use PVE::HA::Env;
use PVE::HA::Config;

my $lockdir = "/etc/pve/priv/lock";

my $manager_status_filename = "/etc/pve/ha/manager_status";
my $ha_groups_config = "/etc/pve/ha/groups.cfg";
my $ha_resources_config = "/etc/pve/ha/resources.cfg";

#cfs_register_file($ha_groups_config, 
#		  sub { PVE::HA::Groups->parse_config(@_); },
#		  sub { PVE::HA::Groups->write_config(@_); });

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

    my $node = $self->{nodename};

    my $filename = "/etc/pve/nodes/$node/lrm_status";

    PVE::HA::Tools::write_json_to_file($filename, $status_obj); 
}

sub manager_status_exists {
    my ($self) = @_;
    
    return -f $manager_status_filename ? 1 : 0;
}

sub read_service_config {
    my ($self) = @_;

    # fixme: use cfs_read_file
    
    my $raw = '';

    $raw = PVE::Tools::file_get_contents($ha_resources_config)
	if -f $ha_resources_config;
    
    my $res = PVE::HA::Config::parse_resources_config($ha_resources_config, $raw);

    my $vmlist = PVE::Cluster::get_vmlist();
    my $conf = {};

    foreach my $sid (keys %{$res->{ids}}) {
	my $d = $res->{ids}->{$sid};
	$d->{state} = 'enabled' if !defined($d->{state});
	if ($d->{type} eq 'pvevm') {
	    if (my $vmd = $vmlist->{ids}->{$d->{name}}) {
		if (!$vmd) {
		    warn "no such VM '$d->{name}'\n";
		} else {
		    $d->{node} = $vmd->{node};
		    $conf->{$sid} = $d;
		}
	    } else {
		if (defined($d->{node})) {
		    $conf->{$sid} = $d;
		} else {
		    warn "service '$sid' without node\n";
		}
	    }
	}
    }
    
    return $conf;
}

sub change_service_location {
    my ($self, $sid, $node) = @_;

    die "implement me";
}

sub read_group_config {
    my ($self) = @_;

    # fixme: use cfs_read_file
    
    my $raw = '';

    $raw = PVE::Tools::file_get_contents($ha_groups_config)
	if -f $ha_groups_config;
    
    return PVE::HA::Config::parse_groups_config($ha_groups_config, $raw);
}

sub queue_crm_commands {
    my ($self, $cmd) = @_;

    chomp $cmd;

    my $code = sub {
	my $data = '';
	my $filename = "/etc/pve/ha/crm_commands";
	if (-f $filename) {
	    $data = PVE::Tools::file_get_contents($filename);
	}
	$data .= "$cmd\n";
	PVE::Tools::file_set_contents($filename, $data);
    };

    # fixme: do not use cfs_lock_storage (replace with cfs_lock_ha)
    my $res = PVE::Cluster::cfs_lock_storage("_ha_crm_commands", undef, $code);
    die $@ if $@;
    return $res;
}

sub read_crm_commands {
    my ($self) = @_;

    my $code = sub {
	my $data = '';

 	my $filename = "/etc/pve/ha/crm_commands";
	if (-f $filename) {
	    $data = PVE::Tools::file_get_contents($filename);
	    PVE::Tools::file_set_contents($filename, '');
	}

	return $data;
    };

    # fixme: do not use cfs_lock_storage (replace with cfs_lock_ha)
    my $res = PVE::Cluster::cfs_lock_storage("_ha_crm_commands", undef, $code);
    die $@ if $@;
    return $res;
}

# this should return a hash containing info
# what nodes are members and online.
sub get_node_info {
    my ($self) = @_;

    my ($node_info, $quorate) = ({}, 0);
   
    my $nodename = $self->{nodename};

    $quorate = PVE::Cluster::check_cfs_quorum(1) || 0;

    my $members = PVE::Cluster::get_members();

    foreach my $node (keys %$members) {
	my $d = $members->{$node};
	$node_info->{$node}->{online} = $d->{online}; 
    }
	
    $node_info->{$nodename}->{online} = 1; # local node is always up
    
    return ($node_info, $quorate);
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    syslog($level, $msg);
}

my $last_lock_status = {};

sub get_pve_lock {
    my ($self, $lockid) = @_;

    my $got_lock = 0;

    my $filename = "$lockdir/$lockid";

    my $last = $last_lock_status->{$lockid} || 0;

    my $ctime = time();

    eval {

	mkdir $lockdir;

	# pve cluster filesystem not online
	die "can't create '$lockdir' (pmxcfs not mounted?)\n" if ! -d $lockdir;

	if ($last && (($ctime - $last) < 100)) { # fixme: what timeout
	    utime(0, $ctime, $filename) || # cfs lock update request
		die "cfs lock update failed - $!\n";
	} else {

	    # fixme: wait some time?
	    if (!(mkdir $filename)) {
		utime 0, 0, $filename; # cfs unlock request
		die "can't get cfs lock\n";
	    }
	}

	$got_lock = 1;
    };

    my $err = $@;

    $last_lock_status->{$lockid} = $got_lock ? $ctime : 0;

    if (!!$got_lock != !!$last) {
	if ($got_lock) {
	    $self->log('info', "successfully aquired lock '$lockid'");
	} else {
	    my $msg = "lost lock '$lockid";
	    $msg .= " - $err" if $err; 
	    $self->log('err', $msg);
	}
    }

    return $got_lock;
}

sub get_ha_manager_lock {
    my ($self) = @_;

    return $self->get_pve_lock("ha_manager_lock");
}

sub get_ha_agent_lock {
    my ($self) = @_;
    
    my $node = $self->nodename();

    return $self->get_pve_lock("ha_agent_${node}_lock");
}

sub test_ha_agent_lock {
    my ($self, $node) = @_;
    
    my $lockid = "ha_agent_${node}_lock";
    my $filename = "$lockdir/$lockid";
    my $res = $self->get_pve_lock($lockid);
    rmdir $filename if $res; # cfs unlock

    return $res;
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

my $watchdog_fh;

sub watchdog_open {
    my ($self) = @_;

    die "watchdog already open\n" if defined($watchdog_fh);

    $watchdog_fh = IO::Socket::UNIX->new(
	Type => SOCK_STREAM(),
	Peer => "/run/watchdog-mux.sock") ||
	die "unable to open watchdog socket - $!\n";
      
    $self->log('info', "watchdog active");
}

sub watchdog_update {
    my ($self, $wfh) = @_;

    my $res = $watchdog_fh->syswrite("\0", 1);
    if (!defined($res)) {
	$self->log('err', "watchdog update failed - $!\n");
	return 0;
    }
    if ($res != 1) {
	$self->log('err', "watchdog update failed - write $res bytes\n");
	return 0;
    }

    return 1;
}

sub watchdog_close {
    my ($self, $wfh) = @_;

    $watchdog_fh->syswrite("V", 1); # magic watchdog close
    if (!$watchdog_fh->close()) {
	$self->log('err', "watchdog close failed - $!");
    } else {
	$watchdog_fh = undef;
	$self->log('info', "watchdog closed (disabled)");
    }
}

sub exec_resource_agent {
    my ($self, $sid, $service_config, $cmd, @params) = @_;

    die "implement me";
}

1;
