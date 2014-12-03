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

my $cur_time = 0;

my $max_sim_time = 1000;



# time => quorate nodes (first node gets manager lock)
my $quorum_setup = [];

my $compute_node_info = sub {

    my $last_node_info = {};

    foreach my $entry (@$quorum_setup) {
	my ($time, $members) = @$entry;

	$max_sim_time = $time + 1000;

	my $node_info = {};

	foreach my $node (@$members) {
	    $node_info->{$node}->{online} = 1;
	    if (!$last_node_info->{$node}) {
		$node_info->{$node}->{join_time} = $time;
	    } else {
		$node_info->{$node}->{join_time} =
		    $last_node_info->{$node}->{join_time};
	    }
	}

	push @$entry, $node_info;

	$last_node_info = $node_info;
    }
};

my $lookup_quorum_info = sub {
    my ($self) = @_;

    foreach my $entry (reverse @$quorum_setup) {
	my ($time, $members) = @$entry;

	if ($cur_time >= $time) {
	    return $members;
	}
    }
    
    return undef;
};

sub new {
    my ($this, $testdir) = @_;

    my $class = ref($this) || $this;

    my $nodename = 'node1';
    if (-f "$testdir/hostname") {
	$nodename = PVE::Tools::file_read_firstline("$testdir/hostname");
    }

    if (-f "$testdir/membership") {
	my $raw = PVE::Tools::file_get_contents("$testdir/membership");
	$quorum_setup = decode_json($raw);
    }

    my $statusdir = "$testdir/status";

    my $self = $class->SUPER::new($statusdir, $nodename);

    &$compute_node_info();

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
    my ($self, $lock_name) = @_;

    my $filename = "$self->{statusdir}/cluster_locks";

    my $code = sub {

	my $raw = "{}";
	$raw = PVE::Tools::file_get_contents($filename) if -f $filename; 

	my $data = decode_json($raw);

	my $res;

	my $nodename = $self->nodename();
	my $ctime = $self->get_time();

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
	
	$raw = encode_json($data);
	PVE::Tools::file_set_contents($filename, $raw);

	return $res;
    };

    $self->sim_cluster_lock($code);
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

    return $cur_time;
}

sub sleep {
   my ($self, $delay) = @_;

   $cur_time += $delay;
}

sub get_ha_manager_lock {
    my ($self) = @_;

    my $res = $self->sim_get_lock('ha_manager_lock');
    ++$cur_time;
    return $res;
}

# return true when cluster is quorate
sub quorate {
    my ($self) = @_;

    if (my $members = &$lookup_quorum_info($self)) {
	foreach my $node (@$members) {
	    return 1 if $node eq $self->{nodename};
	}
    }

    return 0;
}

sub get_node_info {
    my ($self) = @_;

    foreach my $entry (reverse @$quorum_setup) {
	my ($time, $members, $node_info) = @$entry;

	if ($cur_time >= $time) {
	    return $node_info;
	}
    }

    die "unbale to get node info";
}

sub loop_start_hook {
    my ($self) = @_;

    $self->{loop_start_time} = $cur_time;

    # do nothing
}

sub loop_end_hook {
    my ($self) = @_;

    my $delay = $cur_time - $self->{loop_start_time};

    die "loop take too long ($delay seconds)\n" if $delay > 30;

    die "simulation end\n" if $cur_time > $max_sim_time;
}

1;
