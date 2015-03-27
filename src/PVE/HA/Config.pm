package PVE::HA::Config;

use strict;
use warnings;
use JSON;

use PVE::HA::Tools;
use PVE::HA::Groups;
use PVE::HA::Resources;
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_write_file cfs_lock_file);

PVE::HA::Groups->register();

PVE::HA::Groups->init();

PVE::HA::Resources::PVEVM->register();
PVE::HA::Resources::IPAddr->register();

PVE::HA::Resources->init();

my $manager_status_filename = "ha/manager_status";
my $ha_groups_config = "ha/groups.cfg";
my $ha_resources_config = "ha/resources.cfg";
my $crm_commands_filename = "ha/crm_commands";

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

sub json_reader {
    my ($filename, $data) = @_;

    return decode_json($data || {});
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
    my () = @_;

    return cfs_read_file($ha_groups_config);
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

sub lock_ha_config {
    my ($code, $errmsg) = @_;

    # fixme: do not use cfs_lock_storage (replace with cfs_lock_ha)
    my $res = PVE::Cluster::cfs_lock_storage("_ha_crm_commands", undef, $code);
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

    return lock_ha_config($code);
}

sub read_crm_commands {

    my $code = sub {
	my $data = cfs_read_file($crm_commands_filename);
	cfs_write_file($crm_commands_filename, '');
	return $data;
    };

    return lock_ha_config($code);
}

sub vm_is_ha_managed {
    my ($vmid) = @_;

    my $conf = cfs_read_file($ha_resources_config);

    my $sid = "pvevm:$vmid";
    
    return defined($conf->{ids}->{$sid});
}

1;
