package PVE::API2::HA::Groups;

use strict;
use warnings;
use Data::Dumper;

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

# fixme: fix permissions

my $api_copy_config = sub {
    my ($cfg, $group) = @_;

    die "no such ha group '$group'\n" if !$cfg->{ids}->{$group};
    
    my $group_cfg = dclone($cfg->{ids}->{$group});
    $group_cfg->{group} = $group;
    $group_cfg->{digest} = $cfg->{digest};

    return $group_cfg;
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

	my $cfg = PVE::HA::Config::read_group_config();

	my $res = [];
	foreach my $group (keys %{$cfg->{ids}}) {
	    my $scfg = &$api_copy_config($cfg, $group);
	    next if $scfg->{type} ne 'group'; # should not happen
	    push @$res, $scfg;
	}

	return $res;
    }});


__PACKAGE__->register_method ({
    name => 'read',
    path => '{group}',
    method => 'GET',
    description => "Read ha group configuration.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    group => get_standard_option('pve-ha-group-id'),
	},
    },
    returns => {},
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::HA::Config::read_group_config();

	return &$api_copy_config($cfg, $param->{group});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new HA group.",
    parameters => PVE::HA::Groups->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	# create /etc/pve/ha directory
	PVE::Cluster::check_cfs_quorum();
	mkdir("/etc/pve/ha");
	
	my $group = extract_param($param, 'group');
	my $type = 'group';
	
	if (my $param_type = extract_param($param, 'type')) {
	    # useless, but do it anyway
	    die "types does not match\n" if $param_type ne $type;
	}

	my $plugin = PVE::HA::Groups->lookup($type);

	my $opts = $plugin->check_config($group, $param, 1, 1);

	PVE::HA::Config::lock_ha_config(
	    sub {

		my $cfg = PVE::HA::Config::read_group_config();

		if ($cfg->{ids}->{$group}) {
		    die "ha group ID '$group' already defined\n";
		}

		$cfg->{ids}->{$group} = $opts;

		PVE::HA::Config::write_group_config($cfg)

	    }, "create ha group failed");

        return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{group}',
    method => 'PUT',
    description => "Update ha group configuration.",
    parameters => PVE::HA::Groups->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $digest = extract_param($param, 'digest');
	my $delete = extract_param($param, 'delete');

	my $group = extract_param($param, 'group');
	my $type = 'group';

	if (my $param_type = extract_param($param, 'type')) {
	    # useless, but do it anyway
	    die "types does not match\n" if $param_type ne $type;
	}

	PVE::HA::Config::lock_ha_config(
	    sub {

		my $cfg = PVE::HA::Config::read_group_config();

		PVE::SectionConfig::assert_if_modified($cfg, $digest);

		my $group_cfg = $cfg->{ids}->{$group} ||
		    die "no such ha group '$group'\n";

		my $plugin = PVE::HA::Groups->lookup($group_cfg->{type});
		my $opts = $plugin->check_config($group, $param, 0, 1);

		foreach my $k (%$opts) {
		    $group_cfg->{$k} = $opts->{$k};
		}

		if ($delete) {
		    my $options = $plugin->private()->{options}->{$type};
		    foreach my $k (PVE::Tools::split_list($delete)) {
			my $d = $options->{$k} ||
			    die "no such option '$k'\n";
			die "unable to delete required option '$k'\n"
			    if !$d->{optional};
			die "unable to delete fixed option '$k'\n"
			    if $d->{fixed};
			delete $group_cfg->{$k};
		    }
		}

		PVE::HA::Config::write_group_config($cfg)

	    }, "update ha group failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{group}',
    method => 'DELETE',
    description => "Delete ha group configuration.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    group => get_standard_option('pve-ha-group-id'),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $group = extract_param($param, 'group');

	PVE::HA::Config::lock_ha_config(
	    sub {

		my $rcfg = PVE::HA::Config::read_resources_config();
		foreach my $sid (keys %$rcfg->{ids}) {
		    my $sg = $rcfg->{ids}->{$sid}->{group};
		    die "ha group is used by service '$sid'\n" 
			if ($sg && $sg eq $group);
		}

		my $cfg = PVE::HA::Config::read_group_config();

		delete $cfg->{ids}->{$group};

		PVE::HA::Config::write_group_config($cfg)

	    }, "delete ha group failed");

	return undef;
    }});

1;
