package PVE::CLI::ha_manager;

use strict;
use warnings;
use Data::Dumper;

use PVE::INotify;
use JSON;

use PVE::JSONSchema qw(get_standard_option);
use PVE::CLIHandler;
use PVE::Cluster;

use PVE::HA::Tools;
use PVE::API2::HA::Resources;
use PVE::API2::HA::Groups;
use PVE::API2::HA::Status;
use PVE::HA::Env::PVE2;

use base qw(PVE::CLIHandler);

my $nodename = PVE::INotify::nodename();

__PACKAGE__->register_method ({
    name => 'enable',
    path => 'enable',
    method => 'POST',
    description => "Enable a HA resource.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    sid => get_standard_option('pve-ha-resource-or-vm-id',
				      { completion => \&PVE::HA::Tools::complete_disabled_sid }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $sid = PVE::HA::Tools::parse_sid($param->{sid});

	# delete state (default is 'enabled')
	PVE::API2::HA::Resources->update({ sid => $sid, delete => 'state' });

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'disable',
    path => 'disable',
    method => 'POST',
    description => "Disable a HA resource.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    sid => get_standard_option('pve-ha-resource-or-vm-id',
				      { completion => \&PVE::HA::Tools::complete_enabled_sid }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $sid = PVE::HA::Tools::parse_sid($param->{sid});

	PVE::API2::HA::Resources->update({ sid => $sid, state => 'disabled' });

	return undef;
    }});

my $timestamp_to_status = sub {
    my ($ctime, $timestamp) = @_;

    my $tdiff = $ctime - $timestamp;
    if ($tdiff > 30) {
	return "old timestamp - dead?";
    } elsif ($tdiff < -2) {
	return "detected time drift!";
    } else {
	return "active";
    }
};

__PACKAGE__->register_method ({
    name => 'status',
    path => 'status',
    method => 'GET',
    description => "Display HA manger status.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    verbose => {
		description => "Verbose output. Include complete CRM and LRM status (JSON).",
		type => 'boolean',
		default => 0,
		optional => 1,
	    }
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $res = PVE::API2::HA::Status->status({});
	foreach my $e (@$res) {
	    print "$e->{type} $e->{status}\n";
	}

	if ($param->{verbose}) {
	    print "full cluster state:\n";
	    my $data = PVE::API2::HA::Status->manager_status({});
	    print to_json($data, { pretty => 1, canonical => 1} );
	}

	return undef;
    }});

our $cmddef = {
    enable => [ __PACKAGE__, 'enable', ['sid']],
    disable => [ __PACKAGE__, 'disable', ['sid']],
    status => [ __PACKAGE__, 'status'],
    config => [ 'PVE::API2::HA::Resources', 'index', [], {}, sub {
	my $res = shift;
	foreach my $rec (sort { $a->{sid} cmp $b->{sid} } @$res) {
	    my ($type, $name) = split(':', $rec->{sid}, 2);
	    print "$type:$name\n";
	    foreach my $k (sort keys %$rec) {
		next if $k eq 'digest' || $k eq 'sid' ||
		    $k eq 'type' || $k eq 'errors';
		print "\t$k $rec->{$k}\n";
	    }
	    if (my $errors = $rec->{errors}) {
		foreach my $p (keys %$errors) {
		    warn "error: property '$p' - $errors->{$p}\n";
		}
	    }
	    print "\n";
	}}],
    groups => [ 'PVE::API2::HA::Groups', 'index', [], {}, sub {
	my $res = shift;
	foreach my $rec (sort { $a->{group} cmp $b->{group} } @$res) {
	    print "group: $rec->{group}\n";
	    foreach my $k (sort keys %$rec) {
		next if $k eq 'digest' || $k eq 'group' ||
		    $k eq 'type';
		print "\t$k $rec->{$k}\n";
	    }
	    print "\n";
	}}],
    add => [ "PVE::API2::HA::Resources", 'create', ['sid'] ],
    remove => [ "PVE::API2::HA::Resources", 'delete', ['sid'] ],
    set => [ "PVE::API2::HA::Resources", 'update', ['sid'] ],

    migrate => [ "PVE::API2::HA::Resources", 'migrate', ['sid', 'node'] ],
    relocate => [ "PVE::API2::HA::Resources", 'relocate', ['sid', 'node'] ],

};

1;

__END__

=head1 NAME

ha-manager - Proxmox VE HA manager command line interface

=head1 SYNOPSIS

=include synopsis

=head1 DESCRIPTION

ha-manager is a program to manage the HA configuration.

=include pve_copyright
