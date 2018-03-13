#!/usr/bin/perl
use Socket;
use POSIX ;
use DBI;
use Sys::Syslog;
use threads;
use threads::shared;
use Thread::Semaphore; 
use File::Basename;
my $semaphore = new Thread::Semaphore;

### CONFIGURATION SECTION
my @allowedhosts    = ('127.0.0.1');
my $LOGFILE         = "/var/log/ratelimit-policyd.log";
my $PIDFILE         = "/var/run/ratelimit-policyd.pid";
my $SYSLOG_IDENT    = "ratelimit-policyd";
my $SYSLOG_LOGOPT   = "ndelay,pid";
my $SYSLOG_FACILITY = LOG_MAIL;
chomp( my $vhost_dir = `pwd`);
my $port            = 10032;
my $listen_address  = '127.0.0.1'; # or '0.0.0.0'
my $s_key_type      = 'email'; # domain or email
my $dsn             = "DBI:mysql:policyd:127.0.0.1";
my $db_user         = 'policyd';
my $db_passwd       = '************';
my $db_table        = 'ratelimit';
my $db_quotacol     = 'quota';
my $db_tallycol     = 'used';
my $db_updatedcol   = 'updated';
my $db_expirycol    = 'expiry';
my $db_wherecol     = 'sender';
my $db_persistcol   = 'persist';
my $deltaconf       = 'daily'; # hourly|daily|weekly|monthly
my $defaultquota    = 300; # 300 recipients by day and by user, CC and CCI count as well
my $sql_getquota    = "SELECT $db_quotacol, $db_tallycol, $db_expirycol, $db_persistcol FROM $db_table WHERE $db_wherecol = ? AND $db_quotacol > 0";
my $sql_updatequota = "UPDATE $db_table SET $db_tallycol = $db_tallycol + ?, $db_updatedcol = NOW(), $db_expirycol = ? WHERE $db_wherecol = ?";
my $sql_updatereset = "UPDATE $db_table SET $db_quotacol = ?, $db_tallycol = ?, $db_updatedcol = NOW(), $db_expirycol = ? WHERE $db_wherecol = ?";
my $sql_insertquota = "INSERT INTO $db_table ($db_wherecol, $db_quotacol, $db_tallycol, $db_expirycol) VALUES (?, ?, ?, ?)";
### END OF CONFIGURATION SECTION

$0=join(' ',($0,@ARGV));

if ($ARGV[0] eq "printshm") {
	my $out = `echo "printshm"|nc $listen_address $port`;
	print $out;
	exit(0);
}
my %quotahash :shared;
my %scoreboard :shared;
my $lock:shared;
my $cnt=0;
my $proto = getprotobyname('tcp');
my $thread_count = 3;
my $min_threads = 2;
# create a socket, make it reusable
socket(SERVER, PF_INET, SOCK_STREAM, $proto) or die "socket: $!";
setsockopt(SERVER, SOL_SOCKET, SO_REUSEADDR, 1) or die "setsock: $!";
my $paddr = sockaddr_in($port, inet_aton($listen_address)); #Server sockaddr_in
bind(SERVER, $paddr) or die "bind: $!";# bind to a port, then listen
listen(SERVER, SOMAXCONN) or die "listen: $!";

# initialize syslog
openlog($SYSLOG_IDENT, $SYSLOG_LOGOPT, $SYSLOG_FACILITY);

#&daemonize;
&prepare_log;

$SIG{TERM} = \&sigterm_handler;
$SIG{HUP} = \&print_cache;
while (1) {
	my $i = 0;
	my @threads;
	while($i < $thread_count) {
		#$threads[$i] = threads->new(\&start_thr)->detach();
		threads->new(\&start_thr);
		logger("Started thead num $i.");
		$i++;
	}
	while(1) {
		sleep 5;
		$cnt++;
		my $r = 0;
		my $w = 0;
		if ($cnt % 6 == 0) {
			lock($lock);
			&commit_cache;
			&flush_cache;
			logger("Master: cache committed and flushed");
		}
		while (my ($k, $v) = each(%scoreboard)) {
			if ($v eq 'running') {
				$r++;
			} else {
				$w++;
			}
		}
		if ($r/($r + $w) > 0.9) {
			threads->new(\&start_thr);
			logger("New thread started");
		}
		if ($cnt % 150 == 0) {
			logger("STATS: threads running: $r, threads waiting $w.");
		}
	}
}

