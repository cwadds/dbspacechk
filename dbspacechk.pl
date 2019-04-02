#!/usr/bin/perl
#
# (c) Conrad Wadds<conrad@wadds.net.au> - 2019-03-27
 
use warnings;
use strict;
use POSIX;
use File::Temp qw/ tempfile tempdir /;
use MIME::Lite;
use MIME::Base64;
use Authen::SASL;
use File::Basename;
use Sys::Hostname;

my $mydir = dirname(__FILE__);
my $host = hostname();
 
# Tidy up filename
$0 =~ s#^.*/|\\##;

my $basename = $0;
   $basename =~ s/.pl//;
my $conffile = "$mydir/$basename.ini";

my %config = &read_conf;

# Log directory and filenames
my $logdir   = $config{'ENV'}{'LOGDIR'};
   $logdir   = '/var/log/informix' unless $logdir;
my $logfile  = "$logdir/$basename.log";
my $csvfile  = "$logdir/$basename.csv";
my $statfile = "$logdir/$basename.stat";
my $logtext  = '';

# Mail variables
my $msg          = '';
my $mail_from    = $config{'EMAIL'}{'MAILFROM'};
my $mail_to      = $config{'EMAIL'}{'MAILTO'};
my $mail_cc      = $config{'EMAIL'}{'MAILCC'};
my $mail_host    = $config{'EMAIL'}{'SMTPHOST'};
my $mail_user    = $config{'EMAIL'}{'SMTPUSER'};
my $mail_pass    = $config{'EMAIL'}{'SMTPPASS'};
my $mail_type    = '';
my $mail_subject = '';
my $mail_message = '';
my $mail_attach  = '';
my $mail_attname = '';

# many, many variables...
my $cmd   = '';
my $name  = '';
my $used  = 0;
my $size  = 0;
my $free  = 0;
my $pctu  = 0;
my @gulp  = ();
my $junk  = '';
my $limit = 0;
my $start = 0;
my $error = '';
my %l     = ();
my $hashref = '';
my $exceeded = 0;
my $stat_date = '';

# Timestamp for csv report and "is it Sunday" variable
my $timestamp = POSIX::strftime("%Y/%m/%d %H:%M:%S", localtime);
# Timestamp to go in the stat file
my $curr_date = POSIX::strftime("%Y%m%d", localtime);
# Sunday is day 0, which evaluates to false, so invert the result
my $sunday = POSIX::strftime("%w", localtime) ? 0 : 1;

# Retrieve the last status date from the stat file
if ( open(STAT, "< $statfile")) {
    $stat_date = <STAT>;
    close STAT;
} else {
    # If the file doesn't exist, set the status date to "yesterday"
    # # NB: This will always work because we are treating the date
    # as just a number, so (20190101 - 1), even though not a date
    # will still work with the '<' operator
    $stat_date = $curr_date - 1;
}

# If we are the first run after midnight (IE: a date change)
if ( $stat_date < $curr_date ) {
    # Send an "I'm alive" email
    $mail_subject = "DBSpace Checker for $host is alive";
    $mail_message = "DBSpace Checker is alive";
    &send_email;

    if ( $sunday ) {
        # Call the subroutine to send out the 
        # weekly email of all the CSV records
        &email_csv;
    }

    # Update the stat file
    open my $stat, '>', $statfile;
    print $stat $curr_date;
    close $stat;
}

# Copy the DBSPACES hashref
$hashref = $config{'DBSPACES'};

# Assemble the list of dbspaces to report
foreach my $i ( sort keys %$hashref ) {
    $junk .= "$i ";
}
my $dbspaces = join('", "', split(/\s+/, $junk));
 
# Create the SQL
my $sql = qq(SELECT "START" start,
       s.name name,
       round(((sum(c.chksize*s.pagesize))/1024/1024)) size,
       round(((sum(c.nfree*s.pagesize))/1024/1024)) free,
       "END" end
FROM syschunks c,
     sysdbspaces s
WHERE c.dbsnum = s.dbsnum
  AND s.name IN ("$dbspaces")
GROUP BY s.name);

