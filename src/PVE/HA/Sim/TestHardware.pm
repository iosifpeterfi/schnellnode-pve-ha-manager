package PVE::HA::Sim::TestHardware;

# Simulate Hardware resources

# power supply for nodes: on/off
# network connection to nodes: on/off
# watchdog devices for nodes

use strict;
use warnings;
use POSIX qw(strftime EINTR);
use Data::Dumper;
use JSON; 
use IO::File;
use Fcntl qw(:DEFAULT :flock);
use File::Copy;
use File::Path qw(make_path remove_tree);

use PVE::HA::CRM;
use PVE::HA::LRM;

use PVE::HA::Sim::TestEnv;
use base qw(PVE::HA::Sim::Hardware);

my $max_sim_time = 10000;

sub new {
    my ($this, $testdir) = @_;

    my $class = ref($this) || $this;

    my $self = $class->SUPER::new($testdir);

    my $raw = PVE::Tools::file_get_contents("$testdir/cmdlist");
    $self->{cmdlist} = decode_json($raw);

    $self->{loop_count} = 0;
    $self->{cur_time} = 0;

    my $statusdir = $self->statusdir();
    my $logfile = "$statusdir/log";
    $self->{logfh} = IO::File->new(">>$logfile") ||
	die "unable to open '$logfile' - $!";

    foreach my $node (sort keys %{$self->{nodes}}) {

	my $d = $self->{nodes}->{$node};

	$d->{crm_env} = 
	    PVE::HA::Env->new('PVE::HA::Sim::TestEnv', $node, $self, 'crm');

	$d->{lrm_env} = 
	    PVE::HA::Env->new('PVE::HA::Sim::TestEnv', $node, $self, 'lrm');

	$d->{crm} = undef; # create on power on
	$d->{lrm} = undef; # create on power on
    }

    return $self;
}

sub get_time {
    my ($self) = @_;

    return $self->{cur_time};
}

sub log {
    my ($self, $level, $msg, $id) = @_;

    chomp $msg;

    my $time = $self->get_time();

    $id = 'hardware' if !$id;

    my $line = sprintf("%-5s %5d %12s: $msg\n", $level, $time, $id);
    print $line;

    $self->{logfh}->print($line);
    $self->{logfh}->flush();
}

# simulate hardware commands
# power <node> <on|off>
# network <node> <on|off>
# reboot <node>
# shutdown <node>
# restart-lrm <node>
# service <sid> <enabled|disabled>
# service <sid> <migrate|relocate> <target>
# service <sid> lock/unlock [lockname]

sub sim_hardware_cmd {
    my ($self, $cmdstr, $logid) = @_;

    my $code = sub {

	my $cstatus = $self->read_hardware_status_nolock();

	my ($cmd, $objid, $action, $target) = split(/\s+/, $cmdstr);

	die "sim_hardware_cmd: no node or service for command specified"
	    if !$objid;

	my ($node, $sid, $d);

	if ($cmd eq 'service') {
	    $sid = PVE::HA::Tools::pve_verify_ha_resource_id($objid);
	} else {
	    $node = $objid;
	    $d = $self->{nodes}->{$node} ||
		die "sim_hardware_cmd: no such node '$node'\n";
	}

	$self->log('info', "execute $cmdstr", $logid);
	
	if ($cmd eq 'power') {
	    die "sim_hardware_cmd: unknown action '$action'" if $action !~ m/^(on|off)$/;
	    if ($cstatus->{$node}->{power} ne $action) {
		if ($action eq 'on') {
		    $d->{crm} = PVE::HA::CRM->new($d->{crm_env}) if !$d->{crm};
		    $d->{lrm} = PVE::HA::LRM->new($d->{lrm_env}) if !$d->{lrm};
		    $d->{lrm_restart} = undef;
		} else {
		    if ($d->{crm}) {
			$d->{crm_env}->log('info', "killed by poweroff");
			$d->{crm} = undef;
		    }
		    if ($d->{lrm}) {
			$d->{lrm_env}->log('info', "killed by poweroff");
			$d->{lrm} = undef;
			$d->{lrm_restart} = undef;
		    }
		    $self->watchdog_reset_nolock($node);
		    $self->write_service_status($node, {});
		}
	    }

	    $cstatus->{$node}->{power} = $action;
	    $cstatus->{$node}->{network} = $action;
	    $cstatus->{$node}->{shutdown} = undef;

	    $self->write_hardware_status_nolock($cstatus);

	} elsif ($cmd eq 'network') {
	    die "sim_hardware_cmd: unknown network action '$action'"
		if $action !~ m/^(on|off)$/;
	    $cstatus->{$node}->{network} = $action;

	    $self->write_hardware_status_nolock($cstatus);

	} elsif ($cmd eq 'reboot' || $cmd eq 'shutdown') {
	    $cstatus->{$node}->{shutdown} = $cmd;

	    $self->write_hardware_status_nolock($cstatus);

	    $d->{lrm}->shutdown_request() if $d->{lrm};
	} elsif ($cmd eq 'restart-lrm') {
	    if ($d->{lrm}) {
		$d->{lrm_restart} = 1;
		$d->{lrm}->shutdown_request();
	    }
	} elsif ($cmd eq 'crm') {

	    if ($action eq 'stop') {
		if ($d->{crm}) {
		    $d->{crm_stop} = 1;
		    $d->{crm}->shutdown_request();
		}
	    } elsif ($action eq 'start') {
		$d->{crm} = PVE::HA::CRM->new($d->{crm_env}) if !$d->{crm};
	    } else {
		die "sim_hardware_cmd: unknown action '$action'";
	    }

	} elsif ($cmd eq 'service') {
	    if ($action eq 'enabled' || $action eq 'disabled') {

		$self->set_service_state($sid, $action);

	    } elsif ($action eq 'migrate' || $action eq 'relocate') {

		die "sim_hardware_cmd: missing target node for '$action' command"
		    if !$target;

		$self->queue_crm_commands_nolock("$action $sid $target");

	    } elsif ($action eq 'add') {

		$self->add_service($sid, {state => 'enabled', node => $target});

	    } elsif ($action eq 'delete') {

		$self->delete_service($sid);

	    } elsif ($action eq 'lock') {

		$self->lock_service($sid, $target);

	    } elsif ($action eq 'unlock') {

		$self->unlock_service($sid, $target);

	    } else {
		die "sim_hardware_cmd: unknown service action '$action' " .
		    "- not implemented\n"
	    }
	} else {
	    die "sim_hardware_cmd: unknown command '$cmdstr'\n";
	}

    };

    return $self->global_lock($code);
}

