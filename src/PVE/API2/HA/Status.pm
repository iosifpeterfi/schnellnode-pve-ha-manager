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
    name => 'status', 
    path => '',
    method => 'GET',
    description => "Get HA manger status.",
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
	
	foreach my $node (sort keys %{$status->{node_status}}) {
	    my $lrm_status = $haenv->read_lrm_status($node);
	    my $id = "lrm:$node";
	    if (!$lrm_status->{timestamp}) {
		push @$res, { id => $id, type => 'lrm',  node => $node, 
			      status => "$node (unable to read lrm status)"}; 
	    } else {
		my $status_str = &$timestamp_to_status($ctime, $lrm_status->{timestamp});
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



1;
