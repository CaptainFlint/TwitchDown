#!/usr/bin/perl

use strict;
use warnings;

my $url = 'https://www.twitch.tv/squirrel/v/81915754';
my $name = '160805-fernbus+jalopy';
my @parts = split(m/\s+/s, <<DATA);
	1.10/18.11/3/6.40-1.18/18.19/4/2.50
	1.25/18.26/1/7.59-1.47
	1.52/9/6.12
	2.13/19.14/12/1.40-4.20/21.21/3/7.00
	4.46/21.47-5.03/22.04/4/6.10
DATA

sub shift_time($$) {
	my ($tm, $adj) = @_;
	my ($hr, $min) = split(m/\./, $tm);
	$min += $adj;
	if ($min < 0) {
		$min += 60;
		--$hr;
	}
	elsif ($min >= 60) {
		$min -= 60;
		++$hr;
	}
	return sprintf("%d:%02d", $hr, $min);
}

my $idx = 1;
foreach my $part (@parts) {
	next if ($part eq '');
	my ($start, $end) = split(m/-/, $part);
	$end = $start if (!defined($end));
	$start =~ s/\/.*//g;
	$end =~ s/\/.*//g;
	my $cmdline = "perl K:\\Programs\\Perl\\twitchdown\\twitchdown.pl $url E:\\DiskE\\Temp\\!twitch\\${name}_$idx.mp4 --start=" . shift_time($start, -3) . ($end ? (" --end=" . shift_time($end, +3)) : '');
	print "$cmdline\n";
	system($cmdline);
	print "\n\n";
	++$idx;
}
