package PVE::HA::Env::PVE2;

use strict;
use warnings;
use POSIX qw(:errno_h :fcntl_h);
use IO::File;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file);

use PVE::HA::Tools;
use PVE::HA::Env;
use PVE::HA::Groups;

my $lockdir = "/etc/pve/priv/lock";

my $manager_status_filename = "/etc/pve/manager_status";
my $ha_groups_config = "ha/groups.cfg";

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

    die "implement me";
}

sub change_service_location {
    my ($self, $sid, $node) = @_;

    die "implement me";
}

sub read_group_config {
    my ($self) = @_;

    return cfs_read_file($ha_groups_config);
}

sub queue_crm_commands {
    my ($self, $cmd) = @_;

    die "implement me";
}

sub read_crm_commands {
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

    if ($got_lock != $last) {
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

    my $lockid = "ha_manager_lock";

    my $filename = "$lockdir/$lockid";

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

my $WDIOC_GETSUPPORT =  0x80285700;
my $WDIOC_KEEPALIVE = 0x80045705;
my $WDIOC_SETTIMEOUT = 0xc0045706;
my $WDIOC_GETTIMEOUT = 0x80045707;

sub watchdog_open {
    my ($self) = @_;

    system("modprobe -q softdog soft_noboot=1") if ! -e "/dev/watchdog";

    die "watchdog already open\n" if defined($watchdog_fh);

    $watchdog_fh = IO::File->new(">/dev/watchdog") ||
	die "unable to open watchdog device - $!\n";
    
    eval {
	my $timeoutbuf = pack('I', 100);
	my $res = ioctl($watchdog_fh, $WDIOC_SETTIMEOUT, $timeoutbuf) ||
	    die "unable to set watchdog timeout - $!\n";
	my $timeout = unpack("I", $timeoutbuf);
	die "got wrong watchdog timeout '$timeout'\n" if $timeout != 100;

	my $wdinfo = "\x00" x 40;
	$res = ioctl($watchdog_fh, $WDIOC_GETSUPPORT, $wdinfo) ||
	    die "unable to get watchdog info - $!\n";

	my ($options, $firmware_version, $indentity) = unpack("lla32", $wdinfo);
	die "watchdog does not support magic close\n" if !($options & 0x0100);

    };
    if (my $err = $@) {
	$self->watchdog_close();
	die $err;
    }

    # fixme: use ioctl to setup watchdog timeout (requires C interface)
  
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
    my ($self, $sid, $cmd, @params) = @_;

    die "implement me";
}

1;
