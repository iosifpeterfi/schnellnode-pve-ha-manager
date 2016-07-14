#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;

use File::Path qw(make_path remove_tree);

use lib '..';

use PVE::Tools;
use PVE::HA::FenceConfig;

use Data::Dumper;

my $opt_nodiff;

if (!GetOptions ("nodiff"   => \$opt_nodiff)) {
    print "usage: $0 testdir [--nodiff]\n";
    exit -1;
}

sub _log {
    my ($fh, $source, $message) = @_;

    chomp $message;
    $message = "[$source] $message" if $source;

    print "$message\n";

    $fh->print("$message\n");
    $fh->flush();
};

sub get_nodes {
    # three node should be enough for testing
    # don't make it to complicate for now
    return ('node1', 'node2', 'node3');
};

# compares if two data structures are equivalent.
# the may contain hashes, arrays, scalars. May be nested also, we travel
# through the structure recursively
sub deep_cmp {
    my ($a, $b, $noerr) = @_;

    eval {
	if (ref($a) ne ref($b)) {
	    die "variables not the same ref: " . ref($a) ." != " . ref($b) . "\n";
	}

	if (ref($a) eq 'HASH') {
	    if (scalar(keys %$a) != scalar(keys %$b)) {
		die "variables are not of the same length\n";
	    }

	    my %cmp = map { $_ => 1 } keys %$a;
	    for my $key (keys %$b) {
		if (!exists $cmp{$key}) {
		    die "variables not equal";
		}
		if(!deep_cmp($a->{$key}, $b->{$key})) {
		    die "variables not equal";
		}
		delete $cmp{$key};
	    }

	    die "variables not equal" if %cmp;

	} elsif (ref($a) eq 'ARRAY') {
	    if (scalar(@$a) != scalar(@$b)) {
		die "variables are not of the same length\n";
	    }

	    for (my $i = 0; $i < scalar(@$a); $i++) {
		if(!deep_cmp(@$a[$i], @$b[$i])) {
		    die "variables not equal";
		}
	    }

	} elsif (ref($a) eq 'SCALAR' || ref($a) eq '') {

	    if(defined $a && defined $b) {
		return $a eq $b;
	    } else {
		return !(defined $a || defined $b);
	    }

	} else {
	    die "unimplemented ref type: '" . ref($a) . "'\n";
	}
    };
    if (my $err = $@) {
	$err = "deep_cmp: $err";
	die $err if !$noerr;
	warn $err;
	return undef;
    }

	return 1;
}

sub check_cfg {
    my ($cfg_fn, $outfile) = @_;

    my $raw = PVE::Tools::file_get_contents($cfg_fn);

    my $log_fh = IO::File->new(">$outfile") ||
	die "unable to open '$outfile' - $!";

    my $config;
    eval {
	$config = PVE::HA::FenceConfig::parse_config($cfg_fn, $raw);
    };
    if (my $err = $@) {
	_log($log_fh, 'FenceConfig', $err);
	return;
    }

    my @nodes = get_nodes();

    # cycle through all nodes with some tries
    for (my $i=0; 1; $i++) {
	_log($log_fh, "try", $i);

	my $node_has_cmd = 0;
	foreach my $node (@nodes) {

	    my $commands = PVE::HA::FenceConfig::get_commands($node, $i, $config);
	    if($commands) {
		$node_has_cmd = 1;
		foreach my $cmd (sort { $a->{sub_dev} <=> $b->{sub_dev} }  @$commands) {
		    my $cmd_str = "$cmd->{agent} " .
		       PVE::HA::FenceConfig::gen_arg_str(@{$cmd->{param}});
		    _log($log_fh, "$node-cmd", "$cmd_str");
		}
	    } else {
		_log($log_fh, "$node-cmd", "none");
	    }

	}
	# end if no node has a device left
	last if !$node_has_cmd;
    }
};

sub parser_self_check {
    my $cfg_fn = shift;

    print "* parser self check: $cfg_fn\n";

    my $outfile = "$cfg_fn.write";
    my ($config1, $config2, $raw);

    eval {
	# read first time
	$raw = PVE::Tools::file_get_contents($cfg_fn);
	$config1 = PVE::HA::FenceConfig::parse_config($cfg_fn, $raw);
    };
    if (my $err = $@) {
	print "* initial parse failed, skip parser self check\n\n";
	return;
    }

    eval {
	# write config
	$raw = PVE::HA::FenceConfig::write_config($outfile, $config1);
	PVE::Tools::file_set_contents($outfile, $raw);

	# reread written config (must be the same as config1)
	$raw = PVE::Tools::file_get_contents($outfile);
	$config2 = PVE::HA::FenceConfig::parse_config($outfile, $raw);

    };
    if (my $err = $@) {
	die "parser_self_check test error: $err";
    }

    my $res;
    eval {
	$res = deep_cmp($config1, $config2);
    };
    if (my $err = $@ || !$res) {
	die "parser_self_check test failed! Configs not equivalent\n" .
	     Dumper($config1, $config2) . "\n";
    }

    print "* end parser_self_check: $cfg_fn (success)\n\n";
}

sub run_test {
    my $cfg_fn = shift;

    print "check: $cfg_fn\n";

    my $outfile = "$cfg_fn.commands";
    my $expect = "$cfg_fn.expect";

    eval {
	check_cfg($cfg_fn, $outfile);
    };
    if (my $err = $@) {
	die "Test '$cfg_fn' failed:\n$err\n";
    }

    return if $opt_nodiff;

    my $res;

    if (-f $expect) {
	my $cmd = ['diff', '-u', $expect, $outfile];
	$res = system(@$cmd);
	die "test '$cfg_fn' failed\n" if $res != 0;
    } else {
	$res = system('cp', $outfile, $expect);
	die "test '$cfg_fn' failed\n" if $res != 0;
    }
    print "end: $cfg_fn (success)\n";
}


# exec tests

if (my $testcfg = shift) {
    run_test($testcfg);
    parser_self_check($testcfg);
} else {
    foreach my $cfg (<fence_cfgs/*.cfg>) {
	run_test($cfg);
	parser_self_check($cfg);
    }
}
