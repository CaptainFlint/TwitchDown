#!/usr/bin/perl

use strict;
use warnings;

my $url = 'https://www.twitch.tv/videos/255822477';
my $name = '180429-snt';
my $quality = '';
#my $quality = '720p60';
my $force_path = "E:\\DiskE\\Temp\\!twitch";
my @parts = split(m/\s+/s, <<DATA);
	1.18-2.25
	f1:3.38
DATA
my $idx = 1;

sub shift_time($$) {
	my ($tm, $adj) = @_;
	my ($hr, $min) = split(m/\./, $tm);
	if ($tm) {
		$min += $adj;
		if ($min < 0) {
			$min += 60;
			--$hr;
		}
		elsif ($min >= 60) {
			$min -= 60;
			++$hr;
		}
	}
	return sprintf("%d:%02d", $hr, $min);
}

foreach my $part (@parts) {
	next if ($part eq '');
	if (index($part, ':') >= 0) {
		($idx, $part) = split(m/:/, $part);
	}
	my ($start, $end) = split(m/-/, $part);
	$end = $start if (!defined($end));
	$start =~ s/\/.*//g;
	$end =~ s/\/.*//g;
	my $target = ($quality ? (($force_path || "N:\\unsorted\\_twitch") . "\\${name}_$idx-$quality.mp4") : "E:\\DiskE\\Temp\\!twitch\\${name}_$idx.mp4");
	my $cmdline = "perl K:\\Programs\\Perl\\twitchdown\\twitchdown.pl $url $target" . ($quality ? ' --quality=' . $quality : '') . ($start ? (" --start=" . shift_time($start, -3)) : '') . ($end ? (" --end=" . shift_time($end, +3)) : '');
	print "$cmdline\n";
	system($cmdline);
	print "\n\n";
	++$idx;
}
