package PVE::HA::Sim::Hardware;

# Simulate Hardware resources

# power supply for nodes: on/off
# network connection to nodes: on/off
# watchdog devices for nodes

use strict;
use warnings;
use POSIX qw(strftime EINTR);
use Data::Dumper;
use JSON; 
use IO::File;
use Fcntl qw(:DEFAULT :flock);
use File::Copy;
use File::Path qw(make_path remove_tree);

my $watchdog_timeout = 60;


# Status directory layout
#
# configuration
#
# $testdir/cmdlist           Command list for simulation
# $testdir/hardware_status   Hardware description (number of nodes, ...)
# $testdir/manager_status    CRM status (start with {})
# $testdir/service_config    Service configuration

#
# runtime status for simulation system
#
# $testdir/status/cluster_locks        Cluster locks
# $testdir/status/hardware_status      Hardware status (power/network on/off)
# $testdir/status/watchdog_status      Watchdog status
#
# runtime status
#
# $testdir/status/local_status_<node>  local CRM Daemon status
# $testdir/status/manager_status       CRM status
# $testdir/status/service_config       Service configuration

sub read_hardware_status_nolock {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/hardware_status";

    my $raw = PVE::Tools::file_get_contents($filename);
    my $cstatus = decode_json($raw);

    return $cstatus;
}

sub write_hardware_status_nolock {
    my ($self, $cstatus) = @_;

    my $filename = "$self->{statusdir}/hardware_status";

    PVE::Tools::file_set_contents($filename, encode_json($cstatus));
};

sub new {
    my ($this, $testdir) = @_;

    die "missing testdir" if !$testdir;

    my $class = ref($this) || $this;

    my $self = bless {}, $class;

    my $statusdir = $self->{statusdir} = "$testdir/status";

    remove_tree($statusdir);
    mkdir $statusdir;

    # copy initial configuartion
    copy("$testdir/manager_status", "$statusdir/manager_status"); # optional
    copy("$testdir/service_config", "$statusdir/service_config"); # optional

    copy("$testdir/hardware_status", "$statusdir/hardware_status") ||
	die "Copy failed: $!\n";


    my $cstatus = $self->read_hardware_status_nolock();

    foreach my $node (sort keys %$cstatus) {
	$self->{nodes}->{$node} = {};
    }

    return $self;
}

sub get_time {
    my ($self) = @_;

    die "implement in subclass";
}

sub log {
    my ($self, $level, $msg, $id) = @_;

    chomp $msg;

    my $time = $self->get_time();

    $id = 'hardware' if !$id;

    printf("%-5s %5d %12s: $msg\n", $level, $time, $id);
}

sub statusdir {
    my ($self, $node) = @_;

    return $self->{statusdir};
}

sub global_lock {
    my ($self, $code, @param) = @_;

    my $lockfile = "$self->{statusdir}/hardware.lck";
    my $fh = IO::File->new(">>$lockfile") ||
	die "unable to open '$lockfile'\n";

    my $success;
    for (;;) {
	$success = flock($fh, LOCK_EX);
	if ($success || ($! != EINTR)) {
	    last;
	}
	if (!$success) {
	    die "can't aquire lock '$lockfile' - $!\n";
	}
    }
     
    my $res;

    eval { $res = &$code(@param) };
    my $err = $@;

    close($fh);

    die $err if $err;
    
    return $res;
}

my $compute_node_info = sub {
    my ($self, $cstatus) = @_;

    my $node_info = {};

    my $node_count = 0;
    my $online_count = 0;

    foreach my $node (keys %$cstatus) {
	my $d = $cstatus->{$node};

	my $online = ($d->{power} eq 'on' && $d->{network} eq 'on') ? 1 : 0;
	$node_info->{$node}->{online} = $online;

	$node_count++;
	$online_count++ if $online;
    }

    my $quorate = ($online_count > int($node_count/2)) ? 1 : 0;
		   
    if (!$quorate) {
	foreach my $node (keys %$cstatus) {
	    my $d = $cstatus->{$node};
	    $node_info->{$node}->{online} = 0;
	}
    }

    return ($node_info, $quorate);
};

sub get_node_info {
    my ($self) = @_;

    my ($node_info, $quorate);

    my $code = sub { 
	my $cstatus = $self->read_hardware_status_nolock();
	($node_info, $quorate) = &$compute_node_info($self, $cstatus); 
    };

    $self->global_lock($code);

    return ($node_info, $quorate);
}

# simulate hardware commands
# power <node> <on|off>
# network <node> <on|off>

sub sim_hardware_cmd {
    my ($self, $cmdstr, $logid) = @_;

    die "implement in subclass";
}

sub run {
    my ($self) = @_;

    die "implement in subclass";
}

my $modify_watchog = sub {
    my ($self, $code) = @_;

    my $update_cmd = sub {

	my $filename = "$self->{statusdir}/watchdog_status";
 
	my ($res, $wdstatus);

	if (-f $filename) {
	    my $raw = PVE::Tools::file_get_contents($filename);
	    $wdstatus = decode_json($raw);
	} else {
	    $wdstatus = {};
	}
	
	($wdstatus, $res) = &$code($wdstatus);

	PVE::Tools::file_set_contents($filename, encode_json($wdstatus));

	return $res;
    };

    return $self->global_lock($update_cmd);
};

sub watchdog_check {
    my ($self, $node) = @_;

    my $code = sub {
	my ($wdstatus) = @_;

	my $res = 1;

	foreach my $wfh (keys %$wdstatus) {
	    my $wd = $wdstatus->{$wfh};
	    next if $wd->{node} ne $node;

	    my $ctime = $self->get_time();
	    my $tdiff = $ctime - $wd->{update_time};

	    if ($tdiff > $watchdog_timeout) { # expired
		$res = 0;
		delete $wdstatus->{$wfh};
	    }
	}
	
	return ($wdstatus, $res);
    };

    return &$modify_watchog($self, $code);
}

my $wdcounter = 0;

sub watchdog_open {
    my ($self, $node) = @_;

    my $code = sub {
	my ($wdstatus) = @_;

	++$wdcounter;

	my $id = "WD:$node:$$:$wdcounter";

	die "internal error" if defined($wdstatus->{$id});

	$wdstatus->{$id} = {
	    node => $node,
	    update_time => $self->get_time(),
	};

	return ($wdstatus, $id);
    };

    return &$modify_watchog($self, $code);
}

sub watchdog_close {
    my ($self, $wfh) = @_;

    my $code = sub {
	my ($wdstatus) = @_;

	my $wd = $wdstatus->{$wfh};
	die "no such watchdog handle '$wfh'\n" if !defined($wd);

	my $tdiff = $self->get_time() - $wd->{update_time};
	die "watchdog expired" if $tdiff > $watchdog_timeout;

	delete $wdstatus->{$wfh};

	return ($wdstatus);
    };

    return &$modify_watchog($self, $code);
}

sub watchdog_update {
    my ($self, $wfh) = @_;

    my $code = sub {
	my ($wdstatus) = @_;

	my $wd = $wdstatus->{$wfh};

	die "no such watchdog handle '$wfh'\n" if !defined($wd);

	my $ctime = $self->get_time();
	my $tdiff = $ctime - $wd->{update_time};

	die "watchdog expired" if $tdiff > $watchdog_timeout;
	
	$wd->{update_time} = $ctime;

	return ($wdstatus);
    };

    return &$modify_watchog($self, $code);
}



1;