sub run {
    my ($self) = @_;

    my $last_command_time = 0;
    my $next_cmd_at = 0;
	
    for (;;) {

	my $starttime = $self->get_time();

	my @nodes = sort keys %{$self->{nodes}};

	my $nodecount = scalar(@nodes);

	my $looptime = $nodecount*2;
	$looptime = 20 if $looptime < 20;

	die "unable to simulate so many nodes. You need to increate watchdog/lock timeouts.\n"
	    if $looptime >= 60;

	foreach my $node (@nodes) {

	    my $d = $self->{nodes}->{$node};
	    
	    if (my $crm = $d->{crm}) {

		$d->{crm_env}->loop_start_hook($self->get_time());

		my $exit_crm = !$crm->do_one_iteration();

		$d->{crm_env}->loop_end_hook();

		my $nodetime = $d->{crm_env}->get_time();
		$self->{cur_time} = $nodetime if $nodetime > $self->{cur_time};

		if ($exit_crm) {
		    $d->{crm_env}->log('info', "exit (loop end)");
		    $d->{crm} = undef;

		    my $cstatus = $self->read_hardware_status_nolock();
		    my $nstatus = $cstatus->{$node} || die "no node status for node '$node'";
		    my $shutdown = $nstatus->{shutdown} || '';
		    if ($shutdown eq 'reboot') {
			$self->sim_hardware_cmd("power $node off", 'reboot');
			$self->sim_hardware_cmd("power $node on", 'reboot');
		    } elsif ($shutdown eq 'shutdown') {
			$self->sim_hardware_cmd("power $node off", 'shutdown');
		    } elsif (!$d->{crm_stop}) {
			die "unexpected CRM exit - not implemented"
		    }
		    $d->{crm_stop} = undef;
		}
	    }

	    if (my $lrm = $d->{lrm}) {

		$d->{lrm_env}->loop_start_hook($self->get_time());

		my $exit_lrm = !$lrm->do_one_iteration();

		$d->{lrm_env}->loop_end_hook();

		my $nodetime = $d->{lrm_env}->get_time();
		$self->{cur_time} = $nodetime if $nodetime > $self->{cur_time};

		if ($exit_lrm) {
		    $d->{lrm_env}->log('info', "exit (loop end)");
		    $d->{lrm} = undef;
		    my $cstatus = $self->read_hardware_status_nolock();
		    my $nstatus = $cstatus->{$node} || die "no node status for node '$node'";
		    my $shutdown = $nstatus->{shutdown} || '';
		    if ($d->{lrm_restart}) {
			die "lrm restart during shutdown - not implemented" if $shutdown;
			$d->{lrm_restart} = undef;
			$d->{lrm} = PVE::HA::LRM->new($d->{lrm_env});
		    } elsif ($shutdown eq 'reboot' || $shutdown eq 'shutdown') {
			# exit the LRM before the CRM to reflect real world behaviour
			$self->sim_hardware_cmd("crm $node stop", $shutdown);
		    } else {
			die "unexpected LRM exit - not implemented"
		    }
		}
	    }

	    foreach my $n (@nodes) {
		if (!$self->watchdog_check($n)) {
		    $self->sim_hardware_cmd("power $n off", 'watchdog');
		    $self->log('info', "server '$n' stopped by poweroff (watchdog)");
		    $self->{nodes}->{$n}->{crm} = undef;
		    $self->{nodes}->{$n}->{lrm} = undef;
		}
	    }
	}

	
	$self->{cur_time} = $starttime + $looptime 
	    if ($self->{cur_time} - $starttime) < $looptime;

	die "simulation end\n" if $self->{cur_time} > $max_sim_time;

	foreach my $node (@nodes) {
	    my $d = $self->{nodes}->{$node};
	    # forced time update
	    $d->{lrm_env}->loop_start_hook($self->get_time());
	    $d->{crm_env}->loop_start_hook($self->get_time());
	}

	next if $self->{cur_time} < $next_cmd_at;
 
	# apply new comand after 5 loop iterations

	if (($self->{loop_count} % 5) == 0) {
	    my $list = shift @{$self->{cmdlist}};
	    if (!$list) {
		# end sumulation (500 seconds after last command)
		return if (($self->{cur_time} - $last_command_time) > 500);
	    }

	    foreach my $cmd (@$list) {
		$last_command_time = $self->{cur_time};

		if ($cmd =~ m/^delay\s+(\d+)\s*$/) {
		    $next_cmd_at = $self->{cur_time} + $1;
		} else {
		    $self->sim_hardware_cmd($cmd, 'cmdlist');
		}
	    }
	}

	++$self->{loop_count};
    }
}

1;
