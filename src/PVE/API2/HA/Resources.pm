package PVE::API2::HA::Resources;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::HA::Config;
use PVE::HA::Resources;
use HTTP::Status qw(:constants);
use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

# fixme: use cfs_read_file

my $ha_resources_config = "/etc/pve/ha/resources.cfg";

my $resource_type_enum = PVE::HA::Resources->lookup_types();

# fixme: fix permissions

my $api_copy_config = sub {
    my ($cfg, $sid) = @_;

    my $scfg = dclone($cfg->{ids}->{$sid});
    $scfg->{sid} = $sid;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index', 
    path => '',
    method => 'GET',
    description => "Get HA resources index.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    type => { 
		description => "Only list resources of specific type",
		type => 'string', 
		enum => $resource_type_enum,
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { sid => { type => 'string'} },
	},
	links => [ { rel => 'child', href => "{sid}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $raw = '';

	$raw = PVE::Tools::file_get_contents($ha_resources_config)
	    if -f $ha_resources_config;

	my $cfg = PVE::HA::Config::parse_resources_config($ha_resources_config, $raw);

	my $res = [];
	foreach my $sid (keys %{$cfg->{ids}}) {
	    my $scfg = &$api_copy_config($cfg, $sid);
	    next if $param->{type} && $param->{type} ne $scfg->{type};
	    push @$res, $scfg;
	}

	return $res;
    }});


1;
