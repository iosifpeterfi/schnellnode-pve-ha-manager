package PVE::HA::SimCluster;

use strict;
use warnings;
use POSIX qw(strftime EINTR);
use Data::Dumper;
use JSON; 
use IO::File;
use Fcntl qw(:DEFAULT :flock);

my $max_sim_time = 1000;

use PVE::HA::SimEnv;
use PVE::HA::Server;

sub read_cluster_status_nolock {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/cluster_status";

    my $raw = PVE::Tools::file_get_contents($filename);
    my $cstatus = decode_json($raw);

    return $cstatus;
}

sub write_cluster_status_nolock {
    my ($self, $cstatus) = @_;

    my $filename = "$self->{statusdir}/cluster_status";

    PVE::Tools::file_set_contents($filename, encode_json($cstatus));
};

sub new {
    my ($this, $testdir) = @_;

    die "missing testdir" if !$testdir;

    my $class = ref($this) || $this;

    my $self = bless {}, $class;

    $self->{statusdir} = "$testdir/status";

    $self->{cur_time} = 0;

    if (-f "$testdir/cmdlist") {
	my $raw = PVE::Tools::file_get_contents("$testdir/cmdlist");
	$self->{cmdlist} = decode_json($raw);
    } else {
	$self->{cmdlist} = []; # fixme: interactive mode
    }

    $self->{loop_count} = 0;

    my $cstatus = $self->read_cluster_status_nolock();

    foreach my $node (sort keys %$cstatus) {

	my $haenv = PVE::HA::SimEnv->new($self, $node);
	die "HA is not enabled\n" if !$haenv->manager_status_exists();

	$haenv->log('info', "starting server");
	my $server = PVE::HA::Server->new($haenv);

	$self->{nodes}->{$node}->{haenv} = $haenv;
	$self->{nodes}->{$node}->{server} = undef; # create on power on
    }

    return $self;
}

sub get_time {
    my ($self) = @_;

    return $self->{cur_time};
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    my $time = $self->get_time();

    printf("%-5s %5d %10s: $msg\n", $level, $time, 'cluster');
}

sub statusdir {
    my ($self, $node) = @_;

    return $self->{statusdir};
}

sub cluster_lock {
    my ($self, $code, @param) = @_;

    my $lockfile = "$self->{statusdir}/cluster.lck";
    my $fh = IO::File->new(">>$lockfile") ||
	die "unable to open '$lockfile'\n";

    my $success;
    for (;;) {
	$success = flock($fh, LOCK_EX);
	if ($success || ($! != EINTR)) {
	    last;
	}
	if (!$success) {
	    die "can't aquire lock '$lockfile' - $!\n";
	}
    }
     
    my $res;

    eval { $res = &$code(@param) };
    my $err = $@;

    close($fh);

    die $err if $err;
    
    return $res;
}

# simulate cluster commands
# power <node> <on|off>
# network <node> <on|off>

sub sim_cluster_cmd {
    my ($self, $cmdstr) = @_;

    my $code = sub {

	my $cstatus = $self->read_cluster_status_nolock();

	my ($cmd, $node, $action) = split(/\s+/, $cmdstr);

	die "sim_cluster_cmd: no node specified" if !$node;
	die "sim_cluster_cmd: unknown action '$action'" if $action !~ m/^(on|off)$/;

	my $haenv = $self->{nodes}->{$node}->{haenv};
	die "sim_cluster_cmd: no such node '$node'\n" if !$haenv;
	
	if ($cmd eq 'power') {
	    if ($cstatus->{$node}->{power} ne $action) {
		if ($action eq 'on') {
		    my $server = $self->{nodes}->{$node}->{server} = PVE::HA::Server->new($haenv);
		} elsif ($self->{nodes}->{$node}->{server}) {
		    $haenv->log('info', "server killed by poweroff");
		    $self->{nodes}->{$node}->{server} = undef;
		}
	    }

	    $cstatus->{$node}->{power} = $action;
	    $cstatus->{$node}->{network} = $action;

	} elsif ($cmd eq 'network') {
		$cstatus->{$node}->{network} = $action;
	} else {
	    die "sim_cluster_cmd: unknown command '$cmd'\n";
	}

	$self->log('info', "execute $cmdstr");

	$self->write_cluster_status_nolock($cstatus);
    };

    return $self->cluster_lock($code);
}

sub run {
    my ($self) = @_;

    for (;;) {

	my $starttime = $self->get_time();

	foreach my $node (sort keys %{$self->{nodes}}) {
	    my $haenv = $self->{nodes}->{$node}->{haenv};
	    my $server = $self->{nodes}->{$node}->{server};

	    next if !$server;

	    $haenv->loop_start_hook($self->get_time());

	    die "implement me" if !$server->do_one_iteration();

	    $haenv->loop_end_hook();

	    my $nodetime = $haenv->get_time();
	    $self->{cur_time} = $nodetime if $nodetime > $self->{cur_time};
	}

	$self->{cur_time} = $starttime + 20 if ($self->{cur_time} - $starttime) < 20;

	die "simulation end\n" if $self->{cur_time} > $max_sim_time;

	# apply new comand after 5 loop iterations

	if (($self->{loop_count} % 5) == 0) {
	    my $list = shift $self->{cmdlist};
	    return if !$list;

	    foreach my $cmd (@$list) {
		$self->sim_cluster_cmd($cmd);
	    }
	}

	++$self->{loop_count};
    }
}
 


1;