exit;

sub start_thr {
	my $threadid = threads->tid();
	my $client_addr;
	my $client_ipnum;
	my $client_ip;
	my $client;
	while(1) {
		$scoreboard{$threadid} = 'waiting';
		$semaphore->down();#TODO move to non-block
		$client_addr = accept($client, SERVER);
		$semaphore->up();
		$scoreboard{$threadid} = 'running';
		if (!$client_addr) {
			logger("TID: $threadid accept() failed with: $!");
			next;
		}	
		my ($client_port, $client_ip) = unpack_sockaddr_in($client_addr);
		$client_ipnum = inet_ntoa($client_ip);
		logger("TID: $threadid accepted from $client_ipnum ...");
		
		select($client);
		$|=1;
	
		if (grep $_ eq $client_ipnum, @allowedhosts) {
			#my $client_host = gethostbyaddr($client_ip, AF_INET);
			#if (! defined ($client_host)) { $client_host=$client_ipnum;}
			my $message;
			my @buf;
			while(!eof($client)) {
				$message = <$client>;
				if ($message =~ m/printshm/) {
					my $r=0;
					my $w =0;
					print $client "Printing shm:\r\n";
					print $client "Domain\t\t:\tQuota\t:\tUsed\t:\tExpire\r\n";
					while(($k,$v) = each(%quotahash)) {
						chomp(my $exp = ctime($quotahash{$k}{'expire'}));
						print $client "$k\t:\t".$quotahash{$k}{'quota'}."\t:\t $quotahash{$k}{'tally'}\t:\t$exp\r\n";
					}
					while (my ($k, $v) = each(%scoreboard)) {
						if ($v eq 'running') {
							$r++;
						} else {
							$w++;
						}
					}
					print $client "Threads running: $r, Threads waiting: $w\r\n";
					last;
				} elsif ($message =~ m/=/) {
					push(@buf, $message);
					next;
				} elsif ($message == "\r\n") {
					#logger("Handle new request");
					my $ret = &handle_req(@buf);
					if ($ret =~ m/unknown/) {
						last;
					#New thread model - old code
					#	shutdown($client,2);
					#??	threads->exit(0);
					} else {
						print $client "action=$ret\n\n";
					}
					@buf = ();
				} else {
					print $client "message not understood\r\n";
				}
			}
		} else {
			logger("Client $client_ipnum connection not allowed.");
		}
		shutdown($client,2);
		undef $client;
		logger("TID: $threadid Client $client_ipnum disconnected.");
	}
	undef $scoreboard{$threadid};
	threads->exit(0);
}

