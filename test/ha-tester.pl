#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;

use File::Path qw(make_path remove_tree);

use PVE::Tools;


my $opt_nodiff;

if (!GetOptions ("nodiff"   => \$opt_nodiff)) {
    print "usage: $0 testdir [--nodiff]\n";
    exit -1;
}


#my $testcmd = "../pve-ha-manager --test"

sub run_test {
    my $dir = shift;

    $dir =~ s!/+$!!;

    print "run: $dir\n";
    my $statusdir = "$dir/status";
    remove_tree($statusdir);
    mkdir $statusdir;

    if (-f "$dir/manager_status") {
	system("cp $dir/manager_status $statusdir/manager_status");
    }
    if (-f "$dir/service_status") {
	system("cp $dir/service_status $statusdir/service_status");
    }

    system("cp $dir/cluster_status $statusdir/cluster_status");

    my $logfile = "$dir/log";
    my $logexpect = "$logfile.expect";

    my $res = system("../pve-ha-manager --test '$dir'|tee $logfile");
    die "Test '$dir' failed\n" if $res != 0;

    return if $opt_nodiff;

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



