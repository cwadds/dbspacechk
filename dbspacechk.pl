#!/usr/bin/perl
#
# Copyright (C) 2019 Conrad Wadds - All Rights Reserved
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
 
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

# Retrieve the config
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

# Timestamp for csv report
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
    # NB: This will always work because we are treating the date
    # as just a number, so (20190101 - 1), even though not a date
    # will still work with the '<' operator
    $stat_date = $curr_date - 1;
}

# If we are the first run after midnight (IE: a date change)
if ( $stat_date < $curr_date ) {
    # Send an "I'm alive" email
    $mail_subject = "DBSpace Checker for $host is alive";
    $mail_message = $mail_subject;
    &send_email;

    if ( $sunday ) {
        # Call the subroutine to send out the 
        # weekly email of all the CSV records
        &email_csv;
    }

    # Update the stat file with the current date
    open  STAT, '>', $statfile;
    print STAT $curr_date;
    close STAT;
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

# Open an FD to a scalar in memory to have the log report available
open(LOG, '>', \$logtext) or die "Can't open LOG file: $!\n";
 
# Create a temporary sql file which will be removed when we finish
# and write the SQL into it.
my ($SQL, $sqlname) = tempfile( UNLINK => 1, SUFFIX => '.sql')
    or die "cannot create temp sql file: $?\n";

print $SQL $sql;
close $SQL;

# Create the shell script to run the SQL
my $script = &write_script;

# And gather the output into the @gulp array
@gulp = `$script`;

# Loop over the output of the SQL command
while ( @gulp ) {
    $_ = shift @gulp;

    # Tidy up the input, getting rid of newlines,
    # leading and trailing spaces and empty lines;
    chomp;
    s/\s*$//;
    s/^\ *//;
    next if /^$/;

    # Each dbspace block is bounded with the text 'START' and 'END'
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

            # Retrieve all required values from the hash
            $name = $l{'name'};
            $size = $l{'size'};
            $free = $l{'free'};

            # Calculate some variables
            $used = $size - $free;
            $pctu = ($used / $size) * 100;

            # Retrieve the warning limit from the config array
            $limit = $config{'DBSPACES'}{$name};

            # If the percentage used is over the limit
            if ( $pctu > $limit ) {
                # Increment the exceeded flag
                $exceeded++;
                # And set the error flag to an asterisk
                $error = "*";
            } else {
                # Clear out the error flag
                $error = "";
            }

            # Reinitialise the %l hash
            %l = ();
         
            # Write out the logfile
            write LOG;

            # And the CSV file
            print CSV "$timestamp\,$name\,$size\,$free\,$used\,$pctu\,$limit\n";
        } else {
            # We are inside the dbspace block
            # Split the line into key/value pairs
            my ($key, $val) = split;

            # And push them into the hash
            $l{$key} = $val;
        }
    }
}

# Close the opened file handles
close LOG;
close CSV;

# Output the log report to the log file
print LOGFILE $logtext;
close LOGFILE;