sub handle_req {
	my @buf = @_;
	my $protocol_state;
	my $sasl_method;
	my $sasl_username; 
	my $recipient_count;
	my $queue_id;
	my $client_address;
	my $client_name;
	local $/ = "\n";
	foreach $aline(@buf) {
		my @line = split("=", $aline);
		chomp(@line);
		#logger("DEBUG ". $line[0] ."=". $line[1]);
		if ($line[0] eq "protocol_state") {
			chomp($protocol_state = $line[1]);
		} elsif ($line[0] eq "sasl_method") {
			chomp($sasl_method = $line[1]);
		} elsif ($line[0] eq "sasl_username") {
			chomp($sasl_username = $line[1]);
		} elsif ($line[0] eq "recipient_count") {
			chomp($recipient_count = $line[1]);
		} elsif ($line[0] eq "queue_id") {
			chomp($queue_id = $line[1]);
		} elsif ($line[0] eq "client_address") {
			chomp($client_address = $line[1]);
		} elsif ($line[0] eq "client_name") {
			chomp($client_name = $line[1]);
		}
	}

	if ($protocol_state !~ m/RCPT/ || $sasl_username eq "" ) {
		# It should not happen if check_policy is chained after proper authentication on smtpd_sender_restrictions
		logger("protocol_state=$protocol_state sasl_username=$sasl_username");
		return "dunno";
	} else {
		# One RCPT is triggered by outgoing address, including CC and CCI, no need to count
		$recipient_count = 1;
	}

	my $skey = '';
	if ($s_key_type eq 'domain') {
		$skey = (split("@", $sasl_username))[1];
	} else {
		$skey = $sasl_username;
	}

	my $syslogMsg;
	my $syslogMsgTpl = sprintf("%s: client=%s[%s], sasl_method=%s, sasl_username=%s, recipient_count=%s, curr_count=%%s/%%s, status=%%s",
	                           $queue_id, $client_name, $client_address, $sasl_method, $sasl_username, $recipient_count);

	#TODO: Maybe i should move to semaphore!!!
	lock($lock);
	if (!exists($quotahash{$skey})) {
		logger("Looking for $skey");
		my $dbh = get_db_handler()
			or return "dunno";;
		my $sql_query = $dbh->prepare($sql_getquota);
		$sql_query->execute($skey);
		if ($sql_query->rows > 0) {
			while(@row = $sql_query->fetchrow_array()) {
				$quotahash{$skey} = &share({});
				$quotahash{$skey}{'quota'}   = $row[0];
				$quotahash{$skey}{'tally'}   = $row[1];
				$quotahash{$skey}{'sum'}     = 0;
				$quotahash{$skey}{'expire'}  = $row[2];
				$quotahash{$skey}{'persist'} = $row[3];
				undef @row;
			}
			$sql_query->finish();
			$dbh->disconnect;
		} else {
			$sql_query->finish();
			my $expire = calcexpire($deltaconf);
			$sql_query = $dbh->prepare($sql_insertquota);
			logger("Inserting $skey, $defaultquota, $recipient_count, $expire");
			$sql_query->execute($skey, $defaultquota, $recipient_count, $expire)
				or logger("Query error: ". $sql_query->errstr);
			$sql_query->finish();
			$dbh->disconnect;
			$syslogMsg = sprintf($syslogMsgTpl, $recipient_count, $defaultquota, "INSERT");
			logger($syslogMsg);
			syslog(LOG_NOTICE, $syslogMsg);
			return "dunno";
		}
	}
	if ($quotahash{$skey}{'expire'} < time()) {
		lock($lock);
		$quotahash{$skey}{'sum'}    = 0;
		$quotahash{$skey}{'tally'}  = 0;
		$quotahash{$skey}{'expire'} = calcexpire($deltaconf);
		my $newQuota = ($quotahash{$skey}{'persist'}) ? $quotahash{$skey}{'quota'} : $defaultquota;
		my $dbh = get_db_handler()
			or return "dunno";;
		my $sql_query = $dbh->prepare($sql_updatereset);
		$sql_query->execute($newQuota, 0, $quotahash{$skey}{'expire'}, $skey)
			or logger("Query error: ". $sql_query->errstr);
	}
	$quotahash{$skey}{'tally'} += $recipient_count;
	$quotahash{$skey}{'sum'}   += $recipient_count;
	if ($quotahash{$skey}{'tally'} > $quotahash{$skey}{'quota'}) {
		$syslogMsg = sprintf($syslogMsgTpl, $quotahash{$skey}{'tally'}, $quotahash{$skey}{'quota'}, "OVER_QUOTA");
		logger($syslogMsg);
		syslog(LOG_WARNING, $syslogMsg);
		return "471 $deltaconf message quota exceeded"; 
	}
	$syslogMsg = sprintf($syslogMsgTpl, $quotahash{$skey}{'tally'}, $quotahash{$skey}{'quota'}, "UPDATE");
	logger($syslogMsg);
	syslog(LOG_INFO, $syslogMsg);
	return "dunno";
}

