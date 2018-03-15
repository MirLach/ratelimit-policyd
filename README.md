# ratelimit-policyd

A Sender rate limit policy daemon for Postfix.

Original Copyright (c) Onlime Webhosting (http://www.onlime.ch)

Modified by Mathieu Pellegrin for WellHosted (http://www.wellhosted.ch)

Modified by Miroslav Lachman to FreeBSD ports. (2018)

## Credits

Forked from onlime/ratelimit-policyd and modified to ensure that only authenticated users are counted for quota. All credits go to Simone Caruso for his original work (bejelith/send_rate_policyd).

This project was forked and modified for inclusion in FreeBSD ports tree. Dropped dependency on Switch.pm, added use strict and warnings, separate config file, rc script for automatic start on system boot.

## Purpose

This small Perl daemon **limits the number of emails** sent by users through your Postfix server, and store message quota in a RDMS system (MySQL). It counts the number of recipients for each sent email. You can setup a send rate per user or sender domain (via SASL username) on **daily/weekly/monthly** basis.

**The program uses the Postfix policy delegation protocol to control access to the mail system before a message has been accepted (please visit [SMTPD_POLICY_README.html](http://www.postfix.org/SMTPD_POLICY_README.html) for more information).**

For a long time we were using Postfix-Policyd v1 (the old 1.82) in production instead, but that project was no longer maintained and the successor [PolicyD v2 (codename "cluebringer")](http://wiki.policyd.org/) got overly complex and badly documented. Also, PolicyD seems to have been abandoned since 2013.

ratelimit-policyd will never be as feature-rich as other policy daemons. Its main purpose is to limit the number of emails per account, nothing more and nothing less. We focus on performance and simplicity.

**This daemon caches the quota in memory, so you don't need to worry about I/O operations!**

## New Features

The original forked code from [bejelith/send_rate_policyd](https://github.com/bejelith/send_rate_policyd) was improved with the following new features:

- automatically inserts new SASL-users (upon first email sent)
- Debian default init.d startscript
- added installer and documentation
- bugfix: weekly mode did not work (expiry date was not correctly calculated)
- bugfix: counters did not get reset after expiry
- additional information in DB: updated timestamp
- added view_ratelimit in DB to make Unix timestamps human readable (default datetime format)
- syslog messaging (similar to Postfix-policyd) including all relevant information and counter/quota
- more detailed logging
- added logrotation script for /var/log/ratelimit-policyd.log
- added flag in ratelimit DB table to make specific quotas persistent (all others will get reset to default after expiry)
- continue raising counter even in over quota state

The script from Onlime Webhosting was modified to :
 - Support smtpd_sender_restrictions (triggerd only on successful SASL login) instead of smtpd_data_restrictions (triggered when processing any outgoing mail)
 - As a consequence, the script is neutral for ISPConfig auto reply, auto forward, and any mail sent by Postfix without authentication (it will not count +1 on the quota for system mails, as long as your $mynetworks is configured accordingly)

## My Modifications

The script from Mathieu Pellegrin (WellHosted) was modified to :
 - **removed dependency on Switch**
 - **modified to use strict and warnings**
 - **modified shebang line to FreeBSD's `#!/usr/local/bin/perl`**
 - renamed from `daemon.pl` to `ratelimit-policyd.pl`
 - **use separate file for configuration variables `/usr/local/etc/ratelimit-policyd.cfg` (script can be updated without overwriting user modified settings)**
 - **created `rc.d/ratelimit-policyd` for FreeBSD**

## Installation

Recommended installation:

```bash
$ pkg install ratelimit-policyd
```

Create the DB schema and user:

```bash
$ mysql -u root -p < mysql-schema.sql
```

```sql
GRANT USAGE ON *.* TO policyd@'localhost' IDENTIFIED BY '********';
GRANT SELECT, INSERT, UPDATE, DELETE ON policyd.* TO policyd@'localhost';
```

Adjust configuration options in ```/usr/local/etc/ratelimit-policyd.cfg```:

```perl
## configuration must by valid Perl code, variables started with "our"
our @allowedhosts    = ('127.0.0.1', '10.0.0.1');
our $LOGFILE         = "/var/log/ratelimit-policyd.log";
our $PIDFILE         = "/var/run/ratelimit-policyd/ratelimit-policyd.pid";
our $SYSLOG_IDENT    = "ratelimit-policyd";
our $SYSLOG_LOGOPT   = "ndelay,pid";
our $SYSLOG_FACILITY = LOG_MAIL;
#chomp( my $vhost_dir = `pwd`);
our $port            = 10032;
our $listen_address  = '127.0.0.1'; # or '0.0.0.0'
our $s_key_type      = 'email'; # domain or email
our $dsn             = "DBI:mysql:sys_mail:localhost";
our $db_user         = 'sys_mail_ratelimit';
our $db_passwd       = '************';
our $db_table        = 'ratelimit';
our $db_quotacol     = 'quota';
our $db_tallycol     = 'used';
our $db_updatedcol   = 'updated';
our $db_expirycol    = 'expiry';
our $db_wherecol     = 'sender';
our $db_persistcol   = 'persist';

our $deltaconf       = 'daily'; # hourly|daily|weekly|monthly
our $defaultquota    = 100;

our $sql_getquota    = "SELECT $db_quotacol, $db_tallycol, $db_expirycol, $db_persistcol FROM $db_table WHERE $db_wherecol = ? AND $db_quotacol > 0";
our $sql_updatequota = "UPDATE $db_table SET $db_tallycol = $db_tallycol + ?, $db_updatedcol = NOW(), $db_expirycol = ? WHERE $db_wherecol = ?";
our $sql_updatereset = "UPDATE $db_table SET $db_quotacol = ?, $db_tallycol = ?, $db_updatedcol = NOW(), $db_expirycol = ? WHERE $db_wherecol = ?";
our $sql_insertquota = "INSERT INTO $db_table ($db_wherecol, $db_quotacol, $db_tallycol, $db_expirycol) VALUES (?, ?, ?, ?)";

our $thread_count = 3;
our $min_threads = 2;

1;
```

**Take care of using a port higher than 1024 to run the script as non-root (our init script runs it as user "postfix").**

In most cases, the default configuration should be fine. Just don't forget to paste your DB password in ``$db_password``.

Now, start the daemon:

```bash
$ service ratelimit-policyd start
```

## Testing

Check if the daemon is really running:

```bash
$ netstat -an | egrep '\.10032.*LISTEN'
tcp4       0      0 127.0.0.1.10032  *.*                    LISTEN


$ cat /var/run/ratelimit-policyd/ratelimit-policyd.pid
98518

$ ps auxw | grep ratelimit-policyd
mailnull 98517   0.0  0.0   14504   2040  -  Is    6:04PM      0:00.00 daemon: /usr/local/bin/ratelimit-policyd.pl[98518] (daemon)
mailnull 98518   0.0  0.4   96956  21960  -  Is    6:04PM      0:01.24 /usr/local/bin/ratelimit-policyd.pl (perl)

$ ps auxwH | grep ratelimit-policyd
mailnull 98517  0.0  0.0   14504   2040  -  Is    6:04PM     0:00.00 daemon: /usr/local/bin/ratelimit-policyd.pl[98518] (daemon)
mailnull 98518  0.0  0.4   96956  21960  -  Is    6:04PM     0:00.00 /usr/local/bin/ratelimit-policyd.pl (perl)
mailnull 98518  0.0  0.4   96956  21960  -  Ss    6:04PM     0:01.24 /usr/local/bin/ratelimit-policyd.pl (perl)
mailnull 98518  0.0  0.4   96956  21960  -  Is    6:04PM     0:00.00 /usr/local/bin/ratelimit-policyd.pl (perl)
mailnull 98518  0.0  0.4   96956  21960  -  Is    6:04PM     0:00.00 /usr/local/bin/ratelimit-policyd.pl (perl)

```

Print the cache content (in shared memory) with update statistics:

```bash
$ service ratelimit-policyd stats
Printing shm:
Domain          :       Quota   :       Used    :       Expire
Threads running: 1, Threads waiting: 2
```

Or call directly `/usr/local/bin/ratelimit-policyd.pl printshm`
Or network connection `echo 'printshm' | nc -N -w 5 localhost 10032`

## Postfix Configuration

Modify the postfix data restriction class ```smtpd_sender_restrictions``` like the following, ```/etc/postfix/main.cf```:

```
smtpd_sender_restrictions = check_policy_service inet:$IP:$PORT
```

sample configuration (chained with classic SASL authentication from MySQL):

```
smtpd_sender_restrictions = check_sender_access mysql:/etc/postfix/clients.cf, check_policy_service inet:127.0.0.1:10032
```

If you're sure that ratelimit-policyd is really running, restart Postfix:

```
$ service postfix restart
```

## Logging

Detailed logging is written to ``/var/log/ratelimit-policyd.log```. In addition, the most important information including the counter status is written to syslog:

```
$ tail -f /var/log/ratelimit-policyd.log 
Sat Jan 10 12:08:37 2015 Looking for demo@example.com
Sat Jan 10 12:08:37 2015 07F452AC009F: client=4-3.2-1.cust.example.com[1.2.3.4], sasl_method=PLAIN, sasl_username=demo@example.com, recipient_count=1, curr_count=6/1000, status=UPDATE

$ grep ratelimit-policyd /var/log/syslog
Jan 10 12:08:37 mx1 ratelimit-policyd[2552]: 07F452AC009F: client=4-3.2-1.cust.example.com[1.2.3.4], sasl_method=PLAIN, sasl_username=demo@example.com, recipient_count=1, curr_count=6/1000, status=UPDATE
```
