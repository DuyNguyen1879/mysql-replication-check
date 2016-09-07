#!/bin/bash

function check_mysql_connection {
  if [ "`mysql $mysql_options -NBe 'select 1'`" != "1" ] 
  then
    echo "Can't connect to local mysql. Please add connection information to ~/.my.cnf"
    echo "Example: "
    echo "[client]"
    echo "user=percona"
    echo "password=s3cret"
    echo "# If RDS, add host="
    echo ""
    exit 1
  fi
}

# Get specified value from SHOW SLAVE STATUS.
# Example:
# $LAG=get_slave_status_variable('Seconds_behind_master')
function get_slave_status_variable {
  echo `mysql -h127.0.0.1 -uroot -p'yceZ^gtZL%c669Y!6sT' -P33063 -e "SHOW SLAVE STATUS \G" | grep 'SQL_Delay' | awk '{print $2}'`
}


# get paths
PRG=$(basename $0)
TMP=/tmp/$PRG.$$.tmp

mysql="mysql --skip-column-names"
if [ -z $PT_TABLE_CHECKSUM ] ; then
  PT_TABLE_CHECKSUM="pt-table-checksum"
fi

# default parameters
DRY_RUN=false
echo "Reading sync-data.cnf"
if [ ! -f sync-data.cnf ]; then
  echo "File sync-data.cnf not found"
  exit 1
fi

. sync-data.cnf

USAGE="sync-data.sh calls pt-table-checksum and sends an alert via email in case slaves are out of sync.
  -s  Step: 1 to check master and regular slaves, 2 to check delayed slaves (after the checksums are replicated).
  -h  Master IP or hostname
  -P  Master port
  -u  Master user
  -p  Master password
  -d  Database on which pt-table-checksum will write
  -c  Name of the checksum table
  -r  Number of retries if an error occurs (for example, because a slave is lagging)
  -q  Quiet mode
  -l  Max lag: how much seconds pt-table-checksum can wait if a slave lags
  -X  Don't run queries or pt-table-checksum (test only)"

# Parse the command line arguments:
while getopts h:P:u:p:l:d:c:t:T:o:qw:e:s:l:X c ; do
  case $c in
    h)  MASTER_HOST="${OPTARG}" ;;
    P)  MASTER_PORT="${OPTARG}" ;;
    u)  MASTER_USER="${OPTARG}" ;;
    p)  MASTER_PASSWORD="${OPTARG}" ;;
    c)  CKSUMS_TABLE="${OPTARG}" ;;
    T)  ignore_tables_clause="--ignore-tables ${OPTARG}" ;;
    t)  TABLES_CLAUSE="--tables ${OPTARG}" ;;
    d)  DB_NAME="${OPTARG}" ;;
    r)  RETRIES="${OPTARG}" ;;
    q)  QUIET="Yes" ;;
    o)  OPTS="${OPTARG}" ;;
    w)  WHERE="--where \"${OPTARG}\"" ;;
    e)  ERR_FILE="${OPTARG}" ;;
    l)  MAX_LAG="${OPTARG}" ;;
    X)  DRY_RUN=true ;;
    s)  STEP="${OPTARG}" ;;
    *)
        echo "$USAGE"
        exit 2
        ;;
  esac
done

# validate options

if [ "$DATADIR" == "" ] ; then
  echo "DATADIR must be specified!"
  exit
fi
if [ ! -d "$DATADIR" ]; then
  echo "Specified DATADIR is not a directory"
  exit
fi

if [ "$MASTER_USER" == "" -o "$MASTER_PASSWORD" == "" ] ; then
  echo "MASTER_USER (-u) and MASTER_PASSWORD (-p) must be specified!"
  exit
fi

if [ "$STEP" != "1" ] && [ "$STEP" != "2" ] ; then
  echo "STEP (-s) must be specified, and allowed values are 1 and 2!"
  exit
fi

