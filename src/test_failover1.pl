#!/usr/bin/perl

use strict;
use warnings;

use lib '.';
use PVE::HA::Manager;

use Data::Dumper;

my $groups = {
    prefer_node1 => {
	nodes => 'node1',
    },
};


my $online_node_usage = {
    node1 => 0,
    node2 => 0,
    node3 => 0,
};

my $service_conf = {
    node => 'node1',
    group => 'prefer_node1',
};

my $current_node = $service_conf->{node};

sub test {
    my ($expected_node, $try_next) = @_;
    
    my $node = PVE::HA::Manager::select_service_node
	($groups, $online_node_usage, $service_conf, $current_node, $try_next);

    my (undef, undef, $line) = caller();
    die "unexpected result: $node != ${expected_node} at line $line\n" 
	if $node ne $expected_node;

    $current_node = $node;
}


test('node1');
test('node1', 1);

delete $online_node_usage->{node1}; # poweroff

test('node2');
test('node3', 1);
test('node2', 1);

delete $online_node_usage->{node2}; # poweroff

test('node3');
test('node3', 1);

$online_node_usage->{node1} = 0; # poweron

test('node1');

$online_node_usage->{node2} = 0; # poweron

test('node1');
test('node1', 1);
