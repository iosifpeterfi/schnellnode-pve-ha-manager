package PVE::HA::Tools;

use strict;
use warnings;
use JSON;
use PVE::JSONSchema;
use PVE::Tools;
use PVE::Cluster;

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
    description => "HA resource ID. This consists of a resource type followed by a resource specific name, separated with colon (example: vm:100 / ct:100).",
    typetext => "<type>:<name>",
    type => 'string', format => 'pve-ha-resource-id',					 
});

PVE::JSONSchema::register_format('pve-ha-resource-or-vm-id', \&pve_verify_ha_resource_or_vm_id);
sub pve_verify_ha_resource_or_vm_id {
    my ($sid, $noerr) = @_;

    if ($sid !~ m/^([a-z]+:\S+|\d+)$/) {
	return undef if $noerr;
	die "value does not look like a valid ha resource id\n";
    }
    return $sid;
}

PVE::JSONSchema::register_standard_option('pve-ha-resource-or-vm-id', {
    description => "HA resource ID. This consists of a resource type followed by a resource specific name, separated with colon (example: vm:100 / ct:100). For virtual machines and containers, you can simply use the VM or CT id as a shortcut (example: 100).",
    typetext => "<type>:<name>",
    type => 'string', format => 'pve-ha-resource-or-vm-id',					 
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

    my ($type, $name);

    if ($sid =~ m/^(\d+)$/) {
	$name = $1;
	my $vmlist = PVE::Cluster::get_vmlist();
	if (defined($vmlist->{ids}->{$name})) {
	    my $vm_type = $vmlist->{ids}->{$name}->{type};
	    if ($vm_type eq 'lxc') {
		$type = 'ct';
	    } elsif ($vm_type eq 'qemu') {
		$type = 'vm';
	    } else {
		die "internal error";
	    }
	    $sid = "$type:$name";
	}
	else {
	    die "unable do add resource - VM/CT $1 does not exist\n";
	}
    } elsif  ($sid =~m/^(\S+):(\S+)$/) {
	$name = $2;
	$type = $1;
    } else {
	die "unable to parse service id '$sid'\n";
    }

    return wantarray ? ($sid, $type, $name) : $sid;
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

# bash auto completion helper

sub complete_sid {

    my $vmlist = PVE::Cluster::get_vmlist();

    my $res = [];
    while (my ($vmid, $info) = each %{$vmlist->{ids}}) {

	my $sid = '';

	if ($info->{type} eq 'lxc') {
	    $sid .= 'ct:';
	} elsif ($info->{type} eq 'qemu') {
	    $sid .= 'vm:';
	}

	$sid .= $vmid;

	push @$res, $sid;

    }

    return $res;
}

sub complete_group {

    my $cfg = PVE::HA::Config::read_group_config();

    my $res = [];
    foreach my $group (keys %{$cfg->{ids}}) {
	push @$res, $group;
    }

    return $res;
}


1;
