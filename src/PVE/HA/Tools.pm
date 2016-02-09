package PVE::HA::Tools;

use strict;
use warnings;
use JSON;
use PVE::JSONSchema;
use PVE::Tools;
use PVE::Cluster;
use PVE::ProcFSTools;

# return codes used in the ha environment
# mainly by the resource agents
use constant {
    SUCCESS => 0, # action finished as expected
    ERROR => 1, # action was erroneous
    ETRY_AGAIN => 2, # action was erroneous and needs to be repeated
    EWRONG_NODE => 3, # needs to fixup the service location
    EUNKNOWN_SERVICE_TYPE => 4, # no plugin for this type service found
    EUNKNOWN_COMMAND => 5,
    EINVALID_PARAMETER => 6,
    EUNKNOWN_SERVICE => 7, # service not found
};

# get constants out of package in a somewhat easy way
use base 'Exporter';
our @EXPORT_OK = qw(SUCCESS ERROR EWRONG_NODE EUNKNOWN_SERVICE_TYPE
 EUNKNOWN_COMMAND EINVALID_PARAMETER ETRY_AGAIN EUNKNOWN_SERVICE);
our %EXPORT_TAGS = ( 'exit_codes' => [@EXPORT_OK] );

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
    description => "List of cluster node names with optional priority. We use priority '0' as default. The CRM tries to run services on the node with highest priority (also see option 'nofailback').",
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
	my $raw;
	# workaround for bug #775
	if ($filename =~ m|^/etc/pve/|) {
	    $filename =~ s|^/etc/pve/+||;
	    $raw = PVE::Cluster::get_config($filename);
	    die "unable to read file '/etc/pve/$filename'\n" 
		if !defined($raw);
	} else {
	    $raw = PVE::Tools::file_get_contents($filename);
	}
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

sub upid_wait {
    my ($upid, $haenv) = @_;

    my $waitfunc = sub {
	my $task = PVE::Tools::upid_encode(shift);
	$haenv->log('info', "Task '$task' still active, waiting");
    };

    PVE::ProcFSTools::upid_wait($upid, $waitfunc, 5);
}

# bash auto completion helper

sub complete_sid {
    my ($cmd, $pname, $cur) = @_;

    my $cfg = PVE::HA::Config::read_resources_config();

    my $res = [];

    if ($cmd eq 'add') {

	my $vmlist = PVE::Cluster::get_vmlist();

	while (my ($vmid, $info) = each %{$vmlist->{ids}}) {

	    my $sid;

	    if ($info->{type} eq 'lxc') {
		$sid = "ct:$vmid";
	    } elsif ($info->{type} eq 'qemu') {
		$sid = "vm:$vmid";
	    } else {
		next; # should not happen
	    }

	    next if $cfg->{ids}->{$sid};

	    push @$res, $sid;
	}

    } else {

	foreach my $sid (keys %{$cfg->{ids}}) {
	    push @$res, $sid;
	}
    }

    return $res;
}

sub complete_enabled_sid {

    my $cfg = PVE::HA::Config::read_resources_config();

    my $res = [];
    foreach my $sid (keys %{$cfg->{ids}}) {
	my $state = $cfg->{ids}->{$sid}->{state} // 'enabled';
	next if $state ne 'enabled';
	push @$res, $sid;
    }

    return $res;
}

sub complete_disabled_sid {

    my $cfg = PVE::HA::Config::read_resources_config();

    my $res = [];
    foreach my $sid (keys %{$cfg->{ids}}) {
	my $state = $cfg->{ids}->{$sid}->{state} // 'enabled';
	next if $state eq 'enabled';
	push @$res, $sid;
    }

    return $res;
}

sub complete_group {
    my ($cmd, $pname, $cur) = @_;

    my $cfg = PVE::HA::Config::read_group_config();

    my $res = [];
    if ($cmd ne 'groupadd') {

	foreach my $group (keys %{$cfg->{ids}}) {
	    push @$res, $group;
	}

    }

    return $res;
}


1;
