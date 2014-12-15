package PVE::Daemon;

use strict;
use warnings;
use PVE::SafeSyslog;
use PVE::INotify;
use PVE::RPCEnvironment;

use POSIX ":sys_wait_h";
use Fcntl ':flock';
use Getopt::Long;
use Time::HiRes qw (gettimeofday);

use base qw(PVE::CLIHandler);

$SIG{'__WARN__'} = sub {
    my $err = $@;
    my $t = $_[0];
    chomp $t;
    print "$t\n";
    syslog('warning', "WARNING: %s", $t);
    $@ = $err;
};

$ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';

PVE::INotify::inotify_init();

my $daemon_initialized = 0; # we only allow one instance

my $lockpidfile = sub {
    my ($self) = @_;

    my $lkfn = $self->{pidfile} . ".lock";

    if (!open (FLCK, ">>$lkfn")) {
	my $msg = "can't aquire lock on file '$lkfn' - $!";
	syslog ('err', $msg);
	die "ERROR: $msg\n";
    }

    if (!flock (FLCK, LOCK_EX|LOCK_NB)) {
	close (FLCK);
        my $msg = "can't aquire lock '$lkfn' - $!";
	syslog ('err', $msg);
	die "ERROR: $msg\n";
    }
};

my $writepidfile = sub {
    my ($self) = @_;

    my $pidfile = $self->{pidfile};

    if (!open (PIDFH, ">$pidfile")) {
	my $msg = "can't open pid file '$pidfile' - $!";
	syslog ('err', $msg);
	die "ERROR: $msg\n";
    } 
    print PIDFH "$$\n";
    close (PIDFH);
};

my $server_cleanup = sub {
    my ($self) = @_;

    unlink $self->{pidfile} . ".lock";
    unlink $self->{pidfile};
};

my $server_run = sub {
    my ($self, $debug) = @_;

    &$lockpidfile($self);

    # run in background
    my $spid;

    my $restart = $ENV{RESTART_PVE_DAEMON};

    delete $ENV{RESTART_PVE_DAEMON};

    if ($restart) {
	syslog('info' , "restarting server");
    } else {
	syslog('info' , "starting server");
    }

    $self->init();

    if (!$debug) {
	open STDIN,  '</dev/null' || die "can't read /dev/null";
	open STDOUT, '>/dev/null' || die "can't write /dev/null";
    }

    if (!$restart && !$debug) {
	$spid = fork();
	if (!defined ($spid)) {
	    my $msg =  "can't put server into background - fork failed";
	    syslog('err', $msg);
	    die "ERROR: $msg\n";
	} elsif ($spid) { # parent
	    exit (0);
	}
    } 

    &$writepidfile($self);
   
    open STDERR, '>&STDOUT' || die "can't close STDERR\n";
 
    $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = sub { 
	$SIG{INT} = 'DEFAULT';

	eval { $self->shutdown(); };
	warn $@ if $@;

	&$server_cleanup($self);
   };

    $SIG{HUP} = sub {
	eval { $self->hup(); };
	warn $@ if $@;
    };

    eval { $self->run() };
    my $err = $@;
    
    if ($err) {
	syslog ('err', "ERROR: $err");
	$self->restart_daemon(5);
	exit (0);
    }

    syslog("info", "server stopped");
};

sub new {
    my ($this, $name, $cmdline) = @_;

    die "please run as root\n" if $> != 0;

    die "missing name" if !$name;

    die "can't create more that one PVE::Daemon" if $daemon_initialized;
    $daemon_initialized = 1;

    initlog($name);

    my $class = ref($this) || $this;

    my $self = bless { name => $name }, $class;

    $self->{pidfile} = "/var/run/${name}.pid";

    my $rpcenv = PVE::RPCEnvironment->init('cli');

    $rpcenv->init_request();
    $rpcenv->set_language($ENV{LANG});
    $rpcenv->set_user('root@pam');

    $self->{rpcenv} = $rpcenv;

    $self->{nodename} = PVE::INotify::nodename();

    $self->{cmdline} = $cmdline;

    $0 = $name;

    return $self;
}

sub restart_daemon {
    my ($self, $waittime) = @_;

    syslog('info', "server shutdown (restart)");
    
    $ENV{RESTART_PVE_DAEMON} = 1;

    sleep($waittime) if $waittime; # avoid high server load due to restarts

    PVE::INotify::inotify_close();

    exec (@{$self->{cmdline}});

    exit (-1); # never reached?
}

# please overwrite in subclass
sub init {
    my ($self) = @_;

}

# please overwrite in subclass
sub shutdown {
    my ($self) = @_;

    syslog('info' , "server closing");

    # wait for children
    1 while (waitpid(-1, POSIX::WNOHANG()) > 0);
}

# please overwrite in subclass
sub hup {
    my ($self) = @_;

    syslog('info' , "received signal HUP (restart)");  
}

# please overwrite in subclass
sub run {
    my ($self) = @_;

    for (;;) { # forever
	syslog('info' , "server is running");
	sleep(5);
    }
}

sub start {
    my ($self, $debug) = @_;

    &$server_run($self, $debug);
}

sub running {
    my ($self) = @_;
   
    my $pid = int(PVE::Tools::file_read_firstline($self->{pidfile}) || 0);
    return 0 if !$pid;

    return PVE::ProcFSTools::check_process_running($pid);
}

sub stop {
    my ($self) = @_;
   
    my $pid = int(PVE::Tools::file_read_firstline($self->{pidfile}) || 0);
    return if !$pid;

    if (PVE::ProcFSTools::check_process_running($pid)) {
	kill(15, $pid); # send TERM signal
	# give max 5 seconds to shut down
	for (my $i = 0; $i < 5; $i++) {
	    last if !PVE::ProcFSTools::check_process_running($pid);
	    sleep (1);
	}
       
	# to be sure
	kill(9, $pid); 
	waitpid($pid, 0);
    }
	
    if (-f $self->{pidfile}) {
	# try to get the lock
	&$lockpidfile($self);
	&$server_cleanup($self);
    }
}

1;

