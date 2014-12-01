package PVE::HA::SimEnv;

use strict;
use warnings;
use POSIX qw(strftime);
use Data::Dumper;
use JSON; 

use PVE::HA::Env;

use base qw(PVE::HA::Env);

my $cur_time = 0;

my $max_sim_time = 5000;

# time => quorate nodes (first node gets manager lock)
my $quorum_setup = [
    [ 100 , [ 'node1', 'node2' ]],
    [ 200 , [ 'node1', 'node2', 'node3' ]],
    [ 300 , [ 'node1', 'node2' ]],
    [ 400 , [ 'node1', 'node2', 'node3']],
    [ 900 , [ 'node2', 'node3' ]],
    [ 1000 , [ 'node2', 'node3', 'node1' ]],
    [ 1100 , [ 'node1', 'node2', 'node3' ]],

    [ 4800 , [ 'node2', 'node3' ]],
];

my $compute_node_info = sub {

    my $last_node_info = {};

    foreach my $entry (@$quorum_setup) {
	my ($time, $members) = @$entry;

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

my $node_is_lock_owner = sub {
   my ($self) = @_;

   if (my $members = &$lookup_quorum_info($self)) {
       return $members->[0] eq $self->{nodename} ? 1 : 0;
   }

   return 0;
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

    &$compute_node_info();

    return $self;
}

sub read_manager_status {
    my ($self) = @_;

    die "detected read without lock\n" 
	if !&$node_is_lock_owner($self);
    
    my $filename = "$self->{statusdir}/manager_status";

    my $raw = PVE::Tools::file_get_contents($filename);

    my $data = decode_json($raw) || {};
 
    return $data;
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    die "detected write without lock\n" 
	if !&$node_is_lock_owner($self);

    my $data = encode_json($status_obj);
    my $filename = "$self->{statusdir}/manager_status";

    PVE::Tools::file_set_contents($filename, $data);
}

sub manager_status_exists {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/manager_status";
 
    return -f $filename ? 1 : 0;
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

    my $res = &$node_is_lock_owner($self);
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
