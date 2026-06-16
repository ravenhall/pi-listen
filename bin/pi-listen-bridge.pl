#!/usr/bin/env perl
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use Pi::Listen::Bridge qw(main);

exit main(@ARGV);
