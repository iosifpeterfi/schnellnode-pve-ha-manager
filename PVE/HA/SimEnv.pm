package PVE::HA::SimEnv;

use strict;
use warnings;
use POSIX qw(strftime);

use PVE::HA::Env;

use base qw(PVE::HA::Env);

my $max_sim_time = 1000;

sub log {
    my ($self, $level, $msg) = @_;

    my $time = $self->get_time();

    my $timestr = strftime("%H:%M:%S", gmtime($time));

    print "$level $timestr: $msg\n";
}

my $cur_time = 0;

sub get_time {
    my ($self) = @_;

    return $cur_time;
}

sub sleep {
   my ($self, $delay) = @_;

   $cur_time += $delay;
}

sub get_ha_manager_lock {
    my ($self) = @_;

    ++$cur_time;

    return 1;
}

sub loop_start_hook {
    my ($self) = @_;

    $self->{loop_start_time} = $cur_time;

    # do nothing
}

sub loop_end_hook {
    my ($self) = @_;

    my $delay = $cur_time - $self->{loop_start_time};

    die "loop take too long ($delay seconds)\n" if $delay > 20;

    $cur_time++;

    die "simulation end\n" if $cur_time > $max_sim_time;
}

1;