if [ "$STEP" == "1" ]; then
  # prepare the database for re-execution
  if ! $DRY_RUN 2> /dev/null ; then
    echo "Creating checksum DB: $DB_NAME..."
    mysql -h$MASTER_HOST -P$MASTER_PORT -u$MASTER_USER -p$MASTER_PASSWORD -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
    echo "Dropping checksum table table $CKSUMS_TABLE..."
    mysql -h$MASTER_HOST -P$MASTER_PORT -u$MASTER_USER -p$MASTER_PASSWORD -D $DB_NAME -e "TRUNCATE TABLE $CKSUMS_TABLE;"
  else
    echo 'Skipping database recreation because because -X was specified'
  fi

  # Gather checksums and check differences with non-delayed slaves
  echo "Getting checksums and checking non delayed slaves..."
  cmd="$PT_TABLE_CHECKSUM \
                    --replicate=$DB_NAME.$CKSUMS_TABLE \
                    --retries=3 \
                    --create-replicate-table \
                    --no-replicate-check \
                    --no-check-replication-filters \
                    --no-check-binlog-format \
                    --check-slave-lag h=127.0.0.1,P=33061 \
                    --recursion-method dsn=h=$MASTER_HOST,D=$DB_NAME,t=dsns \
                    --progress=time,10 \
                    --max-lag=$MAX_LAG"

  echo "$cmd $WHERE"x

  if ! $DRY_RUN 2> /dev/null ; then
    eval "$cmd $WHERE" 2>&1
    `date +%s` > $DATADIR/master_check_time
  else
    echo 'Skipping checksum calculation because because -X was specified'
  fi
else
  # check if enough time has passed

  # get lag info from SHOW SLAVE STATUS
  SLAVE_EXPECTED_DELAY=$LAG=get_slave_status_variable('SQL_Delay')
  SLAVE_CURRENT_LAG=$LAG=get_slave_status_variable('Seconds_behind_master')

  # check can only be done if slave is applying this timestamp event
  MIN_EVENT_TIME=(`cat $DATADIR/master_check_time`+SLAVE_EXPECTED_DELAY)
  # slave is replicating this timestamp
  SLAVE_TIMESTAMP=(`date %s`-SLAVE_CURRENT_LAG)

  #`(date %s-$DATADIR/master_check_time)`
  if ( MIN_EVENT_TIME > SLAVE_TIMESTAMP ); then
    echo 'Cannot run check because of replication lag; retry later'
    exit
  fi

  # Check for differences on the delayed slave
  cmd="$PT_TABLE_CHECKSUM \
                  --replicate-check \
                  --replicate-check-only \
                  --replicate=$DB_NAME.$CKSUMS_TABLE \
                  --retries=3 \
                  --no-check-replication-filters \
                  --no-check-binlog-format \
                  --recursion-method dsn=h=$MASTER_HOST,D=$DB_NAME,t=dsns \
                  --check-slave-lag h=127.0.0.1,P=33062 \
                  --progress=time,10 \
                  --max-lag=$MAX_LAG"

  echo ""
  echo "$cmd"
  echo ""

  if ! $DRY_RUN 2> /dev/null ; then
    $cmd | tee -a $TMP.diffs
    else
      echo 'Skipping slave checking because because -X was specified'
  fi
fi

NOTE="Note:  The following commands are intended as a short-cut and can be used to sync servers. \
 DO NOT execute these commands without consideration of the replication architecture. \
 There are several cases where these commands will not work and will in fact create further issues if run."

# Mail out the report if there are any sync diffs
if [ -s $TMP.diffs ] ; then
  cat $TMP.diffs | grep "Differences on" | while read w1 w2 host ; do
    echo ""
    echo "Server: $host"
    echo ""
    echo "To see diffs:"
    echo "pt-table-sync --print --verbose --replicate $DB_NAME.$CKSUMS_TABLE --no-foreign-key-checks --sync-to-master $host "
    echo "To fix diffs:"
    echo "pt-table-sync --verbose --execute --verbose --replicate $DB_NAME.$CKSUMS_TABLE --no-foreign-key-checks --sync-to-master $host "
    echo ""
  done >> $TMP.resync

  if [ "$QUIET" == "No" ] ; then
    (cat $TMP.diffs; echo "$NOTE"; cat $TMP.resync) | mail -s "Slave sync check differences $LIST_CLAUSE" $RECIPIENTS
  fi
fi

echo "DONE"