# If one of the dbspaces has exceeded the limits set in the ini file, 
# then we need to send off an email
if ( $exceeded > 0 ) {
    # Set up the variable portions of the email
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

# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
# End of main program code
# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =

# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
# Log report format
# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
format LOG_TOP =
  DBSpace Name            Size MB     Free MB    Used MB   Percent     Limit
  -------------------  ----------  ---------- ---------- --------- ---------
.
 
format LOG =
@ @<<<<<<<<<<<<<<<<<<  @>>>>>>>>>  @>>>>>>>>> @>>>>>>>>> @####.##% @####.##%
$error, $name,         $size,      $free,     $used,     $pctu,    $limit
.

# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
# Subroutines
# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =

# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
# This subroutine reads the configuration ini file into the config hash
# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
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

# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
# This funtion will send an email to the recipients listed in the ini file
# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
sub send_email {
    my $html = '';

    # Create a new eMail sending object
    $msg = MIME::Lite->new;

    # If the ini files contains smtp: host, user and password
    if ( $mail_host and $mail_user and $mail_pass ) {
        MIME::Lite->send('smtp', $mail_host, Timeout=>60,
                          AuthUser=>$mail_user, AuthPass=>$mail_pass);
    # Else if we just have a mail host
    } elsif ( $mail_host ) {
        MIME::Lite->send('smtp', $mail_host, Timeout=>60);
    }

    # If we are sending an email with attachments
    if ($mail_attach and $mail_attname) {
        # Set the mail type
        $mail_type = 'multipart/mixed';
        # Build the email object
        $msg->build( From     => $mail_from,
                     To       => $mail_to,
                     Cc       => $mail_cc,
                     Subject  => $mail_subject,
                     Type     => $mail_type
                     );

        # Add the textual message.
        $msg->attach(Type        => 'TEXT/HTML',
                     Data        => $mail_message,
                     Disposition => 'inline'
                     );

        # Specify the file as attachement.
        $msg->attach(Type        => 'TEXT/HTML',
                     Path        => $mail_attach,
                     Filename    => $mail_attname,
                     Disposition => 'attachment'
                     );       
    } else { # We are sending an email withOUT attachments
        # Set the correct mail type
        $mail_type = 'text/plain';
        # And build the mail object
        $msg->build( From     => $mail_from,
                     To       => $mail_to,
                     Cc       => $mail_cc,
                     Subject  => $mail_subject,
                     Type     => $mail_type,
                     Data     => [qq($mail_message\n),
                                  qq($logtext)]
                     );

        # Repeat the process to create an HTML part 
        $html = $msg->attach(Type => 'multipart/related');
        # And attach it to our mail object
        # formsattig the output to give a prettier email body
        $html->attach(Type => 'text/html',
                      Data => [qq(<h2>$mail_message</h2>\n),
                               qq(<hr>\n<pre>\n),
                               qq($logtext),
                               qq(</pre>)]);
    }

    # Send it off
    $msg->send;
}

# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
# This subroutine creates the script file to be executed
# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
sub write_script {
    # Create a temporary file
    my ($SCRIPT, $scriptfile) = tempfile( UNLINK => 1, SUFFIX => '.sh')
        or die "cannot create temp script file: $?\n";

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

# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
# This subroutine emails the accumulated data in the CSV file and clears it out
# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
sub email_csv {
    # Setup the email and detail file to be attached
    $mail_subject  = "DBSpace CSV file from $host";
    $mail_message  = "The attached CSV file contains all of the results of\n";
    $mail_message .= "the $0 script for the last week.\n";
    $mail_attach   = $csvfile;
    $mail_attname  = "$basename.csv";

    # Send it
    &send_email;

    # And clear out the CSV file to start a new week
    open  CSV, '>', $csvfile;
    close CSV;
}

# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =
# perldoc
# = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = = =

=head1 NAME

dbspacechk.pl - A script to monitor Informix database dbspaces.

=head1 SYNOPSIS

Call this script from cron on a regular basis to 
check the sizes and generate the csv file

    */5 * * * * /opt/informix/dbspacechk/dbspacechk.pl > /tmp/dbspacechk.log 2>&1

=head1 DESCRIPTION

This Perl script and associated ini file can be used to monitor dbspace usage in an Informix database.

=head2 The INI File

=over 12


=item [ENV] - The environment section

All of the data in this section will be added to the shell script as exports, and then runs the generated SQL command.
Each element will generate the following:

    export LH_Value=RH_Value

The intention is to ensure that a sane Informix environment is available.

=item [EMAIL] - The eMail section

This section contains email B<send to>,  B<send from> and B<cc> data. It can also optionally contain an SMTP B<server name> and a B<username> and B<password> pair. These will be used to connect to an SMTP server which requires authentication.

=item [DBSPACES] - List of dbspaces to report

This section contains pairs of dbspaces and the warning limit.

=back

=head1 VERSION

2.1.1

=head1 LICENSE

This is released under the 
GNU General Public License v3.0
see <https://www.gnu.org/licenses/>

=head1 AUTHOR

Conrad Wadds - cwadds <at> wadds <dot> net <dot> au

=cut
