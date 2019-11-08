#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use JSON;
use File::Path 'remove_tree';
use Term::ANSIColor;

if ($^O eq 'MSWin32') {
	require Win32::Console::ANSI;
	require Win32::Mutex;
}

my $options = {
	# Directory for downloading segment files
	'data_dir' => 'C:/Users/CaptainFlint/AppData/Local/Temp',
	# Full path to ffmpeg executable
	'ffmpeg_exe' => 'C:/Programs/ffmpeg/bin/ffmpeg.exe',
	# Twitch authentication token
	'twitch_auth' => '',
	# How many threads to use for downloading video segments
	'num_threads' => 12,
	# Number of segment download retries
	'num_retries' => 5,
	# Whether to try mergning segments by file names (seems to not work lately)
	'ts_merge' => 0,
	# Stream type to fetch
	#'stream_id' => 'VIDEO="720p30"',  # Specific type
	'stream_id' => 'VIDEO="chunked"',  # Source
};

my $ini_file = $FindBin::Bin . '/twitchdown.ini';
my $ini_fh;
if (open($ini_fh, '<', $ini_file)) {
	while (<$ini_fh>) {
		if (m/^([^\x23]\S*)\s*=\s*(.*)/) {
			$options->{$1} = $2;
		}
	}
}

if (scalar(@ARGV) < 2) {
	print <<EOF;
Usage: $0 {URL|VideoID} {FileName} [OPTIONS]

Options:
  --token=AUTH       Twitch authentication token. To obtain one, go to 
                     https://api.twitch.tv/kraken/oauth2/authorize/?response_type=token&client_id=ewvlchtxgqq88ru9gmfp1gmyt6h2b93&scope=user_read+user_subscriptions&redirect_uri=http://livestreamer.tanuki.se/en/develop/twitch_oauth.html
                     and after you authorize you'll get redirected to a
                     non-existent page; get the access_token value from the URL.
  --start=TIME       Download video starting from the specified timestamp.
  --end=TIME         Download video up to the specified timestamp.
  --len=TIME         Download video only the specified length of time.
  --quality=SPEC     Specify stream quality specification to download.
  --numthreads=N     Number of parallel download threads.

  Supported TIME formats:
  h:mm:ss
  h:mm         (seconds = 0)
  5h, 5m, 5[s] (5 hours, 5 minutes, or 5 seconds)
EOF
	exit 1;
}

# Reading/parsing input arguments
my ($vid, $file, @opts) = @ARGV;
my $vid_type = 'v';
if ($vid =~ m!https?://(?:www\.|secure\.|go\.)?twitch\.tv/[^/]+/([^/])/(\d+)(\?.*)?!) {
	$vid_type = $1;
	$vid = $2;
}
elsif ($vid =~ m!https?://(?:www\.|secure\.|go\.)?twitch\.tv/[^/]+/(\d+)(\?.*)?!) {
	$vid = $1;
}
elsif ($vid =~ m/^([a-z])(\d+)$/) {
	$vid_type = $1;
	$vid = $2;
}
elsif ($vid !~ m/^\d+$/) {
	print colored("Invalid video specified!\n", 'bold red');
	exit 1;
}

