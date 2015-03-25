package PVE::HA::Env::PVE2;

use strict;
use warnings;
use POSIX qw(:errno_h :fcntl_h);
use IO::File;
use IO::Socket::UNIX;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file);
use PVE::INotify;
use PVE::RPCEnvironment;

use PVE::HA::Tools;
use PVE::HA::Env;
use PVE::HA::Config;

use PVE::QemuServer;
use PVE::API2::Qemu;

my $lockdir = "/etc/pve/priv/lock";

my $manager_status_filename = "/etc/pve/ha/manager_status";
my $ha_groups_config = "/etc/pve/ha/groups.cfg";
my $ha_resources_config = "/etc/pve/ha/resources.cfg";

# fixme:
#cfs_register_file($ha_groups_config, 
#		  sub { PVE::HA::Groups->parse_config(@_); },
#		  sub { PVE::HA::Groups->write_config(@_); });
#cfs_register_file($ha_resources_config, 
#		  sub { PVE::HA::Resources->parse_config(@_); },
#		  sub { PVE::HA::Resources->write_config(@_); });

sub read_resources_config {
    my $raw = '';

    $raw = PVE::Tools::file_get_contents($ha_resources_config)
	if -f $ha_resources_config;
    
    return PVE::HA::Config::parse_resources_config($ha_resources_config, $raw);
}

sub write_resources_config {
    my ($cfg) = @_;

    my $raw = PVE::HA::Resources->write_config($ha_resources_config, $cfg);
    PVE::Tools::file_set_contents($ha_resources_config, $raw);
}

sub lock_ha_config {
    my ($code, $errmsg) = @_;

    # fixme: do not use cfs_lock_storage (replace with cfs_lock_ha)
    my $res = PVE::Cluster::cfs_lock_storage("_ha_crm_commands", undef, $code);
    my $err = $@;
    if ($err) {
	$errmsg ? die "$errmsg: $err" : die $err;
    }
    return $res;
}

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

sub service_config_exists {
    my ($self) = @_;

    return -f $ha_resources_config ? 1 : 0;
}

sub read_service_config {
    my ($self) = @_;

    my $res = read_resources_config();

    my $vmlist = PVE::Cluster::get_vmlist();
    my $conf = {};

    foreach my $sid (keys %{$res->{ids}}) {
	my $d = $res->{ids}->{$sid};
	my $name = PVE::HA::Tools::parse_sid($sid);
	$d->{state} = 'enabled' if !defined($d->{state});
	if ($d->{type} eq 'pvevm') {
	    if (my $vmd = $vmlist->{ids}->{$name}) {
		if (!$vmd) {
		    warn "no such VM '$name'\n";
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

    return lock_ha_config($code);
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

    return lock_ha_config($code);
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
    my ($self, $node) = @_;
    
    $node = $self->nodename() if !defined($node);

    return $self->get_pve_lock("ha_agent_${node}_lock");
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

sub upid_wait {
    my ($self, $upid) = @_;

    my $task = PVE::Tools::upid_decode($upid);

    CORE::sleep(1);
    while (PVE::ProcFSTools::check_process_running($task->{pid}, $task->{pstart})) {
	$self->log('debug', "Task still active, waiting");
	CORE::sleep(1);
    }
}

sub can_fork {
    my ($self) = @_;

    return 1;
}

sub exec_resource_agent {
    my ($self, $sid, $service_config, $cmd, @params) = @_;

    # setup execution environment
    
    $ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';

    PVE::INotify::inotify_close();
    
    PVE::INotify::inotify_init();

    PVE::Cluster::cfs_update();
 
    my $nodename = $self->{nodename};

    # fixme: return valid_exit code (instead of using die) ?

    my ($service_type, $service_name) = PVE::HA::Tools::parse_sid($sid);

    die "service type '$service_type'not implemented" if $service_type ne 'pvevm';

    my $vmid = $service_name;

    my $running = PVE::QemuServer::check_running($vmid, 1);
 
    if ($cmd eq 'started') {

	# fixme: return valid_exit code
	die "service '$sid' not on this node" if $service_config->{node} ne $nodename;

	# fixme: count failures
	
	return 0 if $running;

	$self->log("info", "starting service $sid");

	my $upid = PVE::API2::Qemu->vm_start({node => $nodename, vmid => $vmid});
	$self->upid_wait($upid);

	$running = PVE::QemuServer::check_running($vmid, 1);

	if ($running) {
	    $self->log("info", "service status $sid started");
	    return 0;
	} else {
	    $self->log("info", "unable to start service $sid");
	    return 1;
	}

    } elsif ($cmd eq 'request_stop' || $cmd eq 'stopped') {

	# fixme: return valid_exit code
	die "service '$sid' not on this node" if $service_config->{node} ne $nodename;

	return 0 if !$running;

	$self->log("info", "stopping service $sid");

	my $timeout = 60; # fixme: make this configurable
	
	my $param = {
	    node => $nodename, 
	    vmid => $vmid, 
	    timeout => $timeout,
	    forceStop => 1,
	};

	my $upid = PVE::API2::Qemu->vm_shutdown($param);
	$self->upid_wait($upid);

	$running = PVE::QemuServer::check_running($vmid, 1);

	if (!$running) {
	    $self->log("info", "service status $sid stopped");
	    return 0;
	} else {
	    return 1;
	}

    } elsif ($cmd eq 'migrate' || $cmd eq 'relocate') {

	# implement me
	
    }

    die "implement me (cmd '$cmd')";
}

1;
