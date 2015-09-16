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

=head1 DESCRIPTION

B<ha-manager> handles management of user-defined cluster services. This includes
handling of user requests including service start, service disable,
service relocate, and service restart. The cluster resource manager daemon also
handles restarting and relocating services in the event of failures.

=head1 HOW IT WORKS

The local resource manager (B<pve-ha-lrm>) is started as a daemon on each node
at system start and waits until the HA cluster is quorate and locks are working.
After initialization, the LRM determines which services are enabled and starts
them. Also the watchdog gets initialized.

The cluster resource manager (B<pve-ha-crm>) starts on each node and waits there
for the manager lock, which can only be held by one node at a time.
The node which successfully acquires the manager lock gets promoted to the CRM,
it handles cluster wide actions like migrations and failures.

When an node leaves the cluster quorum, its state changes to unknown.
If the current CRM then can secure the failed nodes lock, the services will be
'stolen' and restarted on another node.

When a cluster member determines that it is no longer in the cluster quorum,
the LRM waits for a new quorum to form. As long as there is no quorum the node
cannot reset the watchdog. This will trigger a reboot after 60 seconds.

=head1 CONFIGURATION

The HA stack is well integrated int the Proxmox VE API2. So, for example,
HA can be configured via B<ha-manager> or the B<PVE web interface>, which
both provide an easy to use tool.

The resource configuration file can be located at F</etc/pve/ha/resources.cfg>
and the group configuration file at F</etc/pve/ha/groups.cfg>. Use the provided
tools to make changes, there shouldn't be any need to edit them manually.

=head1 RESOURCES/SERVICES AGENTS

A resource or also called service can be managed by the ha-manager. Currently we
support virtual machines and container.

=head1 GROUPS

A group is a collection of cluster nodes which a service may be bound to.

=head2 GROUP SETTINGS

=over 4

=item B<* nodes>

list of group node members

=item B<* restricted>

resources bound to this group may only run on nodes defined by the group. If no
group node member is available the resource will be placed in the stopped state.

=item B<* nofailback>

the resource won't automatically fail back when a more preferred node (re)joins
the cluster.

=back

=head1 RECOVERY POLICY

There are two service recover policy settings which can be configured specific
for each resource.

=over 4

=item B<* max_restart>

maximal number of tries to restart an failed service on the actual node.
The default is set to one.

=item B<* max_relocate>

maximal number of tries to relocate the service to a different node.
A relocate only happens after the max_restart value is exceeded on the
actual node. The default is set to one.

=back

Note that the relocate count state will only reset to zero when the service had
at least one successful start. That means if a service is re-enabled without
fixing the error only the restart policy gets repeated.

=head1 ERROR RECOVERY

If after all tries the service state could not be recovered it gets placed in
an error state. In this state the service won't get touched by the HA stack
anymore.
To recover from this state you should follow these steps:

=over

=item * bring the resource back into an safe and consistent state (e.g: killing
its process)

=item * disable the ha resource to place it in an stopped state

=item * fix the error which led to this failures

=item * B<after> you fixed all errors you may enable the service again

=back

=head1 SERVICE OPERATIONS

This are how the basic user-initiated service operations (via B<ha-manager>)
work.

=over 4

=item B<* enable>

the service will be started by the LRM if not already running.

=item B<* disable>

the service will be stopped by the LRM if running.

=item B<* migrate/relocate>

the service will be relocated (live) to another node.

=item B<* remove>

the service will be removed from the HA managed resource list. Its current state
will not be touched.

=item B<* start/stop>

start and stop commands can be issued to the resource specific tools (like F<qm>
or F<pct>), they will forward the request to the B<ha-manager> which then will
execute the action and set the resulting service state (enabled, disabled).

=back


=head1 SERVICE STATES

=over 4

=item B<stopped>

Service is stopped (confirmed by LRM)

=item B<request_stop>

Service should be stopped. Waiting for confirmation from LRM.

=item B<started>

Service is active an LRM should start it ASAP if not already running.

=item B<fence>

Wait for node fencing (service node is not inside quorate cluster partition).

=item B<freeze>

Do not touch the service state. We use this state while we reboot a node, or
when we restart the LRM daemon.

=item B<migrate>

Migrate service (live) to other node.

=item B<error>

Service disabled because of LRM errors. Needs manual intervention.

=back

=head1 SYNOPSIS

=include synopsis

=include pve_copyright
