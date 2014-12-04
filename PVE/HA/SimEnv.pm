package PVE::HA::SimEnv;

use strict;
use warnings;
use POSIX qw(strftime EINTR);
use Data::Dumper;
use JSON; 
use IO::File;
use Fcntl qw(:DEFAULT :flock);

use PVE::HA::Env;

use base qw(PVE::HA::Env);

my $max_sim_time = 1000;

my $read_cluster_status = sub {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/cluster_status";

    my $raw = PVE::Tools::file_get_contents($filename);
    my $cstatus = decode_json($raw);

    return $cstatus;
};

my $write_cluster_status = sub {
    my ($self, $cstatus) = @_;

    my $filename = "$self->{statusdir}/cluster_status";

    PVE::Tools::file_set_contents($filename, encode_json($cstatus));
};

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

sub new {
    my ($this, $testdir) = @_;

    my $class = ref($this) || $this;

    my $nodename = 'node1';
    if (-f "$testdir/hostname") {
	$nodename = PVE::Tools::file_read_firstline("$testdir/hostname");
    }

    my $statusdir = "$testdir/status";

    my $self = $class->SUPER::new($statusdir, $nodename);

    $self->{cur_time} = 0;
    $self->{loop_delay} = 0;

    if (-f "$testdir/cmdlist") {
	my $raw = PVE::Tools::file_get_contents("$testdir/cmdlist");
	$self->{cmdlist} = decode_json($raw);
    } else {
	$self->{cmdlist} = [];
    }

    $self->{loop_count} = 0;

    return $self;
}

