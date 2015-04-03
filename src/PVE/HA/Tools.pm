package PVE::HA::Tools;

use strict;
use warnings;
use JSON;
use PVE::JSONSchema;
use PVE::Tools;

PVE::JSONSchema::register_format('pve-ha-resource-id', \&pve_verify_ha_resource_id);
sub pve_verify_ha_resource_id {
    my ($sid, $noerr) = @_;

    if ($sid !~ m/^[a-z]+:\S+$/) {
	return undef if $noerr;
	die "value does not look like a valid ha resource id\n";
    }
    return $sid;
}

PVE::JSONSchema::register_standard_option('pve-ha-resource-id', {
    description => "HA resource ID. This consists of a resource type followed by a resource specific name, separated with collon (example: vm:100).",
    typetext => "<type>:<name>",
    type => 'string', format => 'pve-ha-resource-id',					 
});

PVE::JSONSchema::register_format('pve-ha-group-node', \&pve_verify_ha_group_node);
sub pve_verify_ha_group_node {
    my ($node, $noerr) = @_;

    if ($node !~ m/^([a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)(:\d+)?$/) {
	return undef if $noerr;
	die "value does not look like a valid ha group node\n";
    }
    return $node;
}

PVE::JSONSchema::register_standard_option('pve-ha-group-node-list', {
    description => "List of cluster node names with optional priority. We use priority '0' as default. The CRM tries to run services on the node with higest priority (also see option 'nofailback').",
    type => 'string', format => 'pve-ha-group-node-list',
    typetext => '<node>[:<pri>]{,<node>[:<pri>]}*',
});

PVE::JSONSchema::register_standard_option('pve-ha-group-id', {
    description => "The HA group identifier.",
    type => 'string', format => 'pve-configid',
});

sub parse_sid {
    my ($sid) = @_;

    my ($type, $name) = split(':', $sid, 2);

    return wantarray ? ($type, $name) : $name;
}

sub read_json_from_file {
    my ($filename, $default) = @_;

    my $data;

    if (defined($default) && (! -f $filename)) {
	$data = $default;
    } else {
	my $raw = PVE::Tools::file_get_contents($filename);
	$data = decode_json($raw);
    }

    return $data;
}

sub write_json_to_file {
    my ($filename, $data) = @_;

    my $raw = encode_json($data);

    PVE::Tools::file_set_contents($filename, $raw);
}

sub count_fenced_services {
    my ($ss, $node) = @_;

    my $count = 0;
    
    foreach my $sid (keys %$ss) {
	my $sd = $ss->{$sid};
	next if !$sd->{node};
	next if $sd->{node} ne $node;
	my $req_state = $sd->{state};
	next if !defined($req_state);
	if ($req_state eq 'fence') {
	    $count++;
	    next;
	}
    }
    
    return $count;
}

1;
