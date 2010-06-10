#!/usr/bin/env perl
use strict;
use warnings;

# ###########################################################################
# ProcessLog package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End ProcessLog package
# ###########################################################################

# ###########################################################################
# TablePartitions package GIT_VERSION
# ###########################################################################
# ###########################################################################
# End TablePartitions package
# ###########################################################################

package main;
use strict;
use warnings;
use English qw(-no_match_vars);

use ProcessLog;
use TablePartitions;

use DBI;
use Getopt::Long;
use Pod::Usage;
use DateTime;
use DateTime::Format::Strptime;

# Defined since Nagios::Plugin doesn't always exist.
use constant OK       => 0;
use constant WARNING  => 1;
use constant CRITICAL => 2;
use constant UNKNOWN  => 3;

my (
  $db_host,
  $db_user,
  $db_pass,
  $db_schema,
  $db_table,
  $range,
  $verify
);

GetOptions(
  "help" => sub { pod2usage(-verbose => 2, -noperldoc => 1); },
  "host|h=s" => \$db_host,
  "user|u=s" => \$db_user,
  "pass|p=s" => \$db_pass,
  "database|d=s" => \$db_schema,
  "table|t=s" => \$db_table,
  "range|r=s" => \$range,
  "verify|n=s" => \$verify
);

unless($db_host and $db_user and $db_pass and $db_schema and $db_table and $range and $verify) {
  pod2usage(-message => "All parameters are required.", -verbose => 1);
}

$range = lc($range);

unless($range =~ /^(?:days|weeks|months)$/) {
  pod2usage(-message => "Range must be one of: days, weeks, or months.", -verboes => 1);
}

my $dbh =  DBI->connect("DBI:mysql:$db_schema;host=$db_host", $db_user, $db_pass, { RaiseError => 1, PrintError => 0, AutoCommit => 0});

my $pl = ProcessLog->null;
my $parts = TablePartitions->new($pl, $dbh, $db_schema, $db_table);
my $last_ptime = 0;
my $last_p = $parts->last_partition;

if($last_p->{description} eq 'MAXVALUE') {
  $last_p = $parts->partitions->[-2];
}

$last_ptime = to_date($parts->desc_from_datelike($last_p->{name}));
my $today = DateTime->today(time_zone => 'local');

my $du = $last_ptime - $today;

if($range eq 'days') {
  $du = $last_ptime->delta_days($today);
}

$dbh->disconnect;

if($du->in_units($range) < $verify) {
  print "CRITICAL: Not enough partitions. ". $du->in_units($range) . " $range less than $verify $range\n";
  exit(CRITICAL);
}
else {
  print "OK: Enough partitions. ". $du->in_units($range) . " $range greater than, or equal to $verify $range\n";
  exit(OK);
}

print 'UNKNOWN: Very strange error. How did we get here?';
exit(UNKNOWN);

sub to_date {
  my ($dstr) = @_;
  my $fmt1 = DateTime::Format::Strptime->new(pattern => '%Y-%m-%d', time_zone => 'local');
  my $fmt2 = DateTime::Format::Strptime->new(pattern => '%Y-%m-%d %T', time_zone => 'local');
  return ($fmt1->parse_datetime($dstr) || $fmt2->parse_datetime($dstr))->truncate( to => 'day' );
}

=pod

=head1 NAME

table_partitions - Ensure partitions exist for N days/weeks/months.

=head1 SYNOPSIS

table_partitions -h <host> -d <schema> -t <table> -r <range> -n <num>

=head1 OPTIONS

=over 8

=item --help

This help.

=item --host,-h

DB host.

=item --user,-u

DB user.

=item --pass,-p

DB password.

=item --database,-d

DB database(schema).

=item --table,-t

DB table.

=item --range,-r

One of: days, weeks, or months.

See L<pdb-parted> for details on the meaning.

=item --verify,-n

How many L<-r>, i.e., days, weeks. or months to ensure exist from the current date.

=back

=head1 VERSION

This is the version of the script as it exists in the PalominoDB git repository.
It's placed for diagnostic purposes.

SCRIPT_GIT_VERSION

=cut

1;
