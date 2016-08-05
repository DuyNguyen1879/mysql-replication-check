# mysql-replication-check

## Description

mysql-replication-check checks if there are differences between the master and the slave(s). It must be
called twice (2 steps):
1) Compute master checksums;
2) Check differences on the slaves.
The reason why it has 2 steps is that some slaves could be delayed.
If differences are found, an alert is sent via mail to the specified addresses.

mysql-replication-check relies on some tools in Percona Toolkit:
* pt-table-chdcksum is used to calculate checksums and check differences;
* a pt-table-sync command is included in the alert mail, to fix the problem.

## Install

mysql-replication-check expects to find a configuration file called sync-data.cnf. Create it
using sync-data.cnf.example as a template.

All options are documented, with comments, in sync-data.cnf.example.

## Usage

Basic usage:

```
sync-data.sh -s 1
sync-data.sh -s 2
```

### Parameters

Some parameters can be passed via the command line, overriding the configuration file settings. See sync-data.sh source code for complete list.

        -X              Dry run: don't execute any SQL statement or run pt tools.

