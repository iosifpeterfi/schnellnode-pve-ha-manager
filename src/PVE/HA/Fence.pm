package PVE::HA::Fence;

use strict;
use warnings;

use POSIX qw( WNOHANG );

use PVE::HA::FenceConfig;

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	haenv => $haenv,
	workers => {}, # pid's and additional info of fence processes
	results => {}, # fence state of a node
    }, $class;

    return $self;
}

my $virtual_pid = 0; # hack for test framework

sub run_fence_jobs {
    my ($self, $node, $try) = @_;

    my $haenv = $self->{haenv};

    if (!$self->has_fencing_job($node)) {
	# start new fencing job(s)
	my $workers = $self->{workers};
	my $results = $self->{results};

	$try = 0 if !defined($try) || ($try < 0);

	my $fence_cfg = $haenv->read_fence_config();
	my $commands = PVE::HA::FenceConfig::get_commands($node, $try, $fence_cfg);

	if (!$commands) {
	    $haenv->log('err', "no fence commands for node '$node'");
	    $results->{$node}->{failure} = 1;
	    return 0;
	}

	$haenv->log('notice', "Start fencing node '$node'");

	my $can_fork = ($haenv->get_max_workers() > 0) ? 1 : 0;

	# when parallel devices are configured all must succeed
	$results->{$node}->{needed} = scalar(@$commands);
	$results->{$node}->{triggered} = 0;

	for my $cmd (@$commands) {
	    my $cmd_str = "$cmd->{agent} " .
		PVE::HA::FenceConfig::gen_arg_str(@{$cmd->{param}});
	    $haenv->log('notice', "[fence '$node'] execute cmd: $cmd_str");

	    if ($can_fork) {

		my $pid = fork();
		if (!defined($pid)) {
		    $haenv->log('err', "forking fence job failed");
		    return 0;
		} elsif ($pid == 0) {
		    $haenv->after_fork(); # cleanup child

		    $haenv->exec_fence_agent($cmd->{agent}, $node, @{$cmd->{param}});
		    Posix::_exit(-1);
		} else {

		    $workers->{$pid} = {
			cmd => $cmd_str,
			node => $node,
			try => $try
		    };

		}

	    } else {
		# for test framework
		my $res = -1;
		eval {
		    $res = $haenv->exec_fence_agent($cmd->{agent}, $node, @{$cmd->{param}});
		    $res = $res << 8 if $res > 0;
		};
		if (my $err = $@) {
		    $haenv->log('err', $err);
		}

		$virtual_pid++;
		$workers->{$virtual_pid} = {
		    cmd => $cmd_str,
		    node => $node,
		    try => $try,
		    ec => $res,
		};

	    }
	}

	return 1;

    } else {
	# check already deployed fence jobs
	$self->process_fencing();
    }
}

sub collect_finished_workers {
    my ($self) = @_;

    my $haenv = $self->{haenv};
    my $workers = $self->{workers};

    my @finished = ();

    if ($haenv->get_max_workers() > 0) { # check if we forked the fence worker
	foreach my $pid (keys %$workers) {
	    my $waitpid = waitpid($pid, WNOHANG);
	    if (defined($waitpid) && ($waitpid == $pid)) {
		$workers->{$waitpid}->{ec} = $?;
		push @finished, $waitpid;
	    }
	}
    } else {
	# all workers finish instantly when not forking
	@finished = keys %$workers;
    }

    return @finished;
};

sub check_worker_results {
    my ($self) = @_;

    my $haenv = $self->{haenv};

    my $succeeded = {};
    my $failed = {};

    my @finished = $self->collect_finished_workers();

    foreach my $pid (@finished) {
	my $w = delete $self->{workers}->{$pid};
	my $node = $w->{node};

	if ($w->{ec} == 0) {
	    # succeeded jobs doesn't need the status for now
	    $succeeded->{$node} = $succeeded->{$node} || 0;
	    $succeeded->{$node}++;
	} else {
	    $haenv->log('err', "fence job for node '$node' failed, command " .
	                       "'$w->{cmd}' exited with '$w->{ec}'");
	    # try count for all currently running workers per node is the same
	    $failed->{$node}->{tried_device_count} = $w->{try};
	}
    }

    return ($succeeded, $failed);
}

# get finished workers and process the result
sub process_fencing {
    my ($self) = @_;

    my $haenv = $self->{haenv};
    my $results = $self->{results};

    my $fence_cfg = $haenv->read_fence_config();

    my ($succeeded, $failed) = $self->check_worker_results();

    foreach my $node (keys %$succeeded) {
	# count how many fence devices succeeded
	$results->{$node}->{triggered} += $succeeded->{$node};
    }

    # try next device for failed jobs
    foreach my $node (keys %$failed) {
	my $tried_device_count = $failed->{$node}->{tried_device_count};

	# loop until we could start another fence try or we are out of devices to try
	while ($tried_device_count < PVE::HA::FenceConfig::count_devices($node, $fence_cfg)) {
	    # clean up the other parallel jobs, if any, as at least one failed
	    kill_and_cleanup_jobs($haenv, $node);

	    $tried_device_count++; # try next available device
	    return if run_fence_jobs($node, $tried_device_count);

	    $haenv->log('warn', "could not start fence job at try '$tried_device_count'");
	}

	$results->{$node}->{failure} = 1;
	$haenv->log('err', "tried all fence devices for node '$node'");
    }
};

sub has_fencing_job {
    my ($self, $node) = @_;

    my $workers = $self->{workers};

    foreach my $job (values %$workers) {
	return 1 if ($job->{node} eq $node);
    }

    return undef;
}

# if $node is undef we kill and cleanup *all* jobs from all nodes
sub kill_and_cleanup_jobs {
    my ($self, $node) = @_;

    my $haenv = $self->{haenv};
    my $workers = $self->{workers};
    my $results = $self->{results};

    while (my ($pid, $job) = each %$workers) {
	next if defined($node) && $job->{node} ne $node;

	if ($haenv->max_workers() > 0) {
	    kill KILL => $pid;
	    waitpid($pid, 0);
	}
	delete $workers->{$pid};
    }

    if (defined($node) && $results->{$node}) {
	delete $results->{$node};
    } else {
	$self->{results} = {};
	$self->{workers} = {};
    }
};

sub is_node_fenced {
    my ($self, $node) = @_;

    my $state = $self->{results}->{$node};
    return 0 if !$state;

    return -1 if $state->{failure} && $state->{failure} == 1;

    return ($state->{needed} && $state->{triggered} &&
	    $state->{triggered} >= $state->{needed}) ? 1 : 0;
}

1;
