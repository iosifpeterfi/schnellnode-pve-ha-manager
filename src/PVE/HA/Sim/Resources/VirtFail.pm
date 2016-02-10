package PVE::HA::Sim::Resources::VirtFail;

use strict;
use warnings;

use base qw(PVE::HA::Sim::Resources);

# This class lets us simulate failing resources for the regression tests
# To make it more intresting we can encode some bahviour in the VMID
# with the following format, where fa: is the type and a, b, c, ...
# are ciffers in base 10
# fa:abcde
# meaning:
# a - no meaning but can be used for differentiating similar resources
# b - how many tries are needed to start correctly (0 is normal behaviour) (should be set)
# c - how many tries are needed to migrate correctly (0 is normal behaviour) (should be set)
# d - should shutdown be successful (0 = yes, anything else no) (optional)
# e - return value of $plugin->exists() defaults to 1 if not set (optional)

my $decode_id = sub {
    my $id = shift;

    my ($start, $migrate, $stop, $exists) = $id =~ /^\d(\d)(\d)(\d)?(\d)?/g;

    $start = 0 if !defined($start);
    $migrate = 0 if !defined($migrate);
    $stop = 0 if !defined($stop);
    $exists = 1 if !defined($exists);

    return ($start, $migrate, $stop, $exists)
};

my $tries = {
    start => {},
    migrate => {},
};


sub type {
    return 'fa';
}

sub exists {
    my ($class, $id, $noerr) = @_;

    my (undef, undef, undef, $exists) = &$decode_id($id);
    print $exists ."\n";

    return $exists;
}

sub start {
    my ($class, $haenv, $id) = @_;

    my ($start_failure_count) = &$decode_id($id);

    $tries->{start}->{$id} = 0 if !$tries->{start}->{$id};
    $tries->{start}->{$id}++;

    return if $start_failure_count >= $tries->{start}->{$id};

    $tries->{start}->{$id} = 0; # reset counts

    return $class->SUPER::start($haenv, $id);

}

sub shutdown {
    my ($class, $haenv, $id) = @_;

    my (undef, undef, $cannot_stop) = &$decode_id($id);

    return if $cannot_stop;

    return $class->SUPER::shutdown($haenv, $id);
}

sub migrate {
    my ($class, $haenv, $id, $target, $online) = @_;

    my (undef, $migrate_failure_count) = &$decode_id($id);

    $tries->{migrate}->{$id} = 0 if !$tries->{migrate}->{$id};
    $tries->{migrate}->{$id}++;

    return if $migrate_failure_count >= $tries->{migrate}->{$id};

    $tries->{migrate}->{$id} = 0; # reset counts

    return $class->SUPER::migrate($haenv, $id, $target, $online);

}
1;