sub sigterm_handler {
	shutdown(SERVER,2);
	lock($lock);
	logger("SIGTERM received.\nFlushing cache...\nExiting.");
	&commit_cache;
	exit(0);
}

sub get_db_handler {
	my $dbh = DBI->connect($dsn, $db_user, $db_passwd, {PrintError => 0});
	if (!defined($dbh)) {
		my $syslogMsg = sprintf("DB connection error (%s): %s", $DBI::err, $DBI::errstr);
		logger($syslogMsg);
		syslog(LOG_ERR, $syslogMsg);
	}
	return $dbh;
}

sub commit_cache {
	my $dbh = get_db_handler()
		or return undef;
	my $sql_query = $dbh->prepare($sql_updatequota);
	#lock($lock); -- lock at upper level
	while(($k,$v) = each(%quotahash)) {
		$sql_query->execute($quotahash{$k}{'sum'}, $quotahash{$k}{'expire'}, $k)
			or logger("Query error:".$sql_query->errstr);
		$quotahash{$k}{'sum'} = 0;
	}
	$dbh->disconnect;
}

sub flush_cache {
	lock($lock);
	foreach $k(keys %quotahash) {
		delete $quotahash{$k};
	}
}

sub print_cache {
	foreach $k(keys %quotahash) {
        logger("$k: $quotahash{$k}{'quota'}, $quotahash{$k}{'tally'}");
    }
}

# use this instead of daemonize if you're running the script with your own 
# daemon starter (e.g. start-stop-daemon)
sub prepare_log {
	my ($i,$pid);
	my $mask = umask 0027;
	close STDIN;
	setsid();
	close STDOUT;
	open STDIN, "/dev/null";
	open LOG, ">>$LOGFILE" or die "Unable to open $LOGFILE: $!\n";
	select((select(LOG), $|=1)[0]);
	open STDERR, ">>$LOGFILE" or die "Unable to redirect STDERR to STDOUT: $!\n";
	umask $mask;
}

sub daemonize {
	my ($i,$pid);
	my $mask = umask 0027;
	print "SMTP Policy Daemon. Logging to $LOGFILE\n";
	#Should i delete this??
	#$ENV{PATH}="/bin:/usr/bin";
	#chdir("/");
	close STDIN;
	if (!defined(my $pid=fork())) {
		die "Impossible to fork\n";
	} elsif ($pid >0) {
		exit 0;
	}
	setsid();
	close STDOUT;
	open STDIN, "/dev/null";
	open LOG, ">>$LOGFILE" or die "Unable to open $LOGFILE: $!\n";
	select((select(LOG), $|=1)[0]);
	open STDERR, ">>$LOGFILE" or die "Unable to redirect STDERR to STDOUT: $!\n";
	open PID, ">$PIDFILE" or die $!;
	print PID $$."\n";
	close PID;
	umask $mask;
}

sub calcexpire {
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	my ($arg) = @_;
	if ($arg eq 'monthly') {
		$exp = mktime (0, 0, 0, 1, ++$mon, $year);
	} elsif ($arg eq 'weekly') {
		$exp = mktime (0, 0, 0, $mday+7-$wday, $mon, $year);
	} elsif ($arg eq 'daily') {
		$exp = mktime (0, 0, 0, ++$mday, $mon, $year);
	} elsif ($arg eq 'hourly') {
		$exp = mktime (0, $min, ++$hour, $mday, $mon, $year);
	} else {
		$exp = mktime (0, 0, 0, 1, ++$mon, $year);
	}
	return $exp;
}

sub logger {
	my ($arg) = @_;
	my $time = localtime();
	chomp($time);
	print LOG  "$time $arg\n";
}
