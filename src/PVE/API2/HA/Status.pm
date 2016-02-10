package PVE::API2::HA::Status;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::INotify;
use PVE::Cluster;
use PVE::HA::Config;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::HA::Env::PVE2;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $nodename = PVE::INotify::nodename();

my $timestamp_to_status = sub {
    my ($ctime, $timestamp) = @_;

    my $tdiff = $ctime - $timestamp;
    if ($tdiff > 30) {
	return "old timestamp - dead?";
    } elsif ($tdiff < -2) {
	return "detected time drift!";
    } else {
	return "active";
    }
};

__PACKAGE__->register_method ({
    name => 'index', 
    path => '', 
    method => 'GET',
    permissions => { user => 'all' },
    description => "Directory index.",
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {},
	},
	links => [ { rel => 'child', href => "{name}" } ],
    },
    code => sub {
	my ($param) = @_;
    
	my $result = [
	    { name => 'current' },
	    { name => 'manager_status' },
	    ];

	return $result;
    }});

__PACKAGE__->register_method ({
    name => 'status', 
    path => 'current',
    method => 'GET',
    description => "Get HA manger status.",
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => { type => 'array' },
    code => sub {
	my ($param) = @_;

	my $res = [];
	
	if (PVE::Cluster::check_cfs_quorum(1)) {
	    push @$res, { id => 'quorum', type => 'quorum', 
			  node => $nodename, status => "OK", quorate => 1 };
	} else {
	    push @$res, { id => 'quorum', type => 'quorum', node => $nodename, 
			  status => "No quorum on node '$nodename'!", quorate => 0 };
	}
	
	my $haenv = PVE::HA::Env::PVE2->new($nodename);
	
	my $status = $haenv->read_manager_status();

	my $ctime = $haenv->get_time();

	if (defined($status->{master_node}) && defined($status->{timestamp})) {
	    my $master = $status->{master_node};
	    my $status_str = &$timestamp_to_status($ctime, $status->{timestamp});
	    my $time_str = localtime($status->{timestamp});
	    my $status_text = "$master ($status_str, $time_str)";
	    push @$res, { id => 'master', type => 'master', node => $master, 
			  status => $status_text, timestamp => $status->{timestamp} };
	} 

	# compute active services for all nodes
	my $active_count = {};
	foreach my $sid (sort keys %{$status->{service_status}}) {
	    my $sd = $status->{service_status}->{$sid};
	    next if !$sd->{node};
	    $active_count->{$sd->{node}} = 0 if !defined($active_count->{$sd->{node}});
	    my $req_state = $sd->{state};
	    next if !defined($req_state);
	    next if $req_state eq 'stopped';
	    next if $req_state eq 'freeze';
	    $active_count->{$sd->{node}}++;
	}
	
	foreach my $node (sort keys %{$status->{node_status}}) {
	    my $lrm_status = $haenv->read_lrm_status($node);
	    my $id = "lrm:$node";
	    if (!$lrm_status->{timestamp}) {
		push @$res, { id => $id, type => 'lrm',  node => $node, 
			      status => "$node (unable to read lrm status)"}; 
	    } else {
		my $status_str = &$timestamp_to_status($ctime, $lrm_status->{timestamp});
		if ($status_str eq 'active') {
		    my $lrm_mode = $lrm_status->{mode} || 'active';
		    my $lrm_state = $lrm_status->{state} || 'unknown';
		    if ($lrm_mode ne 'active') {
			$status_str = "$lrm_mode mode";
		    } else {
			if ($lrm_state eq 'wait_for_agent_lock' && !$active_count->{$node}) {
			    $status_str = 'idle';
			} else {
			    $status_str = $lrm_state;
			}
		    }
		}

		my $time_str = localtime($lrm_status->{timestamp});
		my $status_text = "$node ($status_str, $time_str)";
		push @$res, { id => $id, type => 'lrm',  node => $node, 
			      status => $status_text, timestamp => $lrm_status->{timestamp} }; 
	    }
	}

	foreach my $sid (sort keys %{$status->{service_status}}) {
	    my $d = $status->{service_status}->{$sid};
	    push @$res, { id => "service:$sid", type => 'service', sid => $sid, 
			  node => $d->{node}, status => "$sid ($d->{node}, $d->{state})" };
	}
		
	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'manager_status', 
    path => 'manager_status',
    method => 'GET',
    description => "Get full HA manger status, including LRM status.",
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $haenv = PVE::HA::Env::PVE2->new($nodename);

	my $status = $haenv->read_manager_status();
	
	my $data = { manager_status => $status };

	$data->{quorum} = {
	    node => $nodename,
	    quorate => PVE::Cluster::check_cfs_quorum(1),
	};
	
	foreach my $node (sort keys %{$status->{node_status}}) {
	    my $lrm_status = $haenv->read_lrm_status($node);
	    $data->{lrm_status}->{$node} = $lrm_status;
	}

	return $data;
    }});

1;