# Open output files
open(LOGFILE, ">  $logfile") or die "cannot open LOGFILE: $logfile $?\n";
open(CSV,     ">> $csvfile") or die "cannot open CSV: $csvfile $?\n";

# Open a FD to a scalar in memory to have the log report available
open(LOG, '>', \$logtext) or die "Can't open LOG file: $!\n";
 
# Create a temporary sql file which will be removed when we finish
# and write the SQL into it.
my ($SQL, $sqlname) = tempfile( UNLINK => 1, SUFFIX => '.sql') or die "cannot create temp file: $?\n";

print $SQL $sql;
close $SQL;

# Create the shell script to run the SQL
my $script = &write_script;

# And gather the output into the @gulp array
@gulp = `$script`;

# Read the output of the SQL command
while ( @gulp ) {
    $_ = shift @gulp;

    # Tidy up the output, getting rid of newlines,
    # leading and trailing spaces and empty lines;
    chomp;
    s/\s*$//;
    s/^\ *//;
    next if /^$/;

    # Each dbspace block is bounded with START and END
    if ( $start == 0 ) {
        # We found the start of a block
        $start = 1 if /START/;
        next;
    } else {
        # We found the end of a block
        # so we have all of the variables required
        if ( /END/ ) {
            # Reset the block indicator
            $start = 0;

            # Retrieve all required values
            # from the hash
            $name = $l{'name'};
            $size = $l{'size'};
            $free = $l{'free'};

            # Calculate some variables
            $used = $size - $free;
            $pctu = ($used / $size) * 100;

            # Retrieve the warning limit from the config array
            $limit = $config{'DBSPACES'}{$name};

            # Increment the exceeded flag if the size is over limit
            if ( $pctu > $limit ) {
                $exceeded++;
                $error = "*";
            } else {
                $error = "";
            }
         
            # Write out the logfile
            write LOG;

            # And the CSV file
            print CSV "$timestamp\,$name\,$size\,$free\,$used\,$pctu\,$limit\n";
        } else {
            # Inside the dbspace block
            # Split the line into key/value pairs
            my ($key, $val) = split;

            # And push them into the hash
            $l{$key} = $val;
        }
    }
}

# Close the opened files
close LOG;
close CSV;

print LOGFILE $logtext;
close LOGFILE;

# If we need to send off an email
if ( $exceeded > 0 ) {
    # Set up the variable portions
    $mail_subject = "DBSpace Checker for $host";
    $mail_message = "WARNING: One or more dbspaces has exceeded the set limit";
    $mail_attach  = '';
    $mail_attname = '';

    # And call the send email subroutine
    &send_email;
}

# Display the logfile report
# Useful if run from the command line
print $logtext;

# End of program

# These next few lines define the output format of the logfile for the write command
format LOG_TOP =
  DBSpace Name            Size MB     Free MB    Used MB   Percent     Limit
  -------------------  ----------  ---------- ---------- --------- ---------
.
 
format LOG =
@ @<<<<<<<<<<<<<<<<<<  @>>>>>>>>>  @>>>>>>>>> @>>>>>>>>> @####.##% @####.##%
$error, $name,         $size,      $free,     $used,     $pctu,    $limit
.

# Subroutines

