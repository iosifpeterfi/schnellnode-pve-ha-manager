package PVE::HA::Config;

use strict;
use warnings;
use JSON;

use PVE::HA::Tools;
use PVE::HA::Groups;
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_write_file cfs_lock_file);
use PVE::HA::Resources;

PVE::HA::Groups->register();

PVE::HA::Groups->init();

my $manager_status_filename = "ha/manager_status";
my $ha_groups_config = "ha/groups.cfg";
my $ha_resources_config = "ha/resources.cfg";
my $crm_commands_filename = "ha/crm_commands";
my $ha_fence_config = "ha/fence.cfg";

cfs_register_file($crm_commands_filename, 
		  sub { my ($fn, $raw) = @_; return defined($raw) ? $raw : ''; },
		  sub { my ($fn, $raw) = @_; return $raw; });
cfs_register_file($ha_groups_config, 
		  sub { PVE::HA::Groups->parse_config(@_); },
		  sub { PVE::HA::Groups->write_config(@_); });
cfs_register_file($ha_resources_config, 
		  sub { PVE::HA::Resources->parse_config(@_); },
		  sub { PVE::HA::Resources->write_config(@_); });
cfs_register_file($manager_status_filename, 
		  \&json_reader, 
		  \&json_writer);
cfs_register_file($ha_fence_config,
		  \&PVE::HA::FenceConfig::parse_config,
		  \&PVE::HA::FenceConfig::write_config);

sub json_reader {
    my ($filename, $data) = @_;

    return defined($data) ? decode_json($data) : {};
}

sub json_writer {
    my ($filename, $data) = @_;

    return encode_json($data);
}

sub read_lrm_status {
    my ($node) = @_;

    die "undefined node" if !defined($node);

    my $filename = "/etc/pve/nodes/$node/lrm_status";

    return PVE::HA::Tools::read_json_from_file($filename, {});  
}

sub write_lrm_status {
    my ($node, $status_obj) = @_;

    die "undefined node" if !defined($node);

    my $filename = "/etc/pve/nodes/$node/lrm_status";

    PVE::HA::Tools::write_json_to_file($filename, $status_obj); 
}

sub parse_groups_config {
    my ($filename, $raw) = @_;

    return PVE::HA::Groups->parse_config($filename, $raw);
}

sub parse_resources_config {
    my ($filename, $raw) = @_;
    
    return PVE::HA::Resources->parse_config($filename, $raw);
}

sub read_resources_config {

    return cfs_read_file($ha_resources_config);
}

sub read_group_config {

    return cfs_read_file($ha_groups_config);
}

sub write_group_config {
    my ($cfg) = @_;

    cfs_write_file($ha_groups_config, $cfg);
}

sub write_resources_config {
    my ($cfg) = @_;

    cfs_write_file($ha_resources_config, $cfg);
}

sub read_manager_status {
    my () = @_;

    return cfs_read_file($manager_status_filename);
}

sub write_manager_status {
    my ($status_obj) = @_;

    cfs_write_file($manager_status_filename, $status_obj);
}

sub read_fence_config {
    my () = @_;

    cfs_read_file($ha_fence_config);
}

sub lock_ha_domain {
    my ($code, $errmsg) = @_;

    my $res = PVE::Cluster::cfs_lock_domain("ha", undef, $code);
    my $err = $@;
    if ($err) {
	$errmsg ? die "$errmsg: $err" : die $err;
    }
    return $res;
}

sub queue_crm_commands {
    my ($cmd) = @_;

    chomp $cmd;

    my $code = sub {
	my $data = cfs_read_file($crm_commands_filename);
	$data .= "$cmd\n";
	cfs_write_file($crm_commands_filename, $data);
    };

    return lock_ha_domain($code);
}

sub read_crm_commands {

    my $code = sub {
	my $data = cfs_read_file($crm_commands_filename);
	cfs_write_file($crm_commands_filename, '');
	return $data;
    };

    return lock_ha_domain($code);
}

my $servive_check_ha_state = sub {
    my ($conf, $sid, $has_state) = @_;

    if (my $d = $conf->{ids}->{$sid}) {
	return 1 if !defined($has_state);

	$d->{state} = 'enabled' if !defined($d->{state});
	return 1 if $d->{state} eq $has_state;
    }

    return undef;
};

sub vm_is_ha_managed {
    my ($vmid, $has_state) = @_;

    my $conf = cfs_read_file($ha_resources_config);

    my $types = PVE::HA::Resources->lookup_types();
    foreach my $type ('vm', 'ct') {
	return 1 if &$servive_check_ha_state($conf, "$type:$vmid", $has_state);
    }

    return undef;
}

sub service_is_ha_managed {
    my ($sid, $has_state, $noerr) = @_;

    my $conf = cfs_read_file($ha_resources_config);

    return 1 if &$servive_check_ha_state($conf, $sid, $has_state);

    die "resource '$sid' is not HA managed\n" if !$noerr;

    return undef;
}

sub get_service_status {
    my ($sid) = @_;

    my $status = { managed => 0 };

    my $conf = cfs_read_file($ha_resources_config);

    if (&$servive_check_ha_state($conf, $sid)) {
	my $manager_status = cfs_read_file($manager_status_filename);

	$status->{managed} = 1;
	$status->{group} = $conf->{ids}->{$sid}->{group};
	$status->{state} = $manager_status->{service_status}->{$sid}->{state};
    }

    return $status;
}

1;
