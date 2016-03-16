package PVE::HA::Fence;

use strict;
use warnings;
use POSIX qw( WNOHANG );
use PVE::HA::FenceConfig;
use Data::Dumper;


 # pid's and additional info of fence processes
my $fence_jobs = {};

# fence state of a node
my $fenced_nodes = {};

sub has_fencing_job { # update for parallel fencing
    my ($node) = @_;

    foreach my $job (values %$fence_jobs) {
	return 1 if ($job->{node} eq $node);
    }
    return undef;
}

my $virtual_pid = 0; # hack for test framework

sub start_fencing {
    my ($haenv, $node, $try) = @_;

    $try = 0 if !defined($try) || $try<0;

    my $fence_cfg = $haenv->read_fence_config();
    my $commands = PVE::HA::FenceConfig::get_commands($node, $try, $fence_cfg);

    if (!$commands) {
	$haenv->log('err', "no commands for node '$node'");
	$fenced_nodes->{$node}->{failure} = 1;
	return 0;
    }

    $haenv->log('notice', "Start fencing of node '$node'");

    my $can_fork = ($haenv->get_max_workers() > 0) ? 1 : 0;

    $fenced_nodes->{$node}->{needed} = scalar @$commands;
    $fenced_nodes->{$node}->{triggered} = 0;

    for my $cmd (@$commands)
    {
	my $cmd_str = "$cmd->{agent} " .
	    PVE::HA::FenceConfig::gen_arg_str(@{$cmd->{param}});
	$haenv->log('notice', "[fence '$node'] execute fence command: $cmd_str");

	if ($can_fork) {
	    my $pid = fork();
	    if (!defined($pid)) {
		$haenv->log('err', "forking fence job failed");
		return 0;
	    } elsif ($pid==0) { # child
		$haenv->exec_fence_agent($cmd->{agent}, $node, @{$cmd->{param}});
		exit(-1);
	    } else {
		$fence_jobs->{$pid} = {cmd=>$cmd_str, node=>$node, try=>$try};
	    }
	} else {
	    my $res = -1;
	    eval {
		$res = $haenv->exec_fence_agent($cmd->{agent}, $node, @{$cmd->{param}});
		$res = $res << 8 if $res > 0;
	    };
	    if (my $err = $@) {
		$haenv->log('err', $err);
	    }

	    $virtual_pid++;
	    $fence_jobs->{$virtual_pid} = {cmd => $cmd_str, node => $node,
					   try => $try, ec => $res};
	}
    }

    return 1;
}


# check childs and process exit status
my $check_jobs = sub {
    my ($haenv) = @_;

    my $succeeded = {};
    my $failed = {};

    my @finished = ();

    # pick up all finsihed childs if we can fork
    if ($haenv->get_max_workers() > 0) {
	while((my $res = waitpid(-1, WNOHANG))>0) {
	    $fence_jobs->{$res}->{ec} = $? if $fence_jobs->{$res};
	    push @finished, $res;
	}
    } else {
	@finished = keys %{$fence_jobs};
    }

    #    while((my $res = waitpid(-1, WNOHANG))>0) {
    foreach my $res (@finished) {
	if (my $job = $fence_jobs->{$res}) {
	    my $ec = $job->{ec};

	    my $status = {
		exit_code => $ec,
		cmd => $job->{cmd},
		try => $job->{try}
	    };

	    if ($ec == 0) {
		$succeeded->{$job->{node}} = $status;
	    } else {
		$failed->{$job->{node}} = $status;
	    }

	    delete $fence_jobs->{$res};

	} else {
	    warn "exit from unknown child (PID=$res)";
	}

    }

    return ($succeeded, $failed);
};


my $reset_hard = sub {
    my ($haenv, $node) = @_;

    while (my ($pid, $job) = each %$fence_jobs) {
	next if $job->{node} ne $node;

	if ($haenv->max_workers() > 0) {
	    kill KILL => $pid;
	    # fixme maybe use an timeout even if kill should not hang?
	    waitpid($pid, 0); # pick it up directly
	}
	delete $fence_jobs->{$pid};
    }

    delete $fenced_nodes->{$node} if $fenced_nodes->{$node};
};


# pick up jobs and process them
sub process_fencing {
    my ($haenv) = @_;

    my $fence_cfg = $haenv->read_fence_config();

    my ($succeeded, $failed) = &$check_jobs($haenv);

    foreach my $node (keys %$succeeded) {
	# count how many fence devices succeeded
	# this is needed for parallel devices
	$fenced_nodes->{$node}->{triggered}++;
    }

    # try next device for failed jobs
    while(my ($node, $job) = each %$failed) {
	$haenv->log('err', "fence job failed: '$job->{cmd}' returned '$job->{exit_code}'");

	while($job->{try} < PVE::HA::FenceConfig::count_devices($node, $fence_cfg) )
	{
	    &$reset_hard($haenv, $node);
	    $job->{try}++;

	    return if start_fencing($node, $job->{try});

	    $haenv->log('warn', "Couldn't start fence try '$job->{try}'");
	}

	    $haenv->log('err', "Tried all fence devices\n");
	    # fixme: returnproper exit code so CRM waits for the agent lock
    }
}


sub is_node_fenced {
    my ($node) = @_;

    my $state = $fenced_nodes->{$node};
    return 0 if !$state;

    return -1 if $state->{failure} && $state->{failure} == 1;

    return ($state->{needed} && $state->{triggered} &&
	   $state->{triggered} >= $state->{needed}) ? 1 : 0;
}


sub reset {
    my ($node, $noerr) = @_;

    delete $fenced_nodes->{$node} if $fenced_nodes->{$node};
}


sub bail_out {
    my ($haenv) = @_;

    if ($haenv->max_workers() > 0) {
	foreach my $pid (keys %$fence_jobs) {
	    kill KILL => $pid;
	    waitpid($pid, 0); # has to come back directly
	}
    }

    $fenced_nodes = {};
    $fence_jobs = {};
}

1;
