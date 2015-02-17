package PVE::HA::Groups;

use strict;
use warnings;

use Data::Dumper;
use PVE::JSONSchema qw(get_standard_option);
use PVE::SectionConfig;

use base qw(PVE::SectionConfig);

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

my $defaultData = {
    propertyList => {
	type => { description => "Section type." },
	group => get_standard_option('pve-ha-group-id'),
	nodes => get_standard_option('pve-ha-group-node-list'),
	restricted => {
	    description => "Services on unrestricted groups may run on any cluster members if all group members are offline. But they will migrate back as soon as a group member comes online. One can implement a 'preferred node' behavior using an unrestricted group with one member.",
	    type => 'boolean', 
	    optional => 1,
	    default => 0,
	},
	nofailback => {
	    description => "The CRM tries to run services on the node with the highest priority. If a node with higher priority comes online, the CRM migrates the service to that node. Enabling nofailback prevents that behavior.",
	    type => 'boolean', 
	    optional => 1,
	    default => 0,	    
	},
	comment => { 
	    description => "Description.",
	    type => 'string', 
	    optional => 1,
	    maxLength => 4096,
	},
    },
};

sub type {
    return 'group';
}

sub options {
    return {
	nodes => {},
	comment => { optional => 1 },
    };
}

sub private {
    return $defaultData;
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
	my ($type, $group) = (lc($1), $2);
	my $errmsg = undef; # set if you want to skip whole section
	eval { PVE::JSONSchema::pve_verify_configid($group); };
	$errmsg = $@ if $@;
	my $config = {}; # to return additional attributes
	return ($type, $group, $errmsg, $config);
    }
    return undef;
}

1;