my %vod_time = ();
for (@opts) {
	if (m/^--(start|end|len)=(.*)/) {
		my ($k, $v) = ($1, $2);
		if ($v =~ m/^(\d+)(h|m|s|)$/i) {
			$v = $1 * ( {'h' => 3600, 'm' => 60, 's' => 1, '' => 1}->{$2} );
		}
		elsif ($v =~ m/^(\d+):(\d+)(:(\d+))?/) {
			$v = $1 * 3600 + $2 * 60 + ($4 ? $4 : 0);
		}
		else {
			print colored("WARNING: Unrecognized time format '$v', skipping.\n", 'bold yellow');
			next;
		}
		$vod_time{$k} = $v;
	}
	elsif (m/^--token=(\S+)/) {
		$options->{'twitch_auth'} = $1;
	}
	elsif (m/^--quality=(\S+)/) {
		$options->{'stream_id'} = 'VIDEO="' . $1 . '"';
	}
	elsif (m/^--numthreads=(\S+)/) {
		$options->{'num_threads'} = $1;
	}
	else {
		print colored("WARNING: Unknown option '$_', skipping.\n", 'bold yellow');
	}
}
if (exists($vod_time{'start'}) && exists($vod_time{'end'}) && exists($vod_time{'len'})) {
	print colored("ERROR: Start, end and length cannot be specified all at once!\n", 'bold red');
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

# Downloader
my $ua;

sub http_request($;$) {
	my ($url, $method) = @_;
	# Lazy downloader initialization
	if (!$ua) {
		require LWP::UserAgent;
		$ua = LWP::UserAgent->new();
		$ua->timeout(600);
		$ua->ssl_opts(verify_hostname => 0);
	}
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

use Fcntl qw/:flock :seek/;
my $LOG_FILE = 'S:/twitch/virtualairshows/twitchdown-coords.log';
unlink($LOG_FILE);
# Append message to the log
# Input parameters:
#	$msg - text message to write
# Return value:
#	none
sub LOG($) {
	my ($msg) = @_;
	my $log_fh;
	if (open($log_fh, '>>', $LOG_FILE)) {
		flock($log_fh, LOCK_EX);
		seek($log_fh, 0, SEEK_END); # In the case if someone has written to the file in between open() and flock().
		my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime();
		my $date = sprintf('%02d.%02d.%04d %02d:%02d:%02d', $mday, ($mon + 1), ($year + 1900), $hour, $min, $sec);
		print $log_fh "$date\t" . $msg . "\n";
		flock($log_fh, LOCK_UN);
		close($log_fh);
	}
}

# Puts colored character at the specified position (0-based) of the progress bar.
# Cursor originally is located at the end, and returned there after printing.

# To debug:
# perl K:\Programs\Perl\twitchdown\twitchdown.pl https://www.twitch.tv/virtualairshows/v/89921084 S:\twitch\virtualairshows\16.mp4 --token=XXXXXXX

sub ensureCursorPos($$) {
	my ($x, $y) = @_;
	Win32::Console::ANSI::Cursor($x, $y);
	for (my $i = 0; $i < 100; ++$i) {
		my ($xpos, $ypos) = Win32::Console::ANSI::Cursor();
		if (($xpos == $x) && ($ypos == $y)) {
			last;
		}
		else {
			++$i;
			select(undef, undef, undef, 0.01);
		}
	}
}

my $put_char_mutex = Win32::Mutex->new();
my ($xend, $yend);
sub put_char($$$$) {
	my ($char, $pos, $len, $color) = @_;
	$put_char_mutex->wait();
	my ($w, $h) = Win32::Console::ANSI::XYMax();
	# Position of the beginning of the progress bar (assume it always starts from newline)
	my ($xstart, $ystart) = (1, $yend - int($len / $w));
	# Position of the character to insert
	my ($xpos, $ypos) = ($xstart + ($pos % $w), $ystart + int($pos / $w));
	ensureCursorPos($xpos, $ypos);
	print colored($char, $color);
	ensureCursorPos($xend, $yend);
	$put_char_mutex->release();
}

my $err = '';
my $playlist_file = '';
do {{
	my @warnings = ();

	# Validate access token
	my $json_txt = `"C:/Program Files/Git/mingw64/bin/curl.exe" -H "Accept: application/vnd.twitchtv.v5+json" -H "Authorization: OAuth $options->{'twitch_auth'}" -X GET https://api.twitch.tv/kraken 2>nul`;
	my $json = decode_json($json_txt);
	if (!$json->{'token'}->{'valid'}) {
		$err = "Access token is invalid!";
		last;
	}

	# Request access token
	my $token_url = 'https://api.twitch.tv/api/vods/' . $vid . '/access_token?as3=t&oauth_token=' . $options->{'twitch_auth'};
	my $res = http_request($token_url);
	if (!$res->is_success) {
		$err = "Failed to download JSON by $token_url\n" . $res->status_line;
		last;
	}
	$json_txt = $res->decoded_content;
	if (!$json_txt) {
		$err = 'Failed to obtain JSON decoded contents: ' . $res->status_line;
		last;
	}
	$json = decode_json($json_txt);
	if (!$json->{'sig'} || !$json->{'token'}) {
		$err = 'JSON does not contain preview URL.';
		last;
	}
	my $nauth = ($json->{'token'} =~ s/([^a-z0-9_])/sprintf('%%%02x', ord($1))/egr);
	
	# Download meta-playlist
	my $meta_playlist_url = 'http://usher.twitch.tv/vod/' . $vid . '?nauth=' . $nauth . '&nauthsig=' . $json->{'sig'} . '&allow_source=true&player=twitchweb&allow_spectre=true';
	$res = http_request($meta_playlist_url);
	if (!$res->is_success) {
		$err = 'Failed to download meta-playlist: ' . $res->status_line;
		last;
	}
	my $meta_playlist = $res->decoded_content;
	if (!$meta_playlist) {
		$err = 'Failed to obtain meta-playlist decoded contents: ' . $res->status_line;
		last;
	}

	# Fetch the 'source' playlist
	my $m3u;
	my $found = 0;
	for (split(m/\n/, $meta_playlist)) {
		if (m/$options->{'stream_id'}/i) {
			$found = 1;
		}
		elsif (m/^http:/ && $found) {
			$m3u = $_;
			last;
		}
	}
	if (!$m3u) {
		$err = "Failed to find the playlist for $options->{'stream_id'}. Meta-playlist contents:\n" . $meta_playlist;
		last;
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
	# 2) compactification.
	my @segment_urls = ();
	my $playlist_fh;
	$playlist_file = $options->{'data_dir'} . "/index-dvr-$vid.m3u8";
	mkdir($options->{'data_dir'} . "/twitch-vod-$vid");
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
	my $playlist_finished = 0;
	my @muted = ();
	my $dump_current_ts = sub() {
		if ($current_ts) {
			# Check if the previously collected segment is muted
			if ($current_ts =~ m/-muted/) {
				if ((scalar(@muted) > 0) && ($muted[scalar(@muted) - 1]->[1] == $dt_sum_total)) {
					$muted[scalar(@muted) - 1]->[1] = $dt_sum_total + $dt_sum;
				}
				else {
					push @muted, [$dt_sum_total, $dt_sum_total + $dt_sum];
				}
			}
			# Dump the previously collected segment
			my $segment_file = $current_ts;
			printf $playlist_fh "#EXTINF:%.3f,\n", $dt_sum;
			my $suffix = '';
			if (defined($current_ts_start) && defined($current_ts_end)) {
				push @segment_urls, "$m3u$segment_file?start_offset=$current_ts_start&end_offset=$current_ts_end";
				if (!$options->{'ts_merge'}) {
					$suffix = "-$current_ts_start-$current_ts_end.ts";
				}
			}
			else {
				push @segment_urls, "$m3u$segment_file";
			}
			print $playlist_fh "twitch-vod-$vid/$segment_file$suffix\n";
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
			# TODO: Report only if within requested range
			push @warnings, "Stream contains a gap of $1 seconds at " . format_time($dt_sum_total + $dt_sum) . ".";
		}
		elsif ($ln =~ m/^([^.]+\.ts)(?:\?start_offset=(\d+)&end_offset=(\d+))?$/) {
			if (!$options->{'ts_merge'} || ($1 ne $current_ts)) {
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
			if ($ln =~ m/^\x23EXT-X-ENDLIST/) {
				$playlist_finished = 1;
			}
			print $playlist_fh "$ln\n";
		}
	}
	if (!$playlist_finished) {
		print $playlist_fh "#EXT-X-ENDLIST\n";
		push @warnings, "Playlist is not finished, force-finishing it\n";
	}
	close($playlist_fh);
	if (scalar(@muted) > 0) {
		push @warnings, "Muted segments are present:\n" . join("\n", map { format_time($_->[0]) . '-' . format_time($_->[1]) } @muted);
	}
	last if ($err);

	print colored("!!! WARNING: $_\n", 'bold yellow') foreach (@warnings);
	print "\n";
	if (scalar(@warnings) > 0) {
		my $fh;
		open($fh, '>', $file . '.info') or die $!;
		print $fh "!!! WARNING: $_\n" foreach (@warnings);
		close($fh);
	}

	my $seg_num = scalar(@segment_urls);
	my $seg_num_part = int($seg_num / $options->{'num_threads'});
	++$seg_num_part if ($seg_num % $options->{'num_threads'} != 0);
	print "Downloading segments: $seg_num\n" . ('.' x $seg_num);
	($xend, $yend) = Win32::Console::ANSI::Cursor();
	my @children = ();
	for (my $tid = 0; $tid < $options->{'num_threads'}; ++$tid) {
		my $pid = fork();
		if (!defined($pid)) {
			$err = "Failed to fork: $!";
			last;
		}
		elsif ($pid == 0) {
#print "[$tid] Child started.\n";
			# Child process: downloading the corresponding part of segments list
			my $start_idx = $seg_num_part * $tid;
			my $end_idx = $seg_num_part * ($tid + 1);
			$end_idx = $seg_num if ($end_idx > $seg_num);
			my $success = 0;
			for (my $i = $start_idx; $i < $end_idx; ++$i) {
				my $seg_url = $segment_urls[$i];
				my $seg_file = ($seg_url =~ s|^.*/([^/?]+)(?:\?start_offset=(\d+)&end_offset=(\d+))?$|$1|r);
				my ($seg_start, $seg_end) = ($2, $3);
				for (my $j = 0; $j <= $options->{'num_retries'}; ++$j) {
					my $ch;
					if ($j == 0) {
						$ch = '?';
					}
					elsif (($j >= 1) && ($j <= 8)) {
						$ch = ($j + 1);
					}
					else {
						$ch = chr($j - 9 + 65);
					}
					put_char($ch, $i, $seg_num, 'bold yellow');
					$res = http_request($seg_url);
					if (!$res->is_success) {
						if ($j == $options->{'num_retries'}) {
							$err = "[$tid] Failed to download segment $seg_file: " . $res->status_line;
							last;
						}
						else {
#print colored("[$tid] Segment file No.$i '$seg_file' download failed, retrying (" . ($j + 2) . "/" . $options->{'num_retries'} . ").\n", 'bold yellow');
							next;
						}
					}
#print "[$tid] Segment URL: $seg_url\nLength: " . $res->header('Content-Length') . "\n";
					my $seg_fh;
					my $suffix = ((!$options->{'ts_merge'} && defined($seg_start) && defined($seg_end)) ? "-$seg_start-$seg_end.ts" : '');
					my $seg_file = $options->{'data_dir'} . "/twitch-vod-$vid/$seg_file$suffix";
#print "[$tid] Saving file $seg_file\n";
					if (!open($seg_fh, '>', $seg_file)) {
						$err = "[$tid] Failed to open segment file $seg_file:\n$!";
						last;
					}
					binmode($seg_fh);
					print $seg_fh ${$res->content_ref};
					close($seg_fh);
					if ($res->header('Content-Length') && (-s $seg_file == $res->header('Content-Length'))) {
						$success = 1;
						last;
					}
					else {
						if ($j == $options->{'num_retries'}) {
							$err = "[$tid] Failed to save segment $seg_file: " . $!;
							last;
						}
						next;
					}
#print colored("[$tid] Segment file No.$i '$seg_file' download failed, retrying (" . ($j + 2) . "/" . $options->{'num_retries'} . ").\n", 'bold yellow');
				}
				if ($err) {
					put_char('X', $i, $seg_num, 'bold red');
					last;
				}
				put_char('#', $i, $seg_num, 'bold green');
#print colored("[$tid] Segment file No.$i '$seg_file' done.\n", 'bold green');
			}
			if ($err) {
				print STDERR colored("$err\n", 'bold red');
				exit(1);
			}
			else {
#print colored("[$tid] Finished.\n", 'bold green');
				exit(0);
			}
		}
		else {
			# Parent process: continue creating threads
			push @children, $pid;
#print "Child with PID $pid started.\n";
		}
	}
	if ($err) {
		kill 'KILL', @children;
		last;
	}
	while (($res = wait()) != -1) {
		my $retcode = ($? >> 8);
#print "wait returned $res, thread's exit code: $retcode\n";
		if ($retcode) {
#print "retcode\n";
			$err = "Some of the segments could not be downloaded, aborting.\n";
#print "err\n";
			kill 'TERM', @children;
#print "kill\n";
			last;
		}
		else {
#print "not retcode\n";
		}
	}
	print "\n";
	last if ($err);

	# Finally, launch ffmpeg to do the rest of work
	if (system($options->{'ffmpeg_exe'} . ' -y -i ' . $playlist_file . ' -c copy -bsf:a aac_adtstoasc "' . $file . '"') != 0) {
		print STDERR colored("Error: Failed to build MP4. Segment files are not removed.\n", 'bold red');
		exit 2;
	}
}} while (0);

# Some cleanup
unlink($playlist_file);
remove_tree($options->{'data_dir'} . "/twitch-vod-$vid");
# FIXME: Clean up segment files

if ($err) {
	print STDERR colored("Error: $err\n", 'bold red');
	exit 2;
}
