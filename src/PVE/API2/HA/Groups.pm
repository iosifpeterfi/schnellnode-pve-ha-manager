package PVE::API2::HA::Groups;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::HA::Config;
use HTTP::Status qw(:constants);
use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

# fixme: use cfs_read_file

my $ha_groups_config = "/etc/pve/ha/groups.cfg";

# fixme: fix permissions

my $api_copy_config = sub {
    my ($cfg, $sid) = @_;

    my $scfg = dclone($cfg->{ids}->{$sid});
    $scfg->{group} = $sid;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index', 
    path => '',
    method => 'GET',
    description => "Get HA groups.",
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { group => { type => 'string'} },
	},
	links => [ { rel => 'child', href => "{group}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $raw = '';

	$raw = PVE::Tools::file_get_contents($ha_groups_config)
	    if -f $ha_groups_config;

	my $cfg = PVE::HA::Config::parse_groups_config($ha_groups_config, $raw);

	my $res = [];
	foreach my $sid (keys %{$cfg->{ids}}) {
	    my $scfg = &$api_copy_config($cfg, $sid);
	    next if $scfg->{type} ne 'group'; # should not happen
	    push @$res, $scfg;
	}

	return $res;
    }});


1;
