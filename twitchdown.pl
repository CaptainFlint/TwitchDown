#!/usr/bin/perl

use strict;
use warnings;

use LWP::UserAgent;

if (scalar(@ARGV) < 2) {
	print "Usage: $0 {URL|VideoID} {FileName}\n";
	exit 1;
}

my ($vid, $file) = @ARGV;
my $vid_type = 'v';
if ($vid =~ m|http://www.twitch.tv/[^/]+/([^/])/(\d+)|) {
	$vid_type = $1;
	$vid = $2;
}
elsif ($vid =~ m/^([a-z])(\d+)$/) {
	$vid_type = $1;
	$vid = $2;
}
elsif ($vid !~ m/^\d+$/) {
	print "Invalid video specified!\n";
	exit 1;
}
my $vid_url = 'http://api.twitch.tv/api/videos/' . $vid_type . $vid;

my $err = '';
do {{
	my $ua = LWP::UserAgent->new();
	$ua->timeout(600);
	my $res = $ua->get(
		$vid_url,
		'User-Agent' => 'Opera/9.80 (Windows NT 6.1; Win64; x64) Presto/2.12.388 Version/12.17',
		'Accept' => 'text/html, application/xml;q=0.9, application/xhtml+xml, image/png, image/webp, image/jpeg, image/gif, image/x-xbitmap, */*;q=0.1',
		'Accept-Language' => 'ru-RU,ru;q=0.9,en;q=0.8'
	);
	if (!$res->is_success) {
		$err = "Failed to download JSON: " . $res->status_line;
		last;
	}
	my $content = $res->decoded_content;
	if (!$content) {
		$err = "Failed to obtain JSON decoded contents: " . $res->status_line;
		last;
	}
	if ($content !~ m/"preview"\s*:\s*"([^\"]+)"/) {
		$err = "JSON does not contain preview URL.";
		last;
	}
#	print $content . "\n";
	my $m3u = $1;
	my $hl = 0;
	if ($content !~ m/"can_highlight"\s*:\s*true/) {
		$hl = 1;
	}
	$m3u =~ s/static-cdn\.jtvnw\.net/vod\.ak\.hls\.ttvnw\.net/;
	if ($hl) {
		$m3u =~ s/thumb\/thumb.*\.jpg/chunked\/highlight-$vid.m3u8/;
	}
	else {
		$m3u =~ s/thumb\/thumb.*\.jpg/chunked\/index-dvr.m3u8/;
	}
	if (-f $file) {
		print "File \"$file\" exists. Overwrite? (y/N) ";
		my $repl = <STDIN>;
		last if ($repl !~ m/^y(es)?\s*$/i);
	}
	system('C:/Programs/ffmpeg/bin/ffmpeg.exe -y -i ' . $m3u . ' -c copy -bsf:a aac_adtstoasc "' . $file . '"');
}} while (0);
if ($err) {
	print STDERR "Error: $err\n";
	exit 2;
}
