# ratelimit-policyd

A Sender rate limit policy daemon for Postfix.

Original Copyright (c) Onlime Webhosting (http://www.onlime.ch)

Modified by Mathieu Pellegrin for WellHosted (http://www.wellhosted.ch)

## Credits

This project was forked from onlime/ratelimit-policyd and modified to ensure that only authenticated users are counted for quota. All credits go to Simone Caruso for his original work (bejelith/send_rate_policyd).

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

## Installation

Recommended installation:

```bash
$ cd /opt/
$ git clone https://github.com/onlime/ratelimit-policyd.git ratelimit-policyd
$ cd ratelimit-policyd
$ chmod +x install.sh
$ ./install.sh
```

Create the DB schema and user:

```bash
$ mysql -u root -p < mysql-schema.sql
```

```sql
GRANT USAGE ON *.* TO policyd@'localhost' IDENTIFIED BY '********';
GRANT SELECT, INSERT, UPDATE, DELETE ON policyd.* TO policyd@'localhost';
```

Adjust configuration options in ```daemon.pl```:

```perl
### CONFIGURATION SECTION
my @allowedhosts    = ('127.0.0.1', '10.0.0.1');
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
my $deltaconf       = 'daily'; # hourly|daily|weekly|monthly
my $defaultquota    = 1000;
my $sql_getquota    = "SELECT $db_quotacol, $db_tallycol, $db_expirycol FROM $db_table WHERE $db_wherecol = ? AND $db_quotacol > 0";
my $sql_updatequota = "UPDATE $db_table SET $db_tallycol = $db_tallycol + ?, $db_updatedcol = NOW(), $db_expirycol = ? WHERE $db_wherecol = ?";
my $sql_updatereset = "UPDATE $db_table SET $db_tallycol = ?, $db_updatedcol = NOW(), $db_expirycol = ? WHERE $db_wherecol = ?";
my $sql_insertquota = "INSERT INTO $db_table ($db_wherecol, $db_quotacol, $db_tallycol, $db_expirycol) VALUES (?, ?, ?, ?)";
### END OF CONFIGURATION SECTION
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
$ netstat -tl | grep 10032
tcp        0      0 localhost.localdo:10032 *:*                     LISTEN

$ cat /var/run/ratelimit-policyd.pid
30566

$ ps aux | grep daemon.pl
postfix  30566  0.4  0.1 176264 19304 ?        Ssl  14:37   0:00 /opt/send_rate_policyd/daemon.pl

$ pstree -p | grep ratelimit
init(1)-+-/opt/ratelimit-(11298)-+-{/opt/ratelimit-}(11300)
        |                        |-{/opt/ratelimit-}(11301)
        |                        |-{/opt/ratelimit-}(11302)
        |                        |-{/opt/ratelimit-}(14834)
        |                        |-{/opt/ratelimit-}(15001)
        |                        |-{/opt/ratelimit-}(15027)
        |                        |-{/opt/ratelimit-}(15058)
        |                        `-{/opt/ratelimit-}(15065)

```

Print the cache content (in shared memory) with update statistics:

```bash
$ service ratelimit-policyd status
Printing shm:
Domain		:	Quota	:	Used	:	Expire
Threads running: 6, Threads waiting: 2
```

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
