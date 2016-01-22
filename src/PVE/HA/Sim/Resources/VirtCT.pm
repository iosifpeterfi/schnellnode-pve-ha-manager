package PVE::HA::Sim::Resources::VirtCT;

use strict;
use warnings;

use base qw(PVE::HA::Sim::Resources);

sub type {
    return 'ct';
}

sub exists {
    my ($class, $id, $noerr) = @_;

    # in the virtual cluster every virtual CT (of this type) exists
    return 1;
}

sub migrate {
    my ($class, $haenv, $id, $target, $online) = @_;

    my $sid = "ct:$id";
    my $nodename = $haenv->nodename();
    my $hardware = $haenv->hardware();
    my $ss = $hardware->read_service_status($nodename);

    if ($online && $ss->{$sid}) {
	$haenv->log('warn', "unable to live migrate running container, fallback to relocate");
	$online = 0;
    }

    $class->SUPER::migrate($haenv, $id, $target, $online);

}

1;
