
#
#   This scipt exports the BNA schema for further usage (OAC)
#

deleteMigEnv()
{

  echo "
+===================================================================================
|
|      Supprission environnement de  migration 19c DB=$dbName
|
+===================================================================================
  "

  echo
  echo "DB Connection check"
  echo

  exec_sql "/ as sysdba" "select 1 from dual ;" "  - Testing DATABASE CONNECT String" || die "Unable to connect to the database" 


  START_INTERM_EPOCH=$(date +%s)
  echo   "========================================================================================" 
  echo   "  - Preparation"
  echo   "  - Started at     : $(date)"
  echo   "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "

  echo

  echo "  - Test d'existence de $MIG_USER" 
  res=$(exec_sql "/ as sysdba"               "select to_char(count(*)) from dba_users where username='$MIG_USER' ;")
  if [ "$res" != "0" ]
  then
    echo "    ==> $MIG_USER existe"
    exec_sql "/ as sysdba" "drop user $MIG_USER cascade ;" "      - Suppression $MIG_USER" || die
  else
    echo "    ==> $MIG_USER n'existe pas"
  fi

  echo

  END_INTERM_EPOCH=$(date +%s)
  all_secs2=$(expr $END_INTERM_EPOCH - $START_INTERM_EPOCH)
  mins2=$(expr $all_secs2 / 60)
  secs2=$(expr $all_secs2 % 60 | awk '{printf("%02d",$0)}')
  echo   "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo   "  - Ended at      : $(date)" 
  echo   "  - Duration      : ${mins2}:${secs2}"
  echo   "========================================================================================" 
  echo   "Script LOG in : $LOG_FILE"
  echo   "========================================================================================" 
}

