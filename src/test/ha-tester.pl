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

sub run_test {
    my $dir = shift;

    $dir =~ s!/+$!!;

    print "run: $dir\n";

    my $logfile = "$dir/status/log";
    my $logexpect = "$dir/log.expect";

    my $res = system("perl -I ../ ../pve-ha-tester $dir");
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



