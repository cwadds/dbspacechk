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
my $lockfile = "$logdir/$basename.lck";

# Mail variables
my $msg          = '';
my $mail_from    = $config{'EMAIL'}{'MAILFROM'};
my $mail_to      = $config{'EMAIL'}{'MAILTO'};
my $mail_cc      = $config{'EMAIL'}{'MAILCC'};
my $mail_host    = $config{'EMAIL'}{'SMTPHOST'};
my $mail_user    = $config{'EMAIL'}{'SMTPUSER'};
my $mail_pass    = $config{'EMAIL'}{'SMTPPASS'};
my $mail_subject = "DBSpace Checker for $host";
my $mail_message = 'WARNING: One or more dbspaces has exceeded the set limit';
my $mail_attach  = $logfile;
my $mail_attname = "$basename.log";

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

# Timestamp for csv report and "is it Sunday" variable
my $timestamp = POSIX::strftime("%Y/%m/%d %H:%M:%S", localtime);
# Sunday is day 0, which evaluates to false, so invert the result
my $sunday = POSIX::strftime("%w", localtime) ? 0 : 1;

# If it IS Sunday, send out the weekly email of the CSV records
&email_csv;

# Assemble the list of dbspaces to report
foreach my $i ( sort keys $config{'DBSPACES'} ) {
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
open LOG, ">  $logfile" or die "cannot open LOG: $logfile $?\n";
open CSV, ">> $csvfile" or die "cannot open CSV: $csvfile $?\n";
 
# Create a temporary sql file which will be removed when we finish
# and write the SQL into it.
my ($SQL, $filename) = tempfile( UNLINK => 1, SUFFIX => '.sql') or die "cannot create temp file: $?\n";

print $SQL $sql;
close $SQL;

# Create the shell script to run the SQL
my $script = &write_script;

# Make it executable
chmod 0700, $script;

# And gather the output into the @gulp array
@gulp = `$script`;

# Some more variables
my $start = 0;
my %l = ();
my $exceeded = 0;

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

            # Retrieve the waring limit from the config array
            $limit = $config{'DBSPACES'}{$name};

            # Increment the exceeded flag if the size is over limit
            $exceeded++ if $pctu > $limit;
         
            # Write out the logfile
            write LOG;

            # And the CSV file
            print CSV "$timestamp\,$name\,$size\,$free\,$used\,$pctu\,$limit\n";
        } else {
            # Inside the dbspace block
            # Split the line into key/value pairs
            my ($key, $val) = split;
            #
            # And push them into the hash
            $l{$key} = $val;
        }
    }
}
 
# Close both of the opened files
close LOG;
close CSV;

# If we need to send off an email
if ( $exceeded > 0 ) {
    # Set up the vairable portions
    $mail_subject = "DBSpace Checker for $host";
    $mail_message = 'WARNING: One or more dbspaces has exceeded the set limit';
    $mail_attach  = $logfile;
    $mail_attname = "$basename.log";

    # And call the send email subroutine
    &send_email;
}

# Display the logfile report
# Useful if run from the command line
system("cat $logfile");

# These next few lines define the output format of the logfile
format LOG_TOP =
DBSpace Name            Size MB     Free MB    Used MB   Percent     Limit
-------------------  ----------  ---------- ---------- --------- ---------
.
 
format LOG =
@<<<<<<<<<<<<<<<<<<  @>>>>>>>>>  @>>>>>>>>> @>>>>>>>>> @####.##% @####.##%
$name,               $size,      $free,     $used,     $pctu,    $limit
.

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
    $msg = MIME::Lite->new(
                     From     => $mail_from,
                     To       => $mail_to,
                     Cc       => $mail_cc,
                     Subject  => $mail_subject,
                     Type     => 'multipart/mixed'
                     );

    if ( $mail_host and $mail_user and $mail_pass ) {
        MIME::Lite->send('smtp', $mail_host, Timeout=>60,
                          AuthUser=>$mail_user, AuthPass=>$mail_pass);
    } elsif ( $mail_host ) {
        MIME::Lite->send('smtp', $mail_host, Timeout=>60);
    }


    # Add your text message.
    $msg->attach(Type         => 'text',
                 Data         => $mail_message
                 );

    # Specify your file as attachement.
    $msg->attach(Type         => 'text',
                 Path         => $logfile,
                 Filename     => $mail_attname,
                 Disposition  => $mail_attach
                 );       
    $msg->send;
}

# This subroutine creates the script file to be executed
sub write_script {
    # Create a temporary file
    my ($SCRIPT, $scriptfile) = tempfile( UNLINK => 1, SUFFIX => '.sh') or die "cannot create temp script file: $?\n";

    # Gather all of the keys from the config hash from the ENV section
    foreach my $i (sort keys $config{'ENV'} ) {
        # Except the path variable (if it's there)
        next if ( $i eq 'PATH' );
        # Create lines which look like: export MYVAR=value
        print $SCRIPT "export $i=$config{'ENV'}{$i}\n";
    }
    # Then add the PATH export, just adding the Informix bi directory
    my $path = $ENV{'PATH'};
    print $SCRIPT "export PATH=$path:$config{'ENV'}{'INFORMIXDIR'}/bin\n";
    print $SCRIPT "\n";
    # Run dbaccess over the SQL script on the sysmaster database
    print $SCRIPT "dbaccess sysmaster $filename 2>/dev/null";
    close $SCRIPT;

    # Return the name of the scriptfile
    return $scriptfile;
}

sub email_csv {
    # If it's Sunday
    if ( $sunday ) {
        # And we have already run the send csv process
        if ( stat($lockfile) ) {
            # Just exit the subroutine
            # because we have already done the process
            return;
        }
    } else {
        # It's NOT Sunday
        # Remove the lockfile
        unlink($lockfile) if ( stat($lockfile) );
        # And exit the subroutine
        return;
    }

    # Time to send the email
    $mail_subject  = "DBSpace CSV file from $host";
    $mail_message  = "The attached CSV file contains all of the results of\r\n";
    $mail_message .= "the $0 script for the last week.\r\n";
    $mail_attach   = $csvfile;
    $mail_attname  = "$basename.csv";

    # And actually send it
    &send_email;

    # Create the lock file
    open my $LOCK, '>', $lockfile;
    close $LOCK;

    # And clear out the CSV file to start a new week
    open my $CSV, '>', $csvfile;
    close $CSV;
}
