#!/bin/bash

# get paths
PRG=$(basename $0)
TMP=/tmp/$PRG.$$.tmp

mysql="mysql --skip-column-names"
if [ -z $PT_TABLE_CHECKSUM ] ; then
  PT_TABLE_CHECKSUM="pt-table-checksum"
fi

# default parameters
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
    X)  DRY_RUN="True" ;;
    s)  STEP="${OPTARG}" ;;
    *)
        echo "$USAGE"
        exit 2
        ;;
  esac
done

# validate options

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
  if [ ​"$DRY_RUN" != 'True' ] ; then
    echo "Creating checksum DB: $DB_NAME..."
    mysql -h$MASTER_HOST -P$MASTER_PORT -u$MASTER_USER -p$MASTER_PASSWORD -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
    echo "Dropping checksum table table $CKSUMS_TABLE..."
    mysql -h$MASTER_HOST -P$MASTER_PORT -u$MASTER_USER -p$MASTER_PASSWORD -D $DB_NAME -e "TRUNCATE TABLE $CKSUMS_TABLE;"
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

  if [ ​"$DRY_RUN" != 'True' ] ; then
    eval "$cmd $WHERE" 2>&1
  else
    echo 'Not executing because -X was specified!'
  fi
else
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

  if [ "$DRY_RUN" != 'True' ]; then
    $cmd | tee -a $TMP.diffs
    else
      echo 'Not executing because -X was specified!'
  fi
fi

NOTE="Note:  The following commands are intended as a short-cut and can be used to sync servers. \
 DO NOT execute these commands without consideration of the replication architecture. \
 There are several cases where these commands will not work and will in fact create further issues if run."

# Mail out the report if there are any sync diffs
if [ -s $TMP.diffs ] ; then
  cat $TMP.diffs | grep "Differences on" | while read w1 w2 host ; do
    echo ""
    echo "To see replication diffs (SQL statements to fix diffs):"
    echo "pt-table-sync --print --verbose --replicate $DB_NAME.$CKSUMS_TABLE --no-foreign-key-checks --sync-to-master $host "
    echo ""
    echo "To fix diffs:"
    echo "pt-table-sync --verbose --execute --verbose --replicate $DB_NAME.$CKSUMS_TABLE --no-foreign-key-checks --sync-to-master $host "
    echo ""
  done >> $TMP.resync

  if [ "$QUIET" == "No" ] ; then
    (cat $TMP.diffs; echo "$NOTE"; cat $TMP.resync) | mail -s "Slave sync check differences $LIST_CLAUSE" $RECIPIENTS
  fi
fi

echo "DONE"

