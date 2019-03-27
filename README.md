# Informix DBSpace Size Checker

This Perl script and associated ini file can be used to monitor dbspace usage in an Informix database.

## The INI file

The ini file contains sections which are treated differently.

* **[ENV]** - The environment section

  All of the data in this section will be added to the shell script which is run the generated SQL command.
  Each element will generate the following: export LH_Value=RH_Value
  The intenstion is to ensure that a sane Informix environment is available.

* **[EMAIL]** - The eMail section

  This section contains email send to send from and cc data.
  It can also optionally contain an SMTP server name and a username and password pair.
  These will be used to connect to an SMTP server which requires authentication.

* **[DBSPACES]** - List of dbspaces to report

  This section contains pairs of dbspaces and the warning limit.

## The output files

The script generates two files: 
* **dbspacechk.csv**

  This file has CSV type data appended to it each time the script runs.
  It contains a timestamp, dbspace name, the size of the dbspace, the amount of free space, the used space, percent used and the percentage limit.

* **dbspacechk.log**

  This file has a simple texual report detailing the same information in an easy to read format.

## Other information

The script will email the log file to the recipients listed in the ini file if the limits are exceeded on any of the dbspaces.

Additionally, each Sunday, the CSV file is emailed and then cleared.
This file can be loaded into a spreadsheet program for further reporting, graphing and monitoring.
