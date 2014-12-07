package PVE::HA::Sim::RTHardware;

# Simulate Hardware resources in Realtime by
# running CRM and LRM in sparate processes

use strict;
use warnings;
use POSIX qw(strftime EINTR);
use Data::Dumper;
use JSON; 
use IO::File;
use IO::Select;
use Fcntl qw(:DEFAULT :flock);
use File::Copy;
use File::Path qw(make_path remove_tree);
use Term::ReadLine;

use PVE::HA::CRM;
use PVE::HA::LRM;

use PVE::HA::Sim::RTEnv;
use base qw(PVE::HA::Sim::Hardware);

sub new {
    my ($this, $testdir) = @_;

    my $class = ref($this) || $this;

    my $self = $class->SUPER::new($testdir);

    foreach my $node (sort keys %{$self->{nodes}}) {
	my $d = $self->{nodes}->{$node};

	$d->{crm} = undef; # create on power on
	$d->{lrm} = undef; # create on power on
    }

    return $self;
}

sub get_time {
    my ($self) = @_;

    return time();
}

sub log {
    my ($self, $level, $msg, $id) = @_;

    chomp $msg;

    my $time = $self->get_time();

    $id = 'hardware' if !$id;

    printf("%-5s %10s %12s: $msg\n", $level, strftime("%H:%M:%S", localtime($time)), $id);
}

sub fork_daemon {
    my ($self, $lockfh, $type, $node) = @_;

    my $pid = fork();
    die "fork failed" if ! defined($pid);

    if ($pid == 0) { 

	close($lockfh) if defined($lockfh); # unlock global lock
	
	if ($type eq 'crm') {

	    my $haenv = PVE::HA::Env->new('PVE::HA::Sim::RTEnv', $node, $self, 'crm');

	    my $crm = PVE::HA::CRM->new($haenv);

	    for (;;) {
		$haenv->loop_start_hook();

		if (!$crm->do_one_iteration()) {
		    $haenv->log("info", "daemon stopped");
		    exit (0);
		}

		$haenv->loop_end_hook();
	    }

	} else {

	    my $haenv = PVE::HA::Env->new('PVE::HA::Sim::RTEnv', $node, $self, 'lrm');

	    my $lrm = PVE::HA::LRM->new($haenv);

	    for (;;) {
		$haenv->loop_start_hook();

		if (!$lrm->do_one_iteration()) {
		    $haenv->log("info", "daemon stopped");
		    exit (0);
		}

		$haenv->loop_end_hook();
	    }
	}

	exit(-1);
    }
	
    return $pid;
}

# simulate hardware commands
# power <node> <on|off>
# network <node> <on|off>

sub sim_hardware_cmd {
    my ($self, $cmdstr, $logid) = @_;

    # note: do not fork when we own the lock!
    my $code = sub {
	my ($lockfh) = @_;

	my $cstatus = $self->read_hardware_status_nolock();

	my ($cmd, $node, $action) = split(/\s+/, $cmdstr);

	die "sim_hardware_cmd: no node specified" if !$node;
	die "sim_hardware_cmd: unknown action '$action'" if $action !~ m/^(on|off)$/;

	my $d = $self->{nodes}->{$node};
	die "sim_hardware_cmd: no such node '$node'\n" if !$d;

	$self->log('info', "execute $cmdstr", $logid);
	
	if ($cmd eq 'power') {
	    if ($cstatus->{$node}->{power} ne $action) {
		if ($action eq 'on') {	      
		    $d->{crm} = $self->fork_daemon($lockfh, 'crm', $node) if !$d->{crm};
		    $d->{lrm} = $self->fork_daemon($lockfh, 'lrm', $node) if !$d->{lrm};
		} else {
		    if ($d->{crm}) {
			$self->log('info', "crm on node '$node' killed by poweroff");
			kill(9, $d->{crm});
			$d->{crm} = undef;
		    }
		    if ($d->{lrm}) {
			$self->log('info', "lrm on node '$node' killed by poweroff");
			kill(9, $d->{lrm});
			$d->{lrm} = undef;
		    }
		}
	    }

	    $cstatus->{$node}->{power} = $action;
	    $cstatus->{$node}->{network} = $action;

	} elsif ($cmd eq 'network') {
		$cstatus->{$node}->{network} = $action;
	} else {
	    die "sim_hardware_cmd: unknown command '$cmd'\n";
	}

	$self->write_hardware_status_nolock($cstatus);
    };

    return $self->global_lock($code);
}


sub run {
    my ($self) = @_;

    my $last_command_time = 0;

    print "entering HA simulation shell - type 'help' for help\n";

    my $term = new Term::ReadLine ('pve-ha-simulator');
    my $attribs = $term->Attribs;

    my $select = new IO::Select;    

    $select->add(\*STDIN);

    my $end_simulation = 0;
    
    my $input_cb = sub {
	my $input = shift;

	chomp $input;

	return if $input =~ m/^\s*$/;

	if ($input =~ m/^\s*q(uit)?\s*$/) {
	    $end_simulation = 1;
	}

	$term->addhistory($input);

	eval {
	    $self->sim_hardware_cmd($input);
	};
	warn $@ if $@;
    };

    $term->CallbackHandlerInstall("ha> ", $input_cb);

    while ($select->count) {
	my @handles = $select->can_read(1);

	my @nodes = sort keys %{$self->{nodes}};
	foreach my $node (@nodes) {
	    if (!$self->watchdog_check($node)) {
		$self->sim_hardware_cmd("power $node off", 'watchdog');
		$self->log('info', "server '$node' stopped by poweroff (watchdog)");
	    }
	}

	if (scalar(@handles)) {
	    $term->rl_callback_read_char();
	}

	last if $end_simulation;
    }

    kill(9, 0); kill whole process group

    $term->rl_deprep_terminal();
}

1;
