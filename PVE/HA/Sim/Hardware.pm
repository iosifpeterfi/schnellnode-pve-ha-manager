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

my $max_sim_time = 10000;

use PVE::HA::Sim::Env;
use PVE::HA::Server;

# Status directory layout
#
# configuration
#
# $testdir/cmdlist   Command list for simulation
#
# runtime status
# $testdir/status/

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

    $self->{cur_time} = 0;

    if (-f "$testdir/cmdlist") {
	my $raw = PVE::Tools::file_get_contents("$testdir/cmdlist");
	$self->{cmdlist} = decode_json($raw);
    } else {
	$self->{cmdlist} = []; # fixme: interactive mode
    }

    # copy initial configuartion
    copy("$testdir/manager_status", "$statusdir/manager_status"); # optional
    copy("$testdir/service_status", "$statusdir/service_status"); # optional

    copy("$testdir/hardware_status", "$statusdir/hardware_status") ||
	die "Copy failed: $!\n";

    $self->{loop_count} = 0;

    my $cstatus = $self->read_hardware_status_nolock();

    foreach my $node (sort keys %$cstatus) {

	my $haenv = PVE::HA::Sim::Env->new($self, $node);
	die "HA is not enabled\n" if !$haenv->manager_status_exists();

	$haenv->log('info', "starting server");
	my $server = PVE::HA::Server->new($haenv);

	$self->{nodes}->{$node}->{haenv} = $haenv;
	$self->{nodes}->{$node}->{server} = undef; # create on power on
    }

    return $self;
}

sub get_time {
    my ($self) = @_;

    return $self->{cur_time};
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    my $time = $self->get_time();

    printf("%-5s %5d %10s: $msg\n", $level, $time, 'hardware');
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
    my ($self, $cmdstr) = @_;

    my $code = sub {

	my $cstatus = $self->read_hardware_status_nolock();

	my ($cmd, $node, $action) = split(/\s+/, $cmdstr);

	die "sim_hardware_cmd: no node specified" if !$node;
	die "sim_hardware_cmd: unknown action '$action'" if $action !~ m/^(on|off)$/;

	my $haenv = $self->{nodes}->{$node}->{haenv};
	die "sim_hardware_cmd: no such node '$node'\n" if !$haenv;
	
	if ($cmd eq 'power') {
	    if ($cstatus->{$node}->{power} ne $action) {
		if ($action eq 'on') {
		    my $server = $self->{nodes}->{$node}->{server} = PVE::HA::Server->new($haenv);
		} elsif ($self->{nodes}->{$node}->{server}) {
		    $haenv->log('info', "server killed by poweroff");
		    $self->{nodes}->{$node}->{server} = undef;
		}
	    }

	    $cstatus->{$node}->{power} = $action;
	    $cstatus->{$node}->{network} = $action;

	} elsif ($cmd eq 'network') {
		$cstatus->{$node}->{network} = $action;
	} else {
	    die "sim_hardware_cmd: unknown command '$cmd'\n";
	}

	$self->log('info', "execute $cmdstr");

	$self->write_hardware_status_nolock($cstatus);
    };

    return $self->global_lock($code);
}

sub run {
    my ($self) = @_;

    for (;;) {

	my $starttime = $self->get_time();

	foreach my $node (sort keys %{$self->{nodes}}) {
	    my $haenv = $self->{nodes}->{$node}->{haenv};
	    my $server = $self->{nodes}->{$node}->{server};

	    next if !$server;

	    $haenv->loop_start_hook($self->get_time());

	    die "implement me" if !$server->do_one_iteration();

	    $haenv->loop_end_hook();

	    my $nodetime = $haenv->get_time();
	    $self->{cur_time} = $nodetime if $nodetime > $self->{cur_time};
	}

	$self->{cur_time} = $starttime + 20 if ($self->{cur_time} - $starttime) < 20;

	die "simulation end\n" if $self->{cur_time} > $max_sim_time;

	# apply new comand after 5 loop iterations

	if (($self->{loop_count} % 5) == 0) {
	    my $list = shift $self->{cmdlist};
	    return if !$list;

	    foreach my $cmd (@$list) {
		$self->sim_hardware_cmd($cmd);
	    }
	}

	++$self->{loop_count};
    }
}
 


1;
