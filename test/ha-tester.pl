#!/usr/bin/perl

use strict;
use warnings;
use File::Path qw(make_path remove_tree);

use PVE::Tools;

#my $testcmd = "../pve-ha-manager --test"

sub run_test {
    my $dir = shift;

    $dir =~ s!/+$!!;

    print "run: $dir\n";
    my $statusdir = "$dir/status";
    remove_tree($statusdir);
    mkdir $statusdir;
    my $logfile = "$dir/log";
    my $logexpect = "$logfile.expect";

    my $res = system("../pve-ha-manager --test '$statusdir'|tee $logfile");
    die "Test '$dir' failed\n" if $res != 0;

    if (-f $logexpect) {
	my $cmd = ['diff', '-u', $logexpect, $logfile]; 
	$res = system(@$cmd);
	die "test '$dir' failed\n" if $res != 0;
    } else {
	$res = system('cp', $logfile, $logexpect);
	die "test '$dir' failed\n" if $res != 0;
    }
    print "end: $dir (success)\n";
}

if (my $testdir = shift) {
    run_test($testdir);
} else {
    foreach my $dir (<test-*>) {
	run_test($dir);
    }
}



