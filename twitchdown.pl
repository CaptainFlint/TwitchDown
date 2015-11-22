#!/usr/bin/perl

use strict;
use warnings;

use LWP::UserAgent;
use JSON;

# How many threads to use for downloading video segments
my $NUM_THREADS = 12;

if (scalar(@ARGV) < 2) {
	print <<EOF;
Usage: $0 {URL|VideoID} {FileName} [OPTS]

Options:
  --start=TIME       Download video starting from the specified timestamp.
  --end=TIME         Download video up to the specified timestamp.
  --len=TIME         Download video only the specified length of time.

  Supported TIME formats:
  h:mm:ss
  h:mm       (seconds = 0)
  5h, 5m, 5s (5 hours, minutes or seconds)
EOF
	exit 1;
}

# Reading/parsing input arguments
my ($vid, $file, @opts) = @ARGV;
my $vid_type = 'v';
if ($vid =~ m|http://(?:www\.)?twitch\.tv/[^/]+/([^/])/(\d+)|) {
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

my %vod_time = ();
for (@opts) {
	if (m/^--(start|end|len)=(.*)/) {
		my ($k, $v) = ($1, $2);
		if ($v =~ m/^(\d+)(h|m|s)$/i) {
			$v = $1 * ( {'h' => 3600, 'm' => 60, 's' => 1}->{$2} );
		}
		elsif ($v =~ m/^(\d+):(\d+)(:(\d+))?/) {
			$v = $1 * 3600 + $2 * 60 + ($4 ? $4 : 0);
		}
		else {
			print "WARNING: Unrecognized time format '$v', skipping.\n";
			next;
		}
		$vod_time{$k} = $v;
	}
	else {
		print "WARNING: Unknown option '$_', skipping.\n";
	}
}
if (exists($vod_time{'start'}) && exists($vod_time{'end'}) && exists($vod_time{'len'})) {
	print "ERROR: Start, end and length cannot be specified all at once!\n";
	exit 1;
}
elsif (exists($vod_time{'start'}) && exists($vod_time{'end'})) {
	$vod_time{'len'} = $vod_time{'end'} - $vod_time{'start'};
	delete($vod_time{'end'});
}
elsif (exists($vod_time{'end'}) && exists($vod_time{'len'})) {
	$vod_time{'start'} = $vod_time{'end'} - $vod_time{'len'};
	delete($vod_time{'end'});
}
elsif (exists($vod_time{'start'}) && exists($vod_time{'len'})) {
	# Do nothing
}
elsif (exists($vod_time{'end'})) {
	$vod_time{'start'} = 0;
	$vod_time{'len'} = $vod_time{'end'};
	delete($vod_time{'end'});
}
elsif (exists($vod_time{'len'})) {
	$vod_time{'start'} = 0;
}
elsif (exists($vod_time{'start'})) {
	# Do nothing
}
else {
	$vod_time{'start'} = 0;
}

# Request overwriting the target file if necessary
if (-f $file) {
	print "File [$file] exists. Overwrite? (y/N) ";
	my $repl = <STDIN>;
	exit if ($repl !~ m/^y(es)?\s*$/i);
}

# Prepare downloader
my $ua = LWP::UserAgent->new();
$ua->timeout(600);

sub http_request($;$) {
	my ($url, $method) = @_;
	if (!$method) {
		$method = 'get';
	}
	my %headers = (
		'User-Agent' => 'Opera/9.80 (Windows NT 6.1; Win64; x64) Presto/2.12.388 Version/12.17',
		'Accept' => 'text/html, application/xml;q=0.9, application/xhtml+xml, image/png, image/webp, image/jpeg, image/gif, image/x-xbitmap, */*;q=0.1',
		'Accept-Language' => 'ru-RU,ru;q=0.9,en;q=0.8'
	);
	if ($method eq 'get') {
		return $ua->get($url, %headers);
	}
	if ($method eq 'head') {
		return $ua->head($url, %headers);
	}
	else {
		return undef;
	}
}

sub format_time($) {
	my ($sec) = @_;
	return sprintf('%d:%02d:%02d', int($sec / 3600), int(($sec % 3600) / 60), int($sec % 60));
}

# Checks whether part of the video intersects with any of the listed segments
sub is_crossed($$$) {
	my ($start, $len, $segments) = @_;
	# [a,b] ∩ [x,y] ≠ ∅  <=>  x ∈ [a,b] ∨ a ∈ [x,y]
	for my $seg (@$segments) {
		if ((($start >= $seg->{'offset'}) && ($start <= $seg->{'offset'} + $seg->{'duration'})) ||
		    (($seg->{'offset'} >= $start) && ($seg->{'offset'} <= $start + $len))) {
			return 1;
		}
	}
	return 0;
}

# Checks whether part of the video should be skipped due to user-specified input args
sub is_skipped($$) {
	my ($start, $len) = @_;
	if (exists($vod_time{'len'})) {
		return !is_crossed($start, $len, [{ 'offset' => $vod_time{'start'}, 'duration' => $vod_time{'len'} }]);
	}
	else {
		return ($start + $len < $vod_time{'start'});
	}
}

my $err = '';
my $playlist_file = '';
do {{
	my @warnings = ();

	# Download the VOD JSON
	my $res = http_request($vid_url);
	if (!$res->is_success) {
		$err = 'Failed to download JSON: ' . $res->status_line;
		last;
	}
	my $json_txt = $res->decoded_content;
	if (!$json_txt) {
		$err = 'Failed to obtain JSON decoded contents: ' . $res->status_line;
		last;
	}
	my $json = decode_json($json_txt);
	if (!$json->{'preview'}) {
		$err = 'JSON does not contain preview URL.';
		last;
	}
	if (scalar(@{$json->{'muted_segments'}}) > 0) {
		push @warnings, "Muted segments are present.";
	}

	# Construct the playlist URL
	my $m3u = $json->{'preview'};
	$m3u =~ s/static-cdn\.jtvnw\.net/vod\.ak\.hls\.ttvnw\.net/;
	if ($json->{'can_highlight'}) {
		$m3u =~ s/thumb\/thumb.*\.jpg/chunked\/index-dvr.m3u8/;
	}
	else {
		$m3u =~ s/thumb\/thumb.*\.jpg/chunked\/highlight-$vid.m3u8/;
	}

	# Download the playlist
	$res = http_request($m3u);
	if (!$res->is_success) {
		$err = "Failed to download playlist $m3u:\n" . $res->status_line;
		last;
	}
	my $playlist = $res->decoded_content;
	if (!$playlist) {
		$err = "Failed to obtain playlist decoded contents: " . $res->status_line;
		last;
	}

	# Save the playlist, modifying it for:
	# 1) being local;
	# 2) compactification;
	# 3) using correct URLs for muted parts.
	my @segment_urls = ();
	my $playlist_fh;
	my $data_dir = 'C:/Users/CaptainFlint/AppData/Local/Temp';
	$playlist_file = "$data_dir/index-dvr-$vid.m3u8";
	mkdir("$data_dir/twitch-vod-$vid");
	if (!open($playlist_fh, '>', $playlist_file)) {
		$err = "Failed to open temp file [$playlist_file]:\n$!";
		last;
	}
	binmode($playlist_fh);
	my $oldh = select(STDOUT);
	$| = 1;
	select($oldh);
	$m3u =~ s|/[^/]+$|/|;
	my $dt;
	my $dt_sum = 0;
	my $dt_sum_total = 0;
	my $current_ts = '';
	my $current_ts_start;
	my $current_ts_end;
	my $dump_current_ts = sub() {
		if ($current_ts) {
			# Dump the previously collected segment
			my $segment_file = $current_ts . (is_crossed($dt_sum_total, $dt_sum, $json->{'muted_segments'}) ? '-muted' : '') . '.ts';
			printf $playlist_fh "#EXTINF:%.3f,\n", $dt_sum;
			print $playlist_fh "twitch-vod-$vid/$segment_file\n";
			push @segment_urls, "$m3u$segment_file?start_offset=$current_ts_start&end_offset=$current_ts_end";
			$current_ts = '';
		}
		$dt_sum_total += $dt_sum;
		$dt_sum = 0;
	};
	for my $ln (split(m/\r?\n/, $playlist)) {
		if ($ln =~ m/^\x23EXTINF\s*:\s*([.\d]+),/) {
			$dt = $1;
		}
		elsif ($ln =~ m/^\x23EXT-X-TWITCH-DISCONTINUITY\s*:\s*([.\d]+)/) {
			push @warnings, "Stream contains a gap of $1 seconds.";
		}
		elsif ($ln =~ m/^(index-[^.]+)\.ts\?start_offset=(\d+)&end_offset=(\d+)/) {
			if ($1 ne $current_ts) {
				# New segment file
				$dump_current_ts->();
				if (!is_skipped($dt_sum_total + $dt_sum, $dt)) {
					($current_ts, $current_ts_start, $current_ts_end) = ($1, $2, $3);
				}
				$dt_sum += $dt;
			}
			else {
				# Same segment file continued - merging
				if (is_skipped($dt_sum_total + $dt_sum, $dt)) {
					$dump_current_ts->();
				}
				else {
					$current_ts_end = $3;
				}
				$dt_sum += $dt;
			}
		}
		else {
			$dump_current_ts->();
			print $playlist_fh "$ln\n";
		}
	}
	close($playlist_fh);
	last if ($err);

#if (!open($playlist_fh, '>', $playlist_file.".seg")) {
#	$err = "Failed to open temp file [$playlist_file.seg]:\n$!";
#	last;
#}
#binmode($playlist_fh);
#print $playlist_fh "$_\n" foreach (@segment_urls);
#close($playlist_fh);

	print "!!! WARNING: $_\n" foreach (@warnings);
	print "\n";

	my $seg_num = scalar(@segment_urls);
	my $seg_num_part = int($seg_num / $NUM_THREADS);
	++$seg_num_part if ($seg_num % $NUM_THREADS != 0);
	print "Downloading segments: $seg_num\n";
	my @children = ();
	for (my $tid = 0; $tid < $NUM_THREADS; ++$tid) {
print "Starting thread $tid.\n";
		my $pid = fork();
		if (!defined($pid)) {
			$err = "Failed to fork: $!";
			last;
		}
		elsif ($pid == 0) {
print "[$tid] Child started.\n";
			# Child process: downloading the corresponding part of segments list
			my $start_idx = $seg_num_part * $tid;
			my $end_idx = $seg_num_part * ($tid + 1);
			$end_idx = $seg_num if ($end_idx > $seg_num);
			for (my $i = $start_idx; $i < $end_idx; ++$i) {
				my $seg_url = $segment_urls[$i];
				my $seg_file = ($seg_url =~ s|^.*/([^/?]+)\?.*$|$1|r);
				$res = http_request($seg_url);
				if (!$res->is_success) {
					$err = "[$tid] Failed to download segment $seg_file: " . $res->status_line;
					last;
				}
				my $seg_fh;
				if (!open($seg_fh, '>', "$data_dir/twitch-vod-$vid/$seg_file")) {
					$err = "[$tid] Failed to open segment file $seg_file:\n$!";
					last;
				}
				binmode($seg_fh);
				print $seg_fh ${$res->content_ref};
				close($seg_fh);
print "[$tid] Segment file No.$i '$seg_file' done.\n";
			}
			if ($err) {
				print STDERR "$err\n";
				exit(1);
			}
			else {
				print "[$tid] Finished.\n";
				exit(0);
			}
		}
		else {
			# Parent process: continue creating threads
			push @children, $pid;
print "Child with PID $pid started.\n";
		}
	}
	if ($err) {
		kill 'KILL', @children;
		last;
	}
	while (($res = wait()) != -1) {
		print "wait returned $res, thread's exit code: " . ($? >> 8) . "\n";
		if ($?) {
			$err = "Some of the segments could not be downloaded, aborting.\n";
			kill 'KILL', @children;
			last;
		}
	}
	last if ($err);

#	my $idx = 0;
#	for my $seg_url (@segment_urls) {
#		++$idx;
#		my $seg_file = ($seg_url =~ s|^.*/([^/?]+)\?.*$|$1|r);
#print "Segment file $idx: $seg_file...";
#		$res = http_request($seg_url);
#		if (!$res->is_success) {
#			$err = 'Failed to download segment $seg_file: ' . $res->status_line;
#			last;
#		}
#		my $seg_fh;
#		if (!open($seg_fh, '>', "$data_dir/twitch-vod-$vid/$seg_file")) {
#			$err = "Failed to open segment file $seg_file:\n$!";
#			last;
#		}
#		binmode($seg_fh);
#		print $seg_fh ${$res->content_ref};
#		close($seg_fh);
#print " Done.\n";
#	}

	# Finally, launch ffmpeg to do the rest of work
	system('C:/Programs/ffmpeg/bin/ffmpeg.exe -y -i ' . $playlist_file . ' -c copy -bsf:a aac_adtstoasc "' . $file . '"');
}} while (0);

# Some cleanup
unlink($playlist_file);

if ($err) {
	print STDERR "Error: $err\n";
	exit 2;
}