# This subroutine reads the configuration ini file into the config hash
sub read_conf {
    # Set up some local variables
    my %config;
    my $section = '';
    local $_;

    # Open the ini file
    open CONF, "< $conffile" or die "cannot open config file: $?\n";
    # And iterate over its contents
    foreach $_ (<CONF>) {
        chomp;                  # Remove EOL characters
        s/\s+$//;               # Remove trailing spaces
        s/^\s+//;               # Remove leading spaces
        next if (/^$/);         # Ignore blank lines
        next if (/^\s*[#;]/);   # Ignore comment lines

        # New [section]
        if ( m/^\[(.*)\]/ ) {
            $section = uc($1);
            $section =~ s/\s+$//;
            $section =~ s/^\s+//;
            next;
        }

        # Extract key/value pairs
        my ($key, $val) = split /=/;
        $key =~ s/\s+$//;
        $key =~ s/^\s+//;
        $val =~ s/\s+$//;
        $val =~ s/^\s+//;

        # And add them to the config hash, including the section header
        $config{$section}{$key} = $val;
    }

    # Return the contents of the config hash
    return %config;
}

# This funtion does the actual sendding of the email
sub send_email {
    my $html = '';
    $msg = MIME::Lite->new;

    if ( $mail_host and $mail_user and $mail_pass ) {
        MIME::Lite->send('smtp', $mail_host, Timeout=>60,
                          AuthUser=>$mail_user, AuthPass=>$mail_pass);
    } elsif ( $mail_host ) {
        MIME::Lite->send('smtp', $mail_host, Timeout=>60);
    }

    if ($mail_attach and $mail_attname) {
        $mail_type = 'multipart/mixed';
        $msg->build( From     => $mail_from,
                     To       => $mail_to,
                     Cc       => $mail_cc,
                     Subject  => $mail_subject,
                     Type     => $mail_type
                     );

        # Add your text message.
        $msg->attach(Type        => 'TEXT/HTML',
                     Data        => $mail_message,
                     Disposition => 'inline'
                     );

        # Specify your file as attachement.
        if ($mail_attach and $mail_attname) {
            $msg->attach(Type        => 'TEXT/HTML',
                         Path        => $mail_attach,
                         Filename    => $mail_attname,
                         Disposition => 'attachment'
                         );       
        }
    } else {
        $mail_type = 'text/plain';
        $msg->build( From     => $mail_from,
                     To       => $mail_to,
                     Cc       => $mail_cc,
                     Subject  => $mail_subject,
                     Type     => $mail_type,
                     Data     => [qq($mail_message\n),
                                  qq($logtext)]
                     );

        $html = $msg->attach(Type => 'multipart/related');
        $html->attach(Type => 'text/html',
                      Data => [qq(<h2>$mail_message</h2>\n),
                               qq(<hr>\n<pre>\n),
                               qq($logtext),
                               qq(</pre>)]);

    }

    $msg->send;
}

# This subroutine creates the script file to be executed
sub write_script {
    # Create a temporary file
    my ($SCRIPT, $scriptfile) = tempfile( UNLINK => 1, SUFFIX => '.sh') or die "cannot create temp script file: $?\n";

    # Copy the ENV hashref
    $hashref = $config{'ENV'};

    # Gather all of the keys from the config hash from the ENV section
    foreach my $i (sort keys %$hashref ) {
        # Except the path variable (if it's there)
        next if ( $i eq 'PATH' );
        # Create lines which look like: export MYVAR=value
        print $SCRIPT "export $i=$config{'ENV'}{$i}\n";
    }
    # Then add the PATH export, just adding the Informix bin directory
    my $path = $ENV{'PATH'};
    print $SCRIPT "export PATH=$path:$config{'ENV'}{'INFORMIXDIR'}/bin\n";
    print $SCRIPT "\n";
    # Run dbaccess over the SQL script on the sysmaster database
    print $SCRIPT "dbaccess sysmaster $sqlname 2>/dev/null";
    close $SCRIPT;

    # Make it executable
    chmod 0700, $scriptfile;

    # Return the name of the scriptfile
    return $scriptfile;
}

sub email_csv {
    # Time to send the email
    $mail_subject  = "DBSpace CSV file from $host";
    $mail_message  = "The attached CSV file contains all of the results of\n";
    $mail_message .= "the $0 script for the last week.\n";
    $mail_attach   = $csvfile;
    $mail_attname  = "$basename.csv";

    # Send it
    &send_email;

    # And clear out the CSV file to start a new week
    open my $CSV, '>', $csvfile;
    close $CSV;
}
