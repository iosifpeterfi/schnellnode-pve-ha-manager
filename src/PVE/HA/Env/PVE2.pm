package PVE::HA::Env::PVE2;

use strict;
use warnings;
use POSIX qw(:errno_h :fcntl_h);
use IO::File;
use IO::Socket::UNIX;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_write_file cfs_lock_file);
use PVE::INotify;
use PVE::RPCEnvironment;

use PVE::HA::Tools ':exit_codes';
use PVE::HA::Env;
use PVE::HA::Config;


my $lockdir = "/etc/pve/priv/lock";

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

    return PVE::HA::Config::read_manager_status();
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    PVE::HA::Config::write_manager_status($status_obj);
}

sub read_lrm_status {
    my ($self, $node) = @_;

    $node = $self->{nodename} if !defined($node);

    return PVE::HA::Config::read_lrm_status($node);
}

sub write_lrm_status {
    my ($self, $status_obj) = @_;

    my $node = $self->{nodename};

    PVE::HA::Config::write_lrm_status($node, $status_obj);
}

sub is_node_shutdown {
    my ($self) = @_;

    my $shutdown = 0;

    my $code = sub {
	my $line = shift;

	$shutdown = 1 if ($line =~ m/shutdown\.target/);
    };

    my $cmd = ['/bin/systemctl', 'list-jobs'];
    eval { PVE::Tools::run_command($cmd, outfunc => $code, noerr => 1); };

    return $shutdown;
}

sub queue_crm_commands {
    my ($self, $cmd) = @_;

    return PVE::HA::Config::queue_crm_commands($cmd);
}

sub read_crm_commands {
    my ($self) = @_;

    return PVE::HA::Config::read_crm_commands();
}

sub service_config_exists {
    my ($self) = @_;

    return PVE::HA::Config::resources_config_exists();
}

sub read_service_config {
    my ($self) = @_;

    my $res = PVE::HA::Config::read_resources_config();

    my $vmlist = PVE::Cluster::get_vmlist();
    my $conf = {};

    foreach my $sid (keys %{$res->{ids}}) {
	my $d = $res->{ids}->{$sid};
	my (undef, undef, $name) = PVE::HA::Tools::parse_sid($sid);
	$d->{state} = 'enabled' if !defined($d->{state});
	$d->{max_restart} = 1 if !defined($d->{max_restart});
	$d->{max_relocate} = 1 if !defined($d->{max_relocate});
	if (PVE::HA::Resources->lookup($d->{type})) {
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
    my ($self, $sid, $current_node, $new_node) = @_;

    my (undef, $type, $name) = PVE::HA::Tools::parse_sid($sid);

    if(my $plugin = PVE::HA::Resources->lookup($type)) {
	my $old = $plugin->config_file($name, $current_node);
	my $new = $plugin->config_file($name, $new_node);
	rename($old, $new) ||
	    die "rename '$old' to '$new' failed - $!\n";
    } else {
	die "implement me";
    }
}

sub read_group_config {
    my ($self) = @_;

    return PVE::HA::Config::read_group_config();
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

    my $retry = 0;
    my $retry_timeout = 100; # fixme: what timeout

    eval {

	mkdir $lockdir;

	# pve cluster filesystem not online
	die "can't create '$lockdir' (pmxcfs not mounted?)\n" if ! -d $lockdir;

	if ($last && (($ctime - $last) < $retry_timeout)) {
	     # send cfs lock update request (utime)
	    if (!utime(0, $ctime, $filename))  {
		$retry = 1;
		die "cfs lock update failed - $!\n";
	    }
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

    if ($retry) {
	# $self->log('err', $err) if $err; # for debugging
	return 0;
    }

    $last_lock_status->{$lockid} = $got_lock ? $ctime : 0;

    if (!!$got_lock != !!$last) {
	if ($got_lock) {
	    $self->log('info', "successfully acquired lock '$lockid'");
	} else {
	    my $msg = "lost lock '$lockid";
	    $msg .= " - $err" if $err;
	    $self->log('err', $msg);
	}
    } else {
	# $self->log('err', $err) if $err; # for debugging
    }

    return $got_lock;
}

sub get_ha_manager_lock {
    my ($self) = @_;

    return $self->get_pve_lock("ha_manager_lock");
}

# release the cluster wide manager lock.
# when released another CRM may step up and get the lock, thus this should only
# get called when shutting down/deactivating the current master
sub release_ha_manager_lock {
    my ($self) = @_;

    return rmdir("$lockdir/ha_manager_lock");
}

sub get_ha_agent_lock {
    my ($self, $node) = @_;

    $node = $self->nodename() if !defined($node);

    return $self->get_pve_lock("ha_agent_${node}_lock");
}

# release the respective node agent lock.
# this should only get called if the nodes LRM gracefully shuts down with
# all services already cleanly stopped!
sub release_ha_agent_lock {
    my ($self) = @_;

    my $node = $self->nodename();

    return rmdir("$lockdir/ha_agent_${node}_lock");
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

    my (undef, $service_type, $service_name) = PVE::HA::Tools::parse_sid($sid);

    my $plugin = PVE::HA::Resources->lookup($service_type);
    if (!$plugin) {
	$self->log('err', "service type '$service_type' not implemented");
	return EUNKNOWN_SERVICE_TYPE;
    }

    if ($service_config->{node} ne $nodename) {
	$self->log('err', "service '$sid' not on this node");
	return EWRONG_NODE;
    }

    my $vmid = $service_name;

    my $running = $plugin->check_running($vmid);

    if ($cmd eq 'started') {

	return SUCCESS if $running;

	$self->log("info", "starting service $sid");

	$plugin->start($self, $vmid);

	$running = $plugin->check_running($vmid);

	if ($running) {
	    $self->log("info", "service status $sid started");
	    return SUCCESS;
	} else {
	    $self->log("warning", "unable to start service $sid");
	    return ERROR;
	}

    } elsif ($cmd eq 'request_stop' || $cmd eq 'stopped') {

	return SUCCESS if !$running;

	$self->log("info", "stopping service $sid");

	$plugin->shutdown($self, $vmid);

	$running = $plugin->check_running($vmid);

	if (!$running) {
	    $self->log("info", "service status $sid stopped");
	    return SUCCESS;
	} else {
	    $self->log("info", "unable to stop stop service $sid (still running)");
	    return ERROR;
	}

    } elsif ($cmd eq 'migrate' || $cmd eq 'relocate') {

	my $target = $params[0];
	if (!defined($target)) {
	    die "$cmd '$sid' failed - missing target\n" if !defined($target);
	    return EINVALID_PARAMETER;
	}

	if ($service_config->{node} eq $target) {
	    # already there
	    return SUCCESS;
	}

	my $online = ($cmd eq 'migrate') ? 1 : 0;

	my $oldconfig = $plugin->config_file($vmid, $nodename);

	$plugin->migrate($self, $vmid, $target, $online);

	# something went wrong if old config file is still there
	if (-f $oldconfig) {
	    $self->log("err", "service $sid not moved (migration error)");
	    return ERROR;
	}

	return SUCCESS;

    } elsif ($cmd eq 'error') {

	if ($running) {
	    $self->log("err", "service $sid is in an error state while running");
	} else {
	    $self->log("warning", "service $sid is not running and in an error state");
	}
	return SUCCESS; # error always succeeds

    }

    $self->log("err", "implement me (cmd '$cmd')");
    return EUNKNOWN_COMMAND;
}

1;
