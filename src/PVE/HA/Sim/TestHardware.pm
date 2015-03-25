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

sub sim_hardware_cmd {
    my ($self, $cmdstr, $logid) = @_;

    my $code = sub {

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
		    $d->{crm} = PVE::HA::CRM->new($d->{crm_env}) if !$d->{crm};
		    $d->{lrm} = PVE::HA::LRM->new($d->{lrm_env}) if !$d->{lrm};
		} else {
		    if ($d->{crm}) {
			$d->{crm_env}->log('info', "killed by poweroff");
			$d->{crm} = undef;
		    }
		    if ($d->{lrm}) {
			$d->{lrm_env}->log('info', "killed by poweroff");
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

		die "implement me (CRM exit)" if !$crm->do_one_iteration();

		$d->{crm_env}->loop_end_hook();

		my $nodetime = $d->{crm_env}->get_time();
		$self->{cur_time} = $nodetime if $nodetime > $self->{cur_time};
	    }

	    if (my $lrm = $d->{lrm}) {

		$d->{lrm_env}->loop_start_hook($self->get_time());

		die "implement me (LRM exit)" if !$lrm->do_one_iteration();

		$d->{lrm_env}->loop_end_hook();

		my $nodetime = $d->{lrm_env}->get_time();
		$self->{cur_time} = $nodetime if $nodetime > $self->{cur_time};
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
	
	# apply new comand after 5 loop iterations

	if (($self->{loop_count} % 5) == 0) {
	    my $list = shift @{$self->{cmdlist}};
	    if (!$list) {
		# end sumulation (500 seconds after last command)
		return if (($self->{cur_time} - $last_command_time) > 500);
	    }

	    foreach my $cmd (@$list) {
		$last_command_time = $self->{cur_time};
		$self->sim_hardware_cmd($cmd, 'cmdlist');
	    }
	}

	++$self->{loop_count};
    }
}

1;
