package PVE::HA::SimEnv;

use strict;
use warnings;
use POSIX qw(strftime);
use Data::Dumper;

use PVE::HA::Env;

use base qw(PVE::HA::Env);

my $max_sim_time = 1000;

# time => quorate nodes (first node gets manager lock)
my $quorum_setup = [
    [ 100 , [ 'node1', 'node2' ]],
    [ 200 , [ 'node1', 'node2', 'node3' ]],
    [ 300 , [ 'node1', 'node2' ]],
    [ 400 , [ 'node1', 'node2', 'node3']],
    [ 900 , [ 'node2', 'node3' ]],
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

sub new {
    my ($this, $nodename) = @_;

    my $class = ref($this) || $this;

    my $self = $class->SUPER::new();

    $self->{nodename} = $nodename;

    &$compute_node_info();

    return $self;
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    my $time = $self->get_time();

    printf("%-5s %10d $self->{nodename}: $msg\n", $level, $time);
}

my $cur_time = 0;

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

    foreach my $entry (reverse @$quorum_setup) {
	my ($time, $members) = @$entry;

	if ($cur_time >= $time) {
	    ++$cur_time;
	    return 1 if $members->[0] eq $self->{nodename};
	    return 0;
	}
    }

    ++$cur_time;
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
