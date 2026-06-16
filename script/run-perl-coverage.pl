#!/usr/bin/env perl
use strict;
use warnings;

use FindBin qw($RealBin);
use Config qw(%Config);
use File::Path qw(remove_tree);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
use lib ();

my $threshold = shift(@ARGV) // 80;
my $home = $ENV{HOME} // '';
my @extra_libs = grep { -d $_ } (
    File::Spec->catdir($home, 'perl5', 'lib', 'perl5'),
    File::Spec->catdir($home, 'perl5', 'lib', 'perl5', $Config{archname}),
);
lib->import(@extra_libs);

eval {
    require Devel::Cover;
    1;
} or die "Devel::Cover is required for coverage runs. Install it with cpanm Devel::Cover.\n";

my $root = File::Spec->catdir($RealBin, '..');
my $local_bin = File::Spec->catdir($home, 'perl5', 'bin');
my $cover_db = File::Spec->catdir($root, 'cover_db');
my $prove_bin = File::Spec->catfile($Config{bin}, 'prove');
remove_tree($cover_db) if -d $cover_db;
local $ENV{PERL5LIB} = join(
    ':',
    grep { defined && length }
    (@extra_libs, split(/:/, $ENV{PERL5LIB} // ''))
);
local $ENV{PATH} = join(
    ':',
    grep { defined && length }
    ($local_bin, split(/:/, $ENV{PATH} // ''))
);
local $ENV{HARNESS_PERL_SWITCHES} = "-MDevel::Cover=-silent,1,-db,$cover_db";
my $stderr = gensym();
my $pid = open3(
    undef,
    my $stdout,
    $stderr,
    $prove_bin,
    '-Ilib',
    't',
);

my $output = do { local $/; <$stdout> // '' };
my $errors = do { local $/; <$stderr> // '' };
waitpid($pid, 0);
my $status = $? >> 8;

print $output if length $output;
print STDERR $errors if length $errors;
exit $status if $status != 0;

my $cover_bin = File::Spec->catfile($local_bin, 'cover');
$cover_bin = 'cover' if !-x $cover_bin;
my $cover_output = `$cover_bin -select ^lib/ -report text $cover_db`;
print $cover_output;

my ($line_rate) = $cover_output =~ /^Total\s+(\d+(?:\.\d+)?)\s+/m;
die "Unable to determine total line coverage from cover output.\n" if !defined $line_rate;

if ($line_rate < $threshold) {
    die sprintf("Coverage %.2f%% is below required %.2f%%.\n", $line_rate, $threshold);
}

print sprintf("Coverage %.2f%% meets required %.2f%%.\n", $line_rate, $threshold);
