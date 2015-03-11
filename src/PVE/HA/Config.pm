package PVE::HA::Config;

use strict;
use warnings;

use PVE::HA::Groups;
use PVE::HA::Resources;

PVE::HA::Groups->register();

PVE::HA::Groups->init();

PVE::HA::Resources::PVEVM->register();
PVE::HA::Resources::IPAddr->register();

PVE::HA::Resources->init();

sub parse_groups_config {
    my ($filename, $raw) = @_;

    return PVE::HA::Groups->parse_config($filename, $raw);
}

sub parse_resources_config {
    my ($filename, $raw) = @_;
    
    return PVE::HA::Resources->parse_config($filename, $raw);
}

1;