sub sim_cluster_lock {
     my ($self, $code, @param) = @_;

     my $lockfile = "$self->{statusdir}/cluster.lck";
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

sub sim_get_lock {
    my ($self, $lock_name, $unlock) = @_;

    my $filename = "$self->{statusdir}/cluster_locks";

    my $code = sub {

	my $raw = "{}";
	$raw = PVE::Tools::file_get_contents($filename) if -f $filename; 

	my $data = decode_json($raw);

	my $res;

	my $nodename = $self->nodename();
	my $ctime = $self->get_time();

	if ($unlock) {

	    if (my $d = $data->{$lock_name}) {
		my $tdiff = $ctime - $d->{time};
	    
		if ($tdiff > 120) {
		    $res = 1;
		} elsif (($tdiff <= 120) && ($d->{node} eq $nodename)) {
		    delete $data->{$lock_name};
		    $res = 1;
		} else {
		    $res = 0;
		}
	    }

	} else {

	    if (my $d = $data->{$lock_name}) {
	    
		my $tdiff = $ctime - $d->{time};
	    
		if ($tdiff <= 120) {
		    if ($d->{node} eq $nodename) {
			$d->{time} = $ctime;
			$res = 1;
		    } else {
			$res = 0;
		    }
		} else {
		    $d->{node} = $nodename;
		    $res = 1;
		}

	    } else {
		$data->{$lock_name} = {
		    time => $ctime,
		    node => $nodename,
		};
		$res = 1;
	    }
	}

	$raw = encode_json($data);
	PVE::Tools::file_set_contents($filename, $raw);

	return $res;
    };

    return $self->sim_cluster_lock($code);
}

sub read_manager_status {
    my ($self) = @_;
    
    my $filename = "$self->{statusdir}/manager_status";

    my $raw = PVE::Tools::file_get_contents($filename);

    return decode_json($raw) || {};
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    my $data = encode_json($status_obj);
    my $filename = "$self->{statusdir}/manager_status";

    PVE::Tools::file_set_contents($filename, $data);
}

sub manager_status_exists {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/manager_status";
 
    return -f $filename ? 1 : 0;
}

my $read_service_status = sub {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/service_status";

    if (-f $filename) {
	my $raw = PVE::Tools::file_get_contents($filename);
	return decode_json($raw);
    } else {
	return {};
    }
};

my $write_service_status = sub {
    my ($self, $status_obj) = @_;

    my $data = encode_json($status_obj);
    my $filename = "$self->{statusdir}/service_status";

    PVE::Tools::file_set_contents($filename, $data);
};

sub read_service_config {
    my ($self) = @_;

    my $conf = {
	'pvevm:101' => {
	    type => 'pvevm',
	    name => '101',
	    state => 'enabled',
	},
	'pvevm:102' => {
	    type => 'pvevm',
	    name => '102',
	    state => 'disabled',
	},
	'pvevm:103' => {
	    type => 'pvevm',
	    name => '103',
	    state => 'enabled',
	},
    };

    my $rl = &$read_service_status($self);

    foreach my $sid (keys %$conf) {
	die "service '$sid' does not exists\n" 
	    if !($rl->{$sid} && $rl->{$sid}->{node});
    }

    foreach my $sid (keys %$rl) {
	next if !$conf->{$sid};
	$conf->{$sid}->{current_node} = $rl->{$sid}->{node};
	$conf->{$sid}->{node} = $conf->{$sid}->{current_node};
    }

    return $conf;
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    my $time = $self->get_time();

    printf("%-5s %10d $self->{nodename}: $msg\n", $level, $time);
}

sub get_time {
    my ($self) = @_;

    return $self->{cur_time};
}

sub sleep {
   my ($self, $delay) = @_;

   $self->{loop_delay} += $delay;
}

sub sleep_until {
   my ($self, $end_time) = @_;

   my $cur_time = $self->{cur_time} + $self->{loop_delay};

   return if $cur_time >= $end_time;

   $self->{loop_delay} += $end_time - $cur_time;
}

sub get_ha_manager_lock {
    my ($self) = @_;

    my $res = $self->sim_get_lock('ha_manager_lock');
    ++$self->{loop_delay};
    return $res;
}

sub test_ha_agent_lock {
    my ($self, $node) = @_;

    my $lck = "ha_agent_${node}_lock";
    my $res = $self->sim_get_lock($lck);
    $self->sim_get_lock($lck, 1) if $res; # unlock

    ++$self->{loop_delay};
    return $res;
}

# return true when cluster is quorate
sub quorate {
    my ($self) = @_;

    my $code = sub { 
	my $cstatus = &$read_cluster_status($self);
	my ($node_info, $quorate) = &$compute_node_info($self, $cstatus); 
	return $quorate;
    };
    return $self->sim_cluster_lock($code);
}

sub get_node_info {
    my ($self) = @_;

    my $code = sub { 
	my $cstatus = &$read_cluster_status($self);
	my ($node_info, $quorate) = &$compute_node_info($self, $cstatus); 
	return $node_info;
    };
    return $self->sim_cluster_lock($code);
}

sub loop_start_hook {
    my ($self) = @_;

    $self->{loop_delay} = 0;

    # apply new comand after 5 loop iterations

    if (($self->{loop_count} % 5) == 0) {
	my $list = shift $self->{cmdlist};
	return if !$list;

	foreach my $cmd (@$list) {
	    $self->sim_cluster_cmd($cmd);
	}
    }

    # do nothing
}

sub loop_end_hook {
    my ($self) = @_;

    ++$self->{loop_count};

    my $delay = $self->{loop_delay};
    $self->{loop_delay} = 0;

    die "loop take too long ($delay seconds)\n" if $delay > 30;

    $self->{cur_time} += $delay;

    die "simulation end\n" if $self->{cur_time} > $max_sim_time;
}

# simulate cluster commands
# power <node> <on|off>
# network <node> <on|off>

sub sim_cluster_cmd {
    my ($self, $cmdstr) = @_;

    my $code = sub {

	my $cstatus = &$read_cluster_status($self);

	my ($cmd, $node, $action) = split(/\s+/, $cmdstr);

	die "sim_cluster_cmd: no node specified" if !$node;
	die "sim_cluster_cmd: unknown action '$action'" if $action !~ m/^(on|off)$/;

	if ($cmd eq 'power') {
		$cstatus->{$node}->{power} = $action;
		$cstatus->{$node}->{network} = $action;
	} elsif ($cmd eq 'network') {
		$cstatus->{$node}->{network} = $action;
	} else {
	    die "sim_cluster_cmd: unknown command '$cmd'\n";
	}

	$self->log('info', "execute $cmdstr");

	&$write_cluster_status($self, $cstatus);
    };

    return $self->sim_cluster_lock($code);
}


1;
