package PVE::HA::Sim::Env;

use strict;
use warnings;
use POSIX qw(strftime EINTR);
use Data::Dumper;
use JSON; 
use IO::File;
use Fcntl qw(:DEFAULT :flock);

use PVE::HA::Tools;
use PVE::HA::Env;

sub new {
    my ($this, $nodename, $hardware) = @_;

    die "missing nodename" if !$nodename;

    my $class = ref($this) || $this;

    my $self = bless {}, $class;

    $self->{statusdir} = $hardware->statusdir();
    $self->{nodename} = $nodename;

    $self->{hardware} = $hardware;
    $self->{cur_time} = 0;
    $self->{loop_delay} = 0;

    return $self;
}

sub nodename {
    my ($self) = @_;

    return $self->{nodename};
}

sub read_local_status {
    my ($self, $name) = @_;

    my $node = $self->{nodename};
    my $filename = "$self->{statusdir}/${name}_status_$node";
    my $default = { state => 'wait_for_quorum' };  
    return PVE::HA::Tools::read_json_from_file($filename, $default); 
}

sub write_local_status {
    my ($self, $name, $status) = @_;

    my $node = $self->{nodename};
    my $filename = "$self->{statusdir}/${name}_status_$node";
    
    PVE::HA::Tools::write_json_to_file($filename, $status);  
}

sub sim_get_lock {
    my ($self, $lock_name, $unlock) = @_;

    return 0 if !$self->quorate();

    my $filename = "$self->{statusdir}/cluster_locks";

    my $code = sub {

	my $data = PVE::HA::Tools::read_json_from_file($filename, {});  

	my $res;

	my $nodename = $self->nodename();
	my $ctime = $self->get_time();

	if ($unlock) {

	    if (my $d = $data->{$lock_name}) {
		my $tdiff = $ctime - $d->{time};
	    
		if ($tdiff > 120) {
		    $res = 1;
		} elsif (($tdiff <= 120) && ($d->{node} eq $nodename)) {
		    delete $data->{$lock_name};
		    $res = 1;
		} else {
		    $res = 0;
		}
	    }

	} else {

	    if (my $d = $data->{$lock_name}) {
	    
		my $tdiff = $ctime - $d->{time};
	    
		if ($tdiff <= 120) {
		    if ($d->{node} eq $nodename) {
			$d->{time} = $ctime;
			$res = 1;
		    } else {
			$res = 0;
		    }
		} else {
		    $self->log('info', "got lock '$lock_name'");
		    $d->{node} = $nodename;
		    $res = 1;
		}

	    } else {
		$data->{$lock_name} = {
		    time => $ctime,
		    node => $nodename,
		};
		$self->log('info', "got lock '$lock_name'");
		$res = 1;
	    }
	}

	PVE::HA::Tools::write_json_to_file($filename, $data); 

	return $res;
    };

    return $self->{hardware}->global_lock($code);
}

sub read_manager_status {
    my ($self) = @_;
    
    my $filename = "$self->{statusdir}/manager_status";

    return PVE::HA::Tools::read_json_from_file($filename, {});  
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    my $filename = "$self->{statusdir}/manager_status";

    PVE::HA::Tools::write_json_to_file($filename, $status_obj); 
}

sub manager_status_exists {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/manager_status";
 
    return -f $filename ? 1 : 0;
}

sub read_service_config {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/service_config";
    my $conf = PVE::HA::Tools::read_json_from_file($filename); 

    foreach my $sid (keys %$conf) {
	my $d = $conf->{$sid};
	$d->{current_node} = $d->{node} if !$d->{current_node};
	if ($sid =~ m/^pvevm:(\d+)$/) {
	    $d->{type} = 'pvevm'; 
	    $d->{name} = $1;
	} else {
	    die "implement me";
	}
	$d->{state} = 'disabled' if !$d->{state};
    }

    return $conf;
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    my $time = $self->get_time();

    printf("%-5s %5d %10s: $msg\n", $level, $time, $self->{nodename});
}

sub get_time {
    my ($self) = @_;

    return $self->{cur_time};
}

sub sleep {
   my ($self, $delay) = @_;

   $self->{loop_delay} += $delay;
}

sub sleep_until {
   my ($self, $end_time) = @_;

   my $cur_time = $self->{cur_time} + $self->{loop_delay};

   return if $cur_time >= $end_time;

   $self->{loop_delay} += $end_time - $cur_time;
}

sub get_ha_manager_lock {
    my ($self) = @_;

    my $res = $self->sim_get_lock('ha_manager_lock');
    ++$self->{loop_delay};
    return $res;
}

sub get_ha_agent_lock_name {
    my ($self, $node) = @_;

    $node = $self->nodename() if !$node;

    return "ha_agent_${node}_lock";
}

sub get_ha_agent_lock {
    my ($self) = @_;

    my $lck = $self->get_ha_agent_lock_name();
    my $res = $self->sim_get_lock($lck);
    ++$self->{loop_delay};

    return $res;
}

sub test_ha_agent_lock {
    my ($self, $node) = @_;

    my $lck = $self->get_ha_agent_lock_name($node);
    my $res = $self->sim_get_lock($lck);
    $self->sim_get_lock($lck, 1) if $res; # unlock

    ++$self->{loop_delay};
    return $res;
}

# return true when cluster is quorate
sub quorate {
    my ($self) = @_;

    my ($node_info, $quorate) = $self->{hardware}->get_node_info();
    my $node = $self->nodename();
    return 0 if !$node_info->{$node}->{online};
    return $quorate;
}

sub get_node_info {
    my ($self) = @_;

    return $self->{hardware}->get_node_info();
}

sub loop_start_hook {
    my ($self, $starttime) = @_;

    $self->{loop_delay} = 0;

    die "no starttime" if !defined($starttime);
    die "strange start time" if $starttime < $self->{cur_time};

    $self->{cur_time} = $starttime;

    # do nothing
}

sub loop_end_hook {
    my ($self) = @_;

    my $delay = $self->{loop_delay};
    $self->{loop_delay} = 0;

    die "loop take too long ($delay seconds)\n" if $delay > 30;

    $self->{cur_time} += $delay;
}

sub watchdog_open {
    my ($self) = @_;

    my $node = $self->nodename();

    return $self->{hardware}->watchdog_open($node);
}

sub watchdog_update {
    my ($self, $wfh) = @_;

    return $self->{hardware}->watchdog_update($wfh);
}

sub watchdog_close {
    my ($self, $wfh) = @_;

    return $self->{hardware}->watchdog_close($wfh);
}

1;
