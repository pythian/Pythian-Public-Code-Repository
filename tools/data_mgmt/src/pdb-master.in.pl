#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

# ###########################################################################
# ProcessLog package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End ProcessLog package
# ###########################################################################

# ###########################################################################
# IniFile package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End IniFile package
# ###########################################################################

# ###########################################################################
# Path package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End Path package
# ###########################################################################

# ###########################################################################
# DSN package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End DSN package
# ###########################################################################

# ###########################################################################
# RObj package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End RObj package
# ###########################################################################

# ###########################################################################
# MysqlInstance package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End MysqlInstance package
# ###########################################################################

# ###########################################################################
# MysqlMasterInfo package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End MysqlMasterInfo package
# ###########################################################################

# ###########################################################################
# MysqlSlave package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End MysqlSlave package
# ###########################################################################

package ReMysql;
use strict;
use warnings FATAL => 'all';
use Data::Dumper;
$Data::Dumper::Indent = 0;
use Carp;
use Path;

my $pid_check_sleep = 10;
my $stop_timeout = 3;
my $start_timeout = 3;
my $slave_timeout = 3;

sub new {
  my ($class, $dry_run, $sandbox_path, $dsn) = @_;
  my $self = {};
  $$self{dsn} = $dsn;
  $$self{dry_run} = $dry_run;
  $$self{sandbox_path} = $sandbox_path;
  $$self{inst} = MysqlInstance->from_dsn($dsn);
  $$self{save_mysql} = 1;
  bless $self, $class;

  $self->verify_permissions();

  return $self;
}

sub _ro() {
  my $self = shift;
  $$self{ro} ||= RObj->new($$self{dsn}->get('h'),
    $$self{dsn}->get('sU'), $$self{dsn}->get('sK'));
  return $$self{ro}->copy;
}

sub verify_permissions {
  my ($self) = @_;
  $self->verify_ssh();
  my $config = $$self{inst}->config();
  $$self{config} = $config;

  my $ro = $self->_ro;
  $ro->add_main(\&verify_user_permissions);
  $::PLOG->d($$self{dsn}->get('h').':', 'Preflight: ssh user permissions');
  my @r = $ro->do($config);
  if($r[0] ne 'EXIT') {
    croak($r[0]);
  }
  unless($r[1] == 1) {
    croak('Invalid permissions on remote');
  }
  $self->verify_mysql_permissions();

  return 1;
}

sub verify_ssh {
  my $self = shift;
  my $host = $$self{dsn};
  my $ro = $self->_ro;
  $::PLOG->d($$self{dsn}->get('h').':', 'Preflight: ssh');
  $ro->add_main(sub { return 'OK' });
  my @r = $ro->do();
  unless($r[1] eq 'OK') {
   croak('Unable to ssh to remote');
  }
  return 1;
}

sub verify_user_permissions {
  my $cfg = shift;
  my $r = {};

  my $pid = ($$cfg{'mysqld'}{'pid-file'} || $$cfg{'mysqld_safe'}{'pid-file'});
  die('No pid-file entry in my.cnf') unless($pid);
  die('No datadir entry in my.cnf') unless($$cfg{'mysqld'}{'datadir'});

  open PID_FILE, '<', $pid or die('Unable to open or read pid file');
  chomp($pid = <PID_FILE>);
  close(PID_FILE);

  my @dirs = (
    $$cfg{'mysqld'}{'datadir'},
    '/proc/'. $pid
  );

  for(@dirs) {
    die('Directory "'. (defined($_) ? $_ : 'undef') .'" does not exist') unless( defined($_) && -d $_ );
    my @st = stat($_);
    my ($uid, $gid, $mode) = @st[4,5,2];
    die('User does not own "'. $_ .'"') unless($< == 0 or $uid == $<);
  }

  die('path /tmp/mysql exists') if(-e '/tmp/mysql');

  return 1;
}

sub verify_mysql_permissions {
  my $self = shift;
  $::PLOG->d($$self{dsn}->get('h').':', 'Preflight: verify mysql permissions');
  $$self{dsn}->get_dbh(1);
  my ($gstr) = $$self{dsn}->get_dbh(1)->selectrow_array('SHOW GRANTS');
  if($gstr !~ /SUPER/ and $gstr !~ / ALL /) {
    croak('mysql user needs SUPER');
  }
  return 1;
}