createMigEnv()
{
  echo "
+===================================================================================
|
|      Preparation migration 19c DB=$dbName
|
+===================================================================================
  "

  echo
  echo "DB Connection check"
  echo

  exec_sql "/ as sysdba " "select 1 from dual ;" "  - Testing DATABASE CONNECT String" || die "Unable to connect to the database"


  START_INTERM_EPOCH=$(date +%s)
  echo   "========================================================================================" 
  echo   "  - Preparation"
  echo   "  - Started at     : $(date)"
  echo   "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "

  echo

  echo "  - Test d'existence de $MIG_USER"
  res=$(exec_sql "/ as sysdba" "select to_char(count(*)) from dba_users where username='$MIG_USER' ;")
  if [ "$res" != "0" ]
  then
    echo "    ==> $MIG_USER existe ($res)"
  else
    echo "    ==> $MIG_USER n'existe pas"
     exec_sql "/ as sysdba" "create user $MIG_USER identified by "$MIG_PASS" ;" "    - Creation de $MIG_USER" || die
  fi

  echo

  res=$(exec_sql -silent "\"$MIG_USER\"/\"$MIG_PASS\""    "select dummy from dual ;")
  printf "%-75s : " "  - Mot de passe de $MIG_USER" ; [ "$res" = "X" ] && { echo "OK" ; migUserPassOk=Y ; }  || { echo "Err" ; migUserPassOk=N ; }
  
  if [ "$migUserPassOk" != "Y" ]
  then
    exec_sql "/ as sysdba " "alter user $MIG_USER identified by "$MIG_PASS"; " "    - Reinit Mot de Pass de $MIG_USER" || die
  fi

  echo

  echo "  - Privileges de $MIG_USER"
  p="CREATE SESSION"             ; exec_sql "/ as sysdba " "grant $p to $MIG_USER container=all ; " "    - $p" || die "Impossible de donner $p à $MIG_USER"
  p="CONNECT"                    ; exec_sql "/ as sysdba " "grant $p to $MIG_USER container=all ; " "    - $p" || die "Impossible de donner $p à $MIG_USER"
  p="SELECT ANY DICTIONARY"      ; exec_sql "/ as sysdba " "grant $p to $MIG_USER container=all ; " "    - $p" || die "Impossible de donner $p à $MIG_USER"
  p="CREATE PLUGGABLE DATABASE"  ; exec_sql "/ as sysdba " "grant $p to $MIG_USER container=all ; " "    - $p" || die "Impossible de donner $p à $MIG_USER"

  exec_sql "/ as sysdba " "alter user $MIG_USER set container_data=all container=current;" "    - Vue sur les conteneurs"  || die
  echo

  END_INTERM_EPOCH=$(date +%s)
  all_secs2=$(expr $END_INTERM_EPOCH - $START_INTERM_EPOCH)
  mins2=$(expr $all_secs2 / 60)
  secs2=$(expr $all_secs2 % 60 | awk '{printf("%02d",$0)}')
  echo   "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo   "  - Ended at      : $(date)" 
  echo   "  - Duration      : ${mins2}:${secs2}"
  echo   "========================================================================================" 
  echo   "Script LOG in : $LOG_FILE"
  echo   "========================================================================================" 
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

usage() {
 echo "Usage :
 $SCRIPT [-?] [-c dbName] [-p pdbName] [-C|-D]
   -?           : Help
  "
  exit
}


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
die() 
{
  echo "
ERROR :
  $*"
  exit 1
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
exec_sql()
{
#
#  Don't forget to use : set -o pipefail un the main program to have error managempent
#
  local VERBOSE=N
  local SILENT=N
  if [ "$1" = "-silent" ]
  then 
    SILENT=Y
    shift
  fi
  if [ "$1" = "-no_error" ]
  then
    err_mgmt="whenever sqlerror continue"
    shift
  else
    err_mgmt="whenever sqlerror exit failure"
  fi
  if [ "$1" = "-verbose" ]
  then
    VERBOSE=Y
    shift
  fi
  local login="$1"
  local stmt="$2"
  local lib="$3"
  local bloc_sql="$err_mgmt
set recsep off
set head off 
set feed off
set pages 0
set lines 2000
connect ${login}
$stmt"
  REDIR_FILE=""
  REDIR_FILE=$(mktemp)
  if [ "$lib" != "" ] 
  then
     printf "%-75s : " "$lib";
     sqlplus -s /nolog >$REDIR_FILE 2>&1 <<%EOF%
$bloc_sql
%EOF%
    status=$?
  else
     sqlplus -s /nolog <<%EOF% | tee $REDIR_FILE  
$bloc_sql
%EOF%
    status=$?
  fi
  if [ $status -eq 0 -a "$(egrep "SP2-" $REDIR_FILE)" != "" ]
  then
    status=1
  fi
  if [ "$lib" != "" ]
  then
    [ $status -ne 0 ] && { echo "*** ERREUR ***" ; test -f $REDIR_FILE && cat $REDIR_FILE ; rm -f $REDIR_FILE ; } \
                      || { echo "OK" ; [ "$VERBOSE" = "Y" ] && test -f $REDIR_FILE && cat $REDIR_FILE ; }
  fi 
  rm -f $REDIR_FILE
  [ $status -ne 0 ] && return 1
  return $status
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

testPDB()
{
  printf "%-75s : " "  - Testing that PDB is $1"
  ret=$(exec_sql "$CONNECT_STRING" "select pdb_name from dba_pdbs;") || { echo "SQL Error" ; echo "$ret" ; return 1 ; }
  [ "${ret}" = "${1^^}" ] && echo "OK" || { echo "*** ERROR *** (ret=$ret)" ; return 1 ; }
  return 0
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
checkDir()
{
  printf "%-75s : " "  - Existence of $1"
  if [ ! -d $1 ]
  then
    echo "Non Existent"
    printf "%-75s : " "    - Creation of $1"
    mkdir -p $1 && echo OK || { echo "*** ERROR ***" ; return 1 ; }
  else
    echo "OK"
  fi
  printf "%-75s : " "    - $1 is writable"
  [ -w $1 ] && echo OK || { echo "*** ERROR ***" ; return 1 ; }
  return 0
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
set -o pipefail

[ "$1" = "" ] && usage

while getopts :c:p:CD opt
do
  case $opt in
   c)   dbName=$OPTARG  ; toShift=$(($toShift + 1)) ;;
   p)   pdbname=$OPTARG ; toShift=$(($toShift + 1)) ;;
   C)   mode=CREATE     ; toShift=$(($toShift + 1)) ;;
   D)   mode=DELETE     ; toShift=$(($toShift + 1)) ;;
   ?|h) usage ;,
  esac
done
shift $toSift 

dbName=${dbName:-tstmig}
pdbName=
mode=${mode:-CREATE}

echo " - Set environment for $dbName"
[ -f "$HOME/$dbName.env" ] || die "$dbName.env non existent"
. "$HOME/$dbName.env"
[ "$(exec_sql "/ as sysdba" "select  name from v\$database;")" != "${dbName^^}" ] && die "Environnement mal positionne"

DAT=$(date +%Y%m%d_%H%M)                                 # Export DATE (for filenames)
BASEDIR=$HOME/migate19                                  # Base dir for logs & files
MIG_DIR=$BASEDIR/$dbName
LOG_DIR=$MIG_DIR/log
LOG_FILE=$LOG_DIR/migPrep_${mode}_${DAT}.log
MIG_USER="C##PDBCLONE"
MIG_PASS="Wel_Come_12"
CONNECT_STRING="\"$USERNAME\"/\"$PASSWORD\"@//$SCAN_NAME:$SCAN_PORT/$SERVICE_NAME"

checkDir $LOG_DIR || die "$LOG_DIR is incorrect"

case $mode in
 CREATE) createMigEnv 2>&1 | tee $LOG_FILE ;;
 DELETE) deleteMigEnv 2>&1 | tee $LOG_FILE ;;
esac

exit


checkDir $PHYSICAL_DIR/log || die "$PHYSICAL_DIR/log is incorrect"

toShift=0
exit

