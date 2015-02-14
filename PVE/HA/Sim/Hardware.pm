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
# $testdir/cmdlist                    Command list for simulation
# $testdir/hardware_status            Hardware description (number of nodes, ...)
# $testdir/manager_status             CRM status (start with {})
# $testdir/service_config             Service configuration
# $testdir/service_status_<node>      Service status

#
# runtime status for simulation system
#
# $testdir/status/cluster_locks        Cluster locks
# $testdir/status/hardware_status      Hardware status (power/network on/off)
# $testdir/status/watchdog_status      Watchdog status
#
# runtime status
#
# $testdir/status/lrm_status_<node>           LRM status
# $testdir/status/manager_status              CRM status
# $testdir/status/service_config              Service configuration
# $testdir/status/service_status_<node>       Service status

sub read_lrm_status {
    my ($self, $node) = @_;

    my $filename = "$self->{statusdir}/lrm_status_$node";

    return PVE::HA::Tools::read_json_from_file($filename, {});  
}

sub write_lrm_status {
    my ($self, $node, $status_obj) = @_;

    my $filename = "$self->{statusdir}/lrm_status_$node";

    PVE::HA::Tools::write_json_to_file($filename, $status_obj); 
}

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

sub read_service_config {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/service_config";
    my $conf = PVE::HA::Tools::read_json_from_file($filename); 

    foreach my $sid (keys %$conf) {
	my $d = $conf->{$sid};

	die "service '$sid' without assigned node!" if !$d->{node};

	if ($sid =~ m/^pvevm:(\d+)$/) {
	    $d->{type} = 'pvevm'; 
	    $d->{name} = $1;
	} else {
	    die "implement me";
	}
	$d->{state} = 'disabled' if !$d->{state};
    }

    return $conf;
}

sub write_service_config {
    my ($self, $conf) = @_;

    $self->{service_config} = $conf;

    my $filename = "$self->{statusdir}/service_config";
    return PVE::HA::Tools::write_json_to_file($filename, $conf);
} 

sub change_service_location {
    my ($self, $sid, $node) = @_;

    my $conf = $self->read_service_config();

    die "no such service '$sid'\n" if !$conf->{$sid};

    $conf->{$sid}->{node} = $node;

    $self->write_service_config($conf);
}

sub read_service_status {
    my ($self, $node) = @_;

    my $filename = "$self->{statusdir}/service_status_$node";
    return PVE::HA::Tools::read_json_from_file($filename); 
}

sub write_service_status {
    my ($self, $node, $data) = @_;

    my $filename = "$self->{statusdir}/service_status_$node";
    my $res = PVE::HA::Tools::write_json_to_file($filename, $data);

    # fixme: add test if a service runs on two nodes!!!

    return $res;
} 

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

    if (-f "$testdir/service_config") {
	copy("$testdir/service_config", "$statusdir/service_config");
    } else {
	my $conf = {
	    'pvevm:101' => { node => 'node1' },
	    'pvevm:102' => { node => 'node2' },
	    'pvevm:103' => { node => 'node3' },
	    'pvevm:104' => { node => 'node1' },
	    'pvevm:105' => { node => 'node2' },
	    'pvevm:106' => { node => 'node3' },
	};
	$self->write_service_config($conf);
    }

    if (-f "$testdir/hardware_status") {
	copy("$testdir/hardware_status", "$statusdir/hardware_status") ||
	    die "Copy failed: $!\n";
    } else {
	my $cstatus = {
	    node1 => { power => 'off', network => 'off' },
	    node2 => { power => 'off', network => 'off' },
	    node3 => { power => 'off', network => 'off' },
	};
	$self->write_hardware_status_nolock($cstatus);
    }


    my $cstatus = $self->read_hardware_status_nolock();

    foreach my $node (sort keys %$cstatus) {
	$self->{nodes}->{$node} = {};

	if (-f "$testdir/service_status_$node") {
	    copy("$testdir/service_status_$node", "$statusdir/service_status_$node");
	} else {	
	    $self->write_service_status($node, {});
	}
    }

    $self->{service_config} = $self->read_service_config();

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
	    close($fh);
	    die "can't aquire lock '$lockfile' - $!\n";
	}
    }

    my $res;

    eval { $res = &$code($fh, @param) };
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