sub make_slave_of {
  my ($self, $master, $user, $pw) = @_;
  $master = $$master{dsn};
  my $ms1 = MysqlSlave->new($master);
  my $ms2 = MysqlSlave->new($$self{dsn});
  my ($m1_file, $m1_pos) = $ms1->master_status();
  my ($binlog_base) = ($m1_file =~ /^(.+)\.\d+$/);
  $::PLOG->d($$self{dsn}->get('h').':', 'making slave of', $master->get('h'));
  $ms2->stop_slave();
  $ms2->change_master_to(
    master_host => $master->get('h'),
    master_user => $user,
    master_port => $master->get('P'),
    master_password => $pw,
    master_log_file => sprintf("$binlog_base.%06d", 1),
    master_log_pos  => 4
  );
  $ms2->start_slave();
  my $i = 0;
  my $status = defined($ms2->slave_status()->{'Seconds_Behind_Master'}
    ? 1 : 0);
  while($i < 3 and !$status) {
    $status = defined($ms2->slave_status()->{'Seconds_Behind_Master'}
      ? 1 : 0);
    sleep(1);
  }
  continue {
    $i++;
  }
  unless($status) {
    croak('Slave not running after 3 seconds');
  }
}

sub copy_data {
  my ($self, $sandbox_path) = @_;
  my $hostname = $$self{dsn}->get('h');
  my $key = $$self{dsn}->get('sK');
  my $user = $$self{dsn}->get('sU');
  my $datadir = $$self{config}{'mysqld'}{'datadir'};
  $::PLOG->d($$self{dsn}->get('h').':', 'copying data');
  system('scp',
    '-B', '-C', '-r',
    '-p', '-q',
    $key ? ('-i', $key) : (),
    <$sandbox_path/data/*>,
    "$user\@${hostname}:$datadir"
  );
  return $? >> 8;
}

#sub empty_datadir {
#  my $self = shift;
#  my $ro = $self->_ro;
#  $ro->add_package('Path');
#  $ro->add_main(sub { Path::dir_empty($_[0]) });
#  $::PLOG->d($$self{dsn}->get('h').':', 'emptying datadir:',
#    $$self{config}{'mysqld'}{'datadir'});
#  my @r =$ro->do($$self{config}{'mysqld'}{'datadir'});
#  die($r[0]) unless($r[0] eq 'EXIT');
#  return 0;
#}

sub check_mysql_pid {
  my $cfg = shift;
  my $pid;
  eval {
    open PID_FILE, '<', $$cfg{'mysqld'}{'pid-file'} or die($!);
    chomp($pid = <PID_FILE>);
  };
  if(defined $pid and -d '/proc/'. $pid ) {
    return 1;
  }
  return 0;
}

#sub stop_mysql {
#  my $self = shift;
#  my $host = $$self{dsn};
#  my $i=0;
#  my $mi = $$self{inst};
#  $::PLOG->d($$self{dsn}->get('h').':', 'stopping mysql');
#  $mi->stop;
#  my $cfg = $$self{config};
#  my $pid_check = $self->_ro;
#  $pid_check->add_main(\&check_mysql_pid);
#  my @r = $pid_check->do($cfg);
#  if($r[0] ne 'EXIT' and $r[0] !~ /No such file/) {
#    die($r[0]) if($r[0] ne 'EXIT');
#  }
#  elsif($r[0] =~ /No such file/) {
#    return 1;
#  }
#  while($i < $stop_timeout and $r[1]) {
#    $::PLOG->d($host->get('h'). ':', 'Waiting for mysql stop..');
#    sleep($pid_check_sleep);
#    $i++;
#    @r = $pid_check->do($cfg);
#  }
#  if($i == $stop_timeout) {
#    die('mysql did not stop in a timely fashion');
#  }
#}
#
#sub start_mysql {
#  my $self = shift;
#  my $host = $$self{dsn};
#  my $i=0;
#  my $mi = $$self{inst};
#  $::PLOG->d($$self{dsn}->get('h').':', 'starting mysql');
#  $mi->start;
#  my $cfg = $$self{config};
#  my $pid_check = $self->_ro;
#  $pid_check->add_main(\&check_mysql_pid);
#  my @r = $pid_check->do($cfg);
#  die($r[0]) if($r[0] ne 'EXIT' and $r[0] !~ /No such file/);
#  while($i < $start_timeout and (!$r[1] or $r[0] =~ /No such file/)) {
#    $::PLOG->d($host->get('h'). ':', 'Waiting for mysql start..');
#    sleep($pid_check_sleep);
#    $i++;
#    @r = $pid_check->do($cfg);
#  }
#  if($i == $start_timeout) {
#    die('mysql did not start in a timely fashion');
#  }
#}

sub rebuild_rmot {
  my $params = shift;
  my $start_timeout = $$params{'start_timeout'};
  my $stop_timeout = $$params{'stop_timeout'};
  my $pid_check_sleep = $$params{'pid_check_sleep'};
  my $save_mysqldb = $$params{'save_mysqldb'};
  my $mi = MysqlInstance->new('localhost');
  my $cfg = $mi->config;
  my $datadir = $$cfg{'mysqld'}{'datadir'};
  my $i=0;

# #############################################################################
# Stop mysql
# #############################################################################

  $mi->stop;
  while($i < $stop_timeout && check_mysql_pid($cfg)) {
    sleep($pid_check_sleep);
    $i++;
  }
  if($i == $stop_timeout) {
    die('mysql did not stop in a timely fashion');
  }
  $i = 0;

# #############################################################################
# Save mysql db to /tmp
# #############################################################################

  system('mv', $datadir . '/mysql', '/tmp/');

# #############################################################################
# Remove existing data
# #############################################################################

  Path::dir_empty($datadir);

# #############################################################################
# print status (removed datadir), and wait for signal (continue)
# #############################################################################

  R_print('datadir ready');
  my @r = R_read();
  unless($r[0] eq 'continue') {
    die('Received invalid signal from controller');
  }

# #############################################################################
# Remove ib_logfiles
# #############################################################################

  unlink($datadir . "/ib_logfile0");
  unlink($datadir . "/ib_logfile1");

# #############################################################################
# Remove new mysql db and restore old from /tmp
# #############################################################################

  system('rm', '-rf', $datadir . '/mysql');
  system('mv', '/tmp/mysql', $datadir . '/');

# #############################################################################
# Start mysql
# #############################################################################

  $mi->start;
  while($i < $start_timeout && !check_mysql_pid($cfg)) {
    sleep($pid_check_sleep);
    $i++;
  }
  if($i == $start_timeout) {
    die('mysql did not start in a timely fashion');
  }

  return 0;
}

sub rebuild {
  my $self;
  my $ro = $self->_ro;
  $ro->add_package('IniFile');
  $ro->add_package('MysqlInstance::Methods');
  $ro->add_package('MysqlInstance');
  $ro->add_package('Path');
  $ro->add_sub(\&check_mysql_pid);
  $ro->add_main(\&rebuild_remote);

  $ro->start({
      start_timeout => $start_timeout,
      stop_timeout => $stop_timeout,
      pid_check_sleep => $pid_check_sleep,
      save_mysqldb => $$self{'save_mysql'}
    });
  
  my @r = $ro->read();
  
  unless($r[0] eq 'datadir ready') {
    die('Got invalid signal from remote end: '. $r[0]);
  }
  else {
    $self->copy_data($$self{sandbox_path});
    $ro->write('continue');
  }
  $ro->wait();
  return 0;
}

#sub rebuild {
#  my $self = shift;
#  my $datadir = $$self{config}{'mysqld'}{'datadir'};
#  my @r;
#
#  unless($$self{dry_run}) {
## #############################################################################
## Stop mysql on remote
## #############################################################################
#
#    $self->stop_mysql;
#
## #############################################################################
## Save the mysql database to /tmp on remote
## #############################################################################
#
#    my $ro = $self->_ro;
#    if($$self{save_mysql}) {
#      $::PLOG->d($$self{dsn}->get('h').':', 'Saving mysql database');
#      $ro->add_main(sub {
#          my $config = shift;
#          my $datadir = shift;
#          my $r = system('mv', "$datadir/mysql", '/tmp/');
#          return $r >> 8;
#        });
#      @r = $ro->do($$self{config}, $datadir);
#      die($r[0]. ' ret: '. $r[1]) unless($r[0] eq 'EXIT' and $r[1] == 0);
#    }
#
## #############################################################################
## Remove existing data and copy over new data
## #############################################################################
#
#    $self->empty_datadir();
#    if($self->copy_data($$self{sandbox_path})) {
#      die($$self{dsn}->get('h') .': Error encountered while copying data');
#    }
#
## #############################################################################
## Remove the ib_logfiles, since they may not be the right size.
## #############################################################################
#
#
## #############################################################################
## Replace the mysql database from /tmp
## #############################################################################
#
#    $ro = $self->_ro;
#    if($$self{save_mysql}) {
#      $::PLOG->d($$self{dsn}->get('h').':', 'Restoring mysql database');
#      $ro->add_main(sub {
#          my $config = shift;
#          my $datadir = shift;
#          system('rm', '-rf', "$datadir/mysql");
#          my $r = system('mv', "/tmp/mysql", $datadir);
#          if($< == 0) {
#            system('chown', '-R', 'mysql:mysql', $datadir);
#          }
#          return $r >> 8;
#        });
#      @r = $ro->do($$self{config}, $datadir);
#      die($r[0]. ' ret: '. $r[1]) unless($r[0] eq 'EXIT' and $r[1] == 0);
#    }
#
## #############################################################################
## Start mysql on remote
## #############################################################################
#
#    $self->start_mysql;
#
#  } ## $dry_run
#  else {
#    $::PLOG->d($$self{dsn}->get('h').':', ' dry-run: rebuild not done');
#  }
#
#  return 0;
#}

1;

package PdbMaster;
use strict;
use warnings FATAL => 'all';

our $VERSION = 0.01;
use Getopt::Long qw(:config no_ignore_case);
use Pod::Usage;
use POSIX ':sys_wait_h';
use Data::Dumper;
use Carp;

use DSN;
use ProcessLog;
use IniFile;
use MysqlSlave;
use MysqlInstance;
use MysqlMasterInfo;
use RObj;

my $pl;
my $dry_run = 0;
my $sandbox_path;


sub main {
  my @ARGV = @_;
  my $dsnp = DSNParser->default();
  my (%o, @hosts);
  $o{'logfile'} = 'pdb-test-harness';
  GetOptions(\%o,
    'help|h',
    'dry-run|n',
    'logfile|L',
    'repl-user=s',
    'repl-password=s'
  );
  if(scalar @ARGV < 2) {
    pod2usage(-message => "Must have a sandbox and at least two DSNs",
      -verbose => 1);
  }
  $dry_run = $o{'dry-run'};
  $sandbox_path = shift @ARGV;
  @hosts        = @ARGV;
  if(! -d $sandbox_path or ! -f "$sandbox_path/my.sandbox.cnf" ) {
    pod2usage(-message => "First argument must be a sandbox directory.",
      -verbose => 1);
  }

  $pl = ProcessLog->new($0, $o{'logfile'}, undef);
  {
    no strict 'refs';
    no warnings 'once';
    *::PLOG = \$pl;
  }
  @hosts = map { $dsnp->parse($_) } @hosts;
  $pl->i("pdb-master v$VERSION build SCRIPT_GIT_VERSION");
  foreach my $host (@hosts) {
    my $host_cfg;
    eval {
      $host = ReMysql->new($dry_run, $sandbox_path, $host);
    };
    if($@) {
      chomp($@);
      $pl->e('Error in pre-flight check for host:', $host->get('h'));
      $pl->e('Error:', $@);
      return 1;
    }
  }

  $pl->i('All pre-flight checks passed. Beginning work.');
  my @pids;
  foreach my $host (@hosts) {
    push @pids, spawn_worker($host);
    $pl->d('Process:', $pids[-1], 'started.');
  }

  my $kid;
  while( ($kid = waitpid(-1, 0)) >= 0 ) {
    # If there was an error with any of the workers,
    # kill them all!
    $pl->d('Return code:', ($? >> 8));
    if( ($? >> 8) > 0 ) {
      for(@pids) {
        kill(15, $_); # Send SIGTERM
      }
      $pl->e('One of the workers encountered an error.');
      return 1;
    }
    else {
      $pl->d('Process:', $kid, 'completed.');
    }
  }

  $pl->d('All hosts prepped for re-slaving.');
  $hosts[0]->make_slave_of($hosts[1], $o{'repl-user'}, $o{'repl-password'});
  $hosts[1]->make_slave_of($hosts[0], $o{'repl-user'}, $o{'repl-password'});

  foreach my $host (@hosts[2 .. $#hosts]) {
    $host->make_slave_of($hosts[0], $o{'repl-user'}, $o{'repl-password'});
  }
  $pl->i('pdb-master finished.');
  return 0;
}

sub spawn_worker {
  my $host = shift;
  my $pid = fork();
  if(not defined($pid)) {
    croak("fork failed [$!]");
  }
  if($pid) {
    return $pid;
  }
  exit($host->rebuild());
}


if(!caller) { exit(main(@ARGV)); }

1;
