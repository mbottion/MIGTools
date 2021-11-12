#!/bin/bash

# Description : script to duplicate from an oracle OCI bucket to an existing enveloppe
# Author : Amaury FRANCOIS <amaury.francois@oracle.com>
# Logging added : Michel BOTTIONE

customPostUpgrade()
{
  # 
  # -----------------------------------------------------------------------------------------
  # 

  startStep "Final recompilation and Materialized view re-creation"
  
  message "DB environment loading"
  load_db_env $OCI_TARGET_DB_NAME

  pdbs=$(exec_sql "/ as sysdba" "select name from v\$pdbs where name != 'PDB\$SEED';") || die "Unable to get PDBS list $pdbs"
  for pdb in $pdbs
  do
    message "Custom upgrade tasks for $pdb"
    if echo $REMAP_PDBS | grep "${pdb}>" > /dev/null
    then
      remap=$(echo ${REMAP_PDBS^^} | sed -e "s;^.*${pdb}>;${pdb}>;")
      remap=$(echo $remap | cut -f1 -d";")
    else
      remap=""
    fi
    if [ "$remap" != "" ]
    then
      old=$(echo $remap | cut -f1 -d ">")
      new=$(echo $remap | cut -f2 -d ">")
      log_info "Renaming $old pluggable database to $new"
      exec_sql "/ as sysdba" "
set feed on heading on
prompt Close $old and open restricted
alter pluggable database $old close immediate instances=all ;
alter pluggable database $old open restricted ;

prompt Rename
alter pluggable database $old rename global_name to $new ;
show pdbs ;

prompt Open and save state
alter pluggable database $new close immediate instances=all ;
alter pluggable database $new open instances=all ;
alter pluggable database $new save state ;" || die "Error when renaming the $old PDB to $new"
      log_success "$old Renamed to $new"
      pdb=$new
    fi
    
    recompEtVuesMat $pdb
    getInvalidObjects  "/ as sysdba" "$pdb"
    addServices $pdb

  done

  log_info "Apply known FIX_CONTROLS and activate 19c disabled fixes"

  exec_sql "/ as sysdba" "
Prompt FIX_CONTROLS for CNAF : 7268249:0,5909305:OFF
alter system reset \"_fix_control\" scope=both ;
ALTER SYSTEM set \"_fix_control\"='27268249:0','5909305:OFF' scope=both ;

Prompt Activate all 19c FIXES
Set serveroutput on

execute dbms_optim_bundle.enable_optim_fixes('ON','BOTH', 'YES') ; " || die "There was a problem activating FIX_CONTROLS"
log_success "Done"

log_info "Bounce database"
srvctl stop database -d $ORACLE_UNQNAME || die "Unable to stop the $ORACLE_UNQNAME database"
srvctl start database -d $ORACLE_UNQNAME || die "Unable to start the $ORACLE_UNQNAME database"
log_success "Database restarted"

log_info "Database and services Status"
srvctl status database -d $ORACLE_UNQNAME
echo
srvctl config database -d $ORACLE_UNQNAME
echo
srvctl status service  -d $ORACLE_UNQNAME

  endStep

  
  # 
  # -----------------------------------------------------------------------------------------
  # 
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#      Recompile et recrée les vues matérialisées (si nécessaire) en fait, 
#  c'est juste du PL/SQL!!!
#  
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
recompEtVuesMat()
{
  log_info "Recompile invalid objects and re-create materialized view if needed ($pdb)"
  exec_sql "/ as sysdba" "
set feedback on
alter session set container=$1 ;

set serveroutput on

declare 
  reste number ;
  
  procedure rebuildMV(s in varchar2,v in varchar2) is
    text varchar2(32767) ;
    stmt varchar2(32767) ;
    i number := 1 ;
    h number ;
    t number ;
  begin
    dbms_metadata.set_transform_param(DBMS_METADATA.SESSION_TRANSFORM,'PRETTY',TRUE);
    dbms_metadata.set_transform_param(DBMS_METADATA.SESSION_TRANSFORM,'SQLTERMINATOR',TRUE);
    text :=         regexp_replace(dbms_metadata.get_ddl('MATERIALIZED_VIEW',v,s) 
                                  ,'^([^(]*)(\([^)]*\))(.*)\$','\1 /* Supprime pour MIg 19C \2*/ \3',1,1,'n'
                                  );
    begin 
      text := text || dbms_metadata.get_dependent_ddl('INDEX',v,s) ;
    exception when others then null ;
    end ;
    begin
      text := text || dbms_metadata.get_dependent_ddl('COMMENT',v,s) ;
    exception when others then null ;
    end ;
    begin
      text := text || dbms_metadata.get_dependent_ddl('OBJECT_GRANT',v,s) ;
    exception when others then null ;
    end ;
    stmt := 'x' ;
    while stmt is not null
    loop
      stmt := regexp_substr(text , '[^;]+',1,i) ;
      if stmt is not null
      then
        if upper(stmt) like '%CREATE%MATERIALIZED%'
        then
          dbms_output.put_line('.                Drop MV: ' || s || '.'|| v) ;
            execute immediate 'drop materialized view \"' || s || '\".\"' || v || '\"';
            dbms_output.put_line('.                Recreation : ' || s || '.'|| v) ;
        end if ;
        --dbms_output.put_line(' ---> '|| stmt) ;
        begin
          execute immediate stmt ;
        exception when others then
          dbms_output.put_line('.                Error executing          : ' || stmt) ;
          raise ;
        end ;
      end if ;
      i := i+1 ;
    end loop ;
  end ;
begin
  dbms_output.put_line('.');
  dbms_output.put_line('.  Post-upgrade processing');
  dbms_output.put_line('.  =======================');
  dbms_output.put_line('.');
  for invalidSchemas in (select owner,count(*) nb_invalid 
                         from dba_objects 
                         where status = 'INVALID' and owner not in ('SYS','PUBLIC')
                         group by owner
                        )
  loop
    dbms_output.put_line ('.');
    dbms_output.put_line (rpad(invalidSchemas.owner,20) || ': ' || invalidSchemas.nb_invalid || ' invalid objects ') ;
    if ( invalidSchemas.nb_invalid != 0 )
    then
      dbms_output.put_line('.       ====> Recompilation') ;
      dbms_utility.compile_schema(invalidSchemas.owner) ;
      select 
        count(*) 
      into 
        reste
      from 
        dba_objects 
      where 
            status='INVALID' 
        and owner = invalidSchemas.owner ;
      dbms_output.put_line('.             Reste : ' || reste || ' invalid objects') ;
      if ( reste != 0 )
      then
        dbms_output.put_line('.             ====> Rebuild MV') ;
        for invViews in (select object_name from dba_objects where object_type = 'MATERIALIZED VIEW' and  owner=invalidSchemas.owner and status='INVALID')
        loop
          rebuildMV(invalidSchemas.owner , invViews.object_name ) ;
        end loop ;
        select 
          count(*) 
        into 
          reste
        from 
          dba_objects 
        where 
              status='INVALID' 
          and owner = invalidSchemas.owner ;
        dbms_output.put_line('.             Remaining  : ' || reste || ' invalid objects') ;
      end if ;
    end if ;
  end loop;
end ;
/
" || die "Error when recompiling" 
  log_success "PDB Recompiled"
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#      Crée ou recrée les 4 services standards
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
addServices()
{
  local dstPdbName=$1
  log_info "Add application services"
  for SERVICE_SUFFIX in art batch api mes
  do
    sn=${dstPdbName,,}_${SERVICE_SUFFIX}
    echo    "    - $sn"

    if [ "$(srvctl status service -d $ORACLE_UNQNAME -s $sn | grep -i "is running")" != "" ]
    then
      echo -n "      - Stop            : "
      srvctl stop  service -d $ORACLE_UNQNAME -s $sn && echo "Ok" || die "Unable to stop service $sn"
    fi

    if [ "$(srvctl status service -d $ORACLE_UNQNAME -s $sn | grep -i "does not exist")" = "" ]
    then
      echo -n "      - Remove          : "
      srvctl remove   service -d $ORACLE_UNQNAME -s $sn && echo "Ok" || die "Unable to remove service $sn"
    fi

    sidPrefix=$(echo $ORACLE_SID  | sed -e "s;[0-9]$;;")
    echo -n "      - Create          : "
    srvctl add   service -d $ORACLE_UNQNAME -s $sn \
                         -pdb $dstPdbName \
                         -preferred ${sidPrefix}1,${sidPrefix}2 \
                         -clbgoal SHORT \
                         -rlbgoal SERVICE_TIME \
                         -failoverretry 30 \
                         -failoverdelay 10 \
                         -failovertype AUTO \
                         -commit_outcome TRUE \
                         -failover_restore AUTO \
                         -replay_init_time 1800 \
                         -retention 86400 \
                         -notification TRUE \
                         -drain_timeout 60 \
                         && echo "Ok" || die "Unable to add service $sn"

    if [ "$(srvctl status service -d $ORACLE_UNQNAME -s $sn | grep -i "does not have defined services")" = "" ]
    then
      echo -n "      - Start           : "
      srvctl start service -d $ORACLE_UNQNAME -s $sn && echo "Ok" || die "Unable to start $s"
    else
      die "Service $sn not created"
    fi

  done
  log_success "Services added"
}

getInvalidObjects()
{
  local cnx=$1
  local pdb=$2
  local label=$3
  log_info "Invalid objects in $pdb"
  exec_sql      "$cnx" "\
set pages 2000
set lines 400
set trimout on
set tab off
set heading on
set feedback on

column owner       format  a30
column object_type format a70
column nb_inv      format 999G999

break on owner skip 1 on object_type on report
compute sum of nb_inv on owner 
compute sum of nb_inv on report

alter session set container=$pdb ;

select
   owner
  ,object_type
  ,count(*) nb_inv
from
  dba_objects
where
      STATUS='INVALID' 
  and owner not in ('APPQOSSYS','MDSYS','XDB','PUBLIC','WMSYS'
                   ,'CTXSYS','ORDPLUGINS','ORDSYS','GSMADMIN_INTERNAL')
group by owner,object_type 
order by owner,object_type;

                " || die "Error when getting INVALID Objects on $pdb"
  log_success "Done"
}


init()
{
#Default
if [[ -z $OCI_RMAN_PARALLELISM ]]; then
	OCI_RMAN_PARALLELISM=32
fi

if [[ -z $OCI_SOURCE_DB_NAME || -z $OCI_BKP_DATE || -z $OCI_TARGET_DB_NAME || -z $OCI_DBID ]]; then
        log_error "Missing arguments"
        usage

        die "Program aborted"
fi

if [[ ! $OCI_BKP_DATE =~ ^20[0-9][0-9]-[01][0-9]-[0-3][0-9]_[0-2][0-9]:[0-5][0-9]:[0-5][0-9]$ ]]; then
        log_error "Date format does not match : 20YY-MM-DD_HH24:MI:SS"
        die "Program aborted"
fi

if [ ! -d ${OCI_BKP_LOG_DIR}/$OCI_TARGET_DB_NAME ]; then
        mkdir -p ${OCI_BKP_LOG_DIR}/$OCI_TARGET_DB_NAME
        if [ $? -ne 0 ]; then
                log_error "Error writing log file directory ${OCI_BKP_LOG_DIR}/$OCI_TARGET_DB_NAME. Exiting."
                die "Program aborted"
        fi
fi



if [ ! -z $OCI_BKP_DATE ]; then
        DATE_MES=" at time $OCI_BKP_DATE"
else
        DATE_MES=" at latest possible time"
fi

#
#      Additional checks
#

#Loading DB env
message "DB environment loading" 
load_db_env $OCI_TARGET_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when loading the environment. Exiting." 
        die "Please check $OCI_TARGET_DB_NAME existence"
fi


#Getting the scan address
message "SCAN address" 
get_scan_addr $OCI_TARGET_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when getting the local SCAN address. Exiting." 
        die "Please check $OCI_TARGET_DB_NAME scan configuration"
fi
#Checking if configuration exists, if not creating it
message "OCI Backup Configuration" 
create_check_config $OCI_SOURCE_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when checking or creating configuration file . Exiting." 
        die "Unable to create $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora"
fi
if [ "$(grep OPC_HOST $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora  | cut -f1 -d"=")" = "" ]
then
  log_error "Incomplete backup configuration"
  die "Please edit the $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora file to point to $OCI_SOURCE_DB_NAME backups"
fi


#Check if credentials are presents for this database
message "Credentials in wallet verification" 
check_cred $OCI_TARGET_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when checking credentials presence in wallet for this database. Exiting." 
        die "Please create credentials for target sys user:

Command :
-------

mkstore -wrl $OCI_BKP_CREDWALLET_DIR -createCredential $OCI_TARGET_DB_NAME sys

"
fi
#Checking and creating TNS conf
message "TNS and wallet configuration" 
create_check_tns $OCI_TARGET_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when checking or creating TNS configuration. Exiting." 
        die "Abort"
fi

message "Basic RMAN Check (restore the spfile to fake location)"
echo "To check : 
      - OPC Configuration
      - TDE Configuration
     "

srvctl stop database -d $ORACLE_UNQNAME
exec_sql "/ as sysdba" "Shutdown abort ; " "Force Shutdown"
TEMP_PFILE=$(mktemp)
rman target /  << EOF | tee /tmp/$$.log
set echo on;
startup nomount;
set DBID=$OCI_DBID
RUN {
ALLOCATE CHANNEL ch1 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=/$OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora)';
RESTORE SPFILE TO PFILE '$TEMP_PFILE' FROM AUTOBACKUP;
}
EOF
status=$?
rm -f $TEMP_FILE

if [ $status -ne 0 ]
then
  echo ""
  echo "================================================"
  echo "An error occured, try to find the root cause ..."
  echo "================================================"
  echo "TNS_ADMIN=$TNS_ADMIN"
  echo ""

  if grep "unable to open Oracle Database Backup Service" /tmp/$$.log >/dev/null
  then
    echo "There is a problem with OPC backups configuration"
    echo "   - Check /$OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora"
    echo "   - Ensure that the Source OPC Wallet has been copied into $OCI_BKP_ROOT_DIR/opc_wallet/${OCI_SOURCE_DB_NAME}" 
  fi

  if grep "ORA-28759 occurred during wallet operation" /tmp/$$.log > /dev/null
  then
    echo "There is a problem reading OPC backups"
    echo "   - OPC Wallet has not been copied into $OCI_BKP_ROOT_DIR/opc_wallet/${OCI_SOURCE_DB_NAME}" 
  fi

  if grep "HTTP response error" /tmp/$$.log > /dev/null
  then
   echo "Unable to access the backup bucket"
   echo "   - Check /$OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora"
  fi

  if grep "unable to decrypt backup" /tmp/$$.log > /dev/null
  then
    echo "Unable du decrypt the backup"
    echo "   - Has the the wallet been copied fron the source DB to the target DB§?"
    echo "   - Target DB TDE configuration : "
    cat $TNS_ADMIN/sqlnet.ora | sed -e "/ENCRYPTION_WALLET_LOCATION/ p" \
                                    -e "1, /ENCRYPTION_WALLET_LOCATION/ d" \
                                    -e "/^ *$/,$ d" 
  fi

  echo
  rm -f /tmp/$$.log
  log_error "ERROR when checking RMAN"
  die "Check TDE and RMAN"
fi
rm -f /tmp/$$.log
exec_sql "/ as sysdba" "Shutdown immediate ; " "Shutdown" || exec_sql "/ as sysdba" "Shutdown abort" "Force shutdown"
return 0
}

dropDatabase()
{
[[ $PROMPT == "true" ]] && ask_confirm "This command will stop and drop $OCI_TARGET_DB_NAME"
message "Stopping and Dropping the database"
log_info "Getting database status on all nodes"
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

log_info "Stopping database on all nodes"
srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME -o abort
exec_sql "/ as sysdba" "Shutdown abort ; " "Force Shutdown"

log_info "Getting database status on all nodes"
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v
SHORT_HOSTNAME=$(hostname -s)
export ORAENV_ASK=NO
export ORACLE_SID=+ASM${SHORT_HOSTNAME: -1}
. /usr/local/bin/oraenv
unset ORAENV_ASK

if [ -z $OCI_BKP_DB_UNIQUE_NAME ]; then
        log_error "OCI_BKP_DB_UNIQUE_NAME is not set"
        exit 1
fi

log_info "Removing all files using asmcmd"
asmcmd --privilege sysdba << EOF
rm -rf +DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/DATAFILE
rm -rf +DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/*/DATAFILE
rm -rf +DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/TEMPFILE
rm -rf +DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/*/TEMPFILE
rm -rf +DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/PARAMETERFILE
rm -rf +DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/CONTROLFILE
rm -rf +DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/CHANGETRACKING
rm -rf +DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/ONLINELOG
rm -rf +DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/PDBSEED
rm -rf +RECOC1/${OCI_BKP_DB_UNIQUE_NAME}/
EOF

}

spFileRestore()
{
#Loading DB env again
message "DB environment loading" | tee -a $LF
load_db_env $OCI_TARGET_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when loading the environment. Exiting." | tee -a $LF
        exit 1
fi

message "Spfile Restore"
log_info "Restoring the spfile to a temporary pfile"
TEMP_PFILE=$(mktemp)
rman target / << EOF
set echo on;
startup nomount;
set DBID=$OCI_DBID
RUN {
ALLOCATE CHANNEL ch1 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora)';
RESTORE SPFILE TO PFILE '$TEMP_PFILE' FROM AUTOBACKUP;
}
EOF
[ $? -ne 0 ] && { log_error "SPFILE Restoration error" ; return 1 ; }

log_info "Stopping database"

exec_sql "/ as sysdba" "shutdown abort;" "Shutdown ABORT"

log_info "Getting topology information"

CRS_HOME=$(grep "^ORA_CRS_HOME" /etc/init.d/ohasd | cut -f 2 -d '=')
NODE_LIST=$($CRS_HOME/bin/olsnodes)
CLUSTER_INTERCONNECT_PARAMS=$(for n in ${NODE_LIST}; do
echo "${OCI_TARGET_DB_NAME}${n: -1}.cluster_interconnects='$(ssh $n /sbin/ip a show | grep "clib[0-9]$" | awk '{print $2}' | cut -d/ -f1 | paste -sd ':')'"
done)

log_info "Modifying pfile to target"
sed -i "s/${OCI_SOURCE_DB_NAME}/${OCI_TARGET_DB_NAME}/" $TEMP_PFILE
sed -i "/cluster_interconnects=/d" $TEMP_PFILE
sed -i "/control_files/d" $TEMP_PFILE
sed -i "/__/d" $TEMP_PFILE
sed -i "/remote_listener/d" $TEMP_PFILE
sed -i "/db_unique_name/d" $TEMP_PFILE
sed -i "/db_name/d" $TEMP_PFILE
sed -i "/db_recovery_file_dest/d" $TEMP_PFILE
sed -i "/dg_broker/d" $TEMP_PFILE
sed -i "/sga_/d" $TEMP_PFILE
sed -i "/log_archive_config=/d" $TEMP_PFILE
sed -i "/inmemory_size=/d" $TEMP_PFILE
sed -i "/db_domain=/d" $TEMP_PFILE
echo "*.control_files='+DATAC1/${OCI_BKP_DB_UNIQUE_NAME}/CONTROLFILE/control.ctl'"  >> $TEMP_PFILE
echo "*.remote_listener='${OCI_SCAN_ADDR}:1521'"  >> $TEMP_PFILE
echo "*.db_unique_name='${OCI_BKP_DB_UNIQUE_NAME}'"  >> $TEMP_PFILE
echo "*.db_name='${OCI_SOURCE_DB_NAME}'"  >> $TEMP_PFILE
echo "*.db_recovery_file_dest='+RECOC1'"  >> $TEMP_PFILE
echo "*.db_recovery_file_dest_size=8192g"  >> $TEMP_PFILE
echo "*.sga_target=20g" >> $TEMP_PFILE
echo "*.inmemory_size=1g" >> $TEMP_PFILE
#echo "*.db_domain=dbad2.hpr.oraclevcn.com" >> $TEMP_PFILE
for p in  $CLUSTER_INTERCONNECT_PARAMS ; do
echo $p >> $TEMP_PFILE
done

log_info "Get audit_file_dest and create directory if needed"
audit_dir=$(grep audit_file_dest $TEMP_PFILE | cut -f2 -d= | sed -e "s;';;g")
if [ "$audit_dir" = "" ] 
then
  audit_dir=$ORACLE_HOME/rdbms/audit
  log_info "Not set, using $audit_dir"
fi
mkdir -p $audit_dir || return 1


SPFILE_LOC=$(srvctl config database -d $OCI_BKP_DB_UNIQUE_NAME | grep "^Spfile" | awk '{print $2}')
log_info "Spfile restore"
echo "   - Old SPFILE : $SPFILE_LOC"

exec_sql "/ as sysdba" "
prompt Startup on temp pfile ...
startup nomount pfile='$TEMP_PFILE';
prompt
prompt Creating the spfile ...
create spfile='+DATAC1' from pfile='$TEMP_PFILE';
whenever sqlerror continue
prompt Shutting down ...
shutdown immediate; " "Start with TEMP_PFILE" || die "Error Starting on PFILE"

SPFILE_LOC=$(srvctl config database -d $OCI_BKP_DB_UNIQUE_NAME | grep "^Spfile" | awk '{print $2}')
echo "   - New SPFILE : $SPFILE_LOC"

log_info "Starting the database with restored spfile"
srvctl start database -d $OCI_BKP_DB_UNIQUE_NAME -o nomount
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

log_info "Checking database state"
DB_STATE=$(exec_sql "/ as sysdba" "select inst_id, status from gv\$instance;")

if [[ $DB_STATE =~ "STARTED" ]]; then
        log_success "Database is in NOMOUNT state"
else
        log_error "Unable to start the database in NOMOUNT mode. Exiting"
        exit 1
fi


log_info "Checking spfile is in use"
SPFILE_RUNTIME_LOC=$(exec_sql "/ as sysdba" "select value from v\$parameter where name='spfile';")

SPFILE_RUNTIME_LOC=$(echo $SPFILE_RUNTIME_LOC | tr -d '\n')
if [[ ${SPFILE_RUNTIME_LOC,,} == ${SPFILE_LOC,,} ]]; then
        log_success "Database is in NOMOUNT state with an ASM spfile"
else
        log_error "Database is not using the ASM spfile. Exiting"
        exit 1
fi

rm -f $TEMP_PFILE
}

controlFileRestore()
{
message "Control file restore"
log_info "Restoring the controlfile"
rman target / << EOF
set echo on;
set DBID=$OCI_DBID
RUN {
ALLOCATE CHANNEL ch1 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora)';
RESTORE CONTROLFILE FROM AUTOBACKUP;
}
EOF

if [ $? -ne 0 ] 
then
  log_error "Unable to restore the control file" 
  return 
fi
log_info "Restarting the database in MOUNT mode"
srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME -o abort
srvctl start database -d $OCI_BKP_DB_UNIQUE_NAME -o mount
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v


log_info "Checking database state"
DB_STATE=$(exec_sql "/ as sysdba" "select status from gv\$instance;")

if [[ $DB_STATE =~ "MOUNTED" ]]; then
        log_success "Database started in MOUNT mode "
else
        log_error "Unable to restart the database in MOUNT mode. Exiting"
        return 1
fi
}

rmanConfig()
{
log_info "Clear RMAN configuration and do backup configuration"
rman target /@$OCI_TARGET_DB_NAME << EOF
set echo on;
CONFIGURE CHANNEL DEVICE TYPE DISK CLEAR;
CONFIGURE CHANNEL DEVICE TYPE 'SBT_TAPE' CLEAR;
CONFIGURE CONTROLFILE AUTOBACKUP OFF;
CONFIGURE CHANNEL DEVICE TYPE 'SBT_TAPE' PARMS  'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora)';
CONFIGURE DEVICE TYPE 'SBT_TAPE' PARALLELISM $OCI_RMAN_PARALLELISM BACKUP TYPE TO COMPRESSED BACKUPSET;
alter database flashback off;
EOF
[ $? -eq 0 ] || return 1
}

databaseRestoreAndRecover()
{
log_info "Getting list of tempfiles"
SWITCH_TEMPFILE_CLAUSE=$(exec_sql "/ as sysdba" "
set feed off head off lines 200 pages 300
select 'set newname for tempfile '||file#||' to new;' from v\$tempfile;")

message "Database restore and recover"
rman target /@$OCI_TARGET_DB_NAME << EOF
CONFIGURE CONTROLFILE AUTOBACKUP OFF;
run {
set until time "to_date('$OCI_BKP_DATE', 'yyyy-mm-dd_hh24:mi:ss')";
set newname for database to new;
$SWITCH_TEMPFILE_CLAUSE
restore database;
switch datafile all;
switch tempfile all;
recover database delete archivelog;
CONFIGURE SNAPSHOT CONTROLFILE NAME TO '+RECOC1/$OCI_BKP_DB_UNIQUE_NAME/snapcf_${OCI_TARGET_DB_NAME}.f';
}
EOF
[ $? -eq 0 ] || return 1

log_info "Disabling BCT if needed"
exec_sql "/ as sysdba" "
ALTER DATABASE DISABLE BLOCK CHANGE TRACKING;" "Disable BCT"

log_info "Backing up control file to trace and cluster database to false"
TRACE_CTL_FILE=$(mktemp -u)
exec_sql "/ as sysdba" "
alter database backup controlfile to trace as '$TRACE_CTL_FILE';
alter system set cluster_database=false scope=spfile;" "Control file to $TRACE_CTL_FILE"

log_info "Modify control file trace"
sed -i '1,/--     Set #2. RESETLOGS case/d' $TRACE_CTL_FILE
sed -i "/ONLINELOG/ s/'+DATAC1.*'/'+DATAC1'/" $TRACE_CTL_FILE
sed -i "/ONLINELOG/ s/'+RECOC1.*'/'+RECOC1'/" $TRACE_CTL_FILE
sed -i "/^RECOVER/d" $TRACE_CTL_FILE

grep -v EXECUTE $TRACE_CTL_FILE |grep -v "CREATE CONTROL" |grep -i "${OCI_SOURCE_DB_NAME}_.*/" > /dev/null 2>&1
if [ $? -eq 0 ]; then
        if [[ $OCI_TARGET_DB_NAME != $OCI_SOURCE_DB_NAME ]]; then
                log_error "Restored controlfile still contain references to logfile from source. Exiting." 
                exit 1
        fi
fi
}

postRestore()
{
log_info "Stopping the database"
srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME

log_info "Database status"
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

log_info "Setting environment using env file"
. ~/${OCI_TARGET_DB_NAME}.env

log_info "Recreating the control file"
exec_sql "/ as sysdba" "@${TRACE_CTL_FILE}" "Run ${TRACE_CTL_FILE}"

log_info "Checking database state"
DB_STATE=$(exec_sql "/ as sysdba" "select status from gv\$instance;")

if [[ $DB_STATE =~ "OPEN" ]]; then
        log_success "Database started in OPEN mode "
else
        log_error "Unable to restart the database in OPEN mode. Exiting"
        exit 1
fi

rm ${TRACE_CTL_FILE}

log_info "Stopping the database"
srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME

log_info "Database status"
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v


log_info "Starting in mount exclusive"
exec_sql "/ as sysdba" "startup mount exclusive;" "DB exclusive"

log_info "Changing the db name using nid"
$OCI_SCRIPT_DIR/change_db_name.exp $ORACLE_HOME $OCI_TARGET_DB_NAME


log_info "Restarting the database in open reset logs"

exec_sql -no_error "/ as sysdba" "
whenever sqlerror continue
prompt Starting nomount ...
startup nomount;
prompt Changing dbname to $OCI_TARGET_DB_NAME in spfile ...
alter system set db_name='$OCI_TARGET_DB_NAME' scope=spfile;
prompt Stopping ...
shutdown immediate;
prompt Starting mount ...
startup mount;

prompt
prompt opening with RESETLOGS ...
alter database open resetlogs;

prompt Reactivating cluster mode ...
alter system set cluster_database=true scope=spfile;
prompt
prompt Stopping ...
shutdown immediate;" 



log_info "Restarting the database in OPEN mode with srvctl"
srvctl start database -d $OCI_BKP_DB_UNIQUE_NAME
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

log_info "Activating BCT"
exec_sql "/ as sysdba" "
prompt Enable BCT on +DATAC1 ...
ALTER DATABASE ENABLE BLOCK CHANGE TRACKING USING FILE '+DATAC1';" "BCT On"


log_info "Checking db_name is in use"
CURRENT_DB_NAME=$(exec_sql "/ as sysdba" "select value from v\$parameter where name='db_name';")

CURRENT_DB_NAME=$(echo $CURRENT_DB_NAME | tr -d '\n')
if [[ ${CURRENT_DB_NAME,,} == ${OCI_TARGET_DB_NAME,,} ]]; then
        log_success "Database name has been changed"
else
        log_error "Database name was not changed. Exiting"
        exit 1
fi


DB_SRVCTL_LINES=$(srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME | wc -l)
DB_SRVCTL_OPEN=$(srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v | grep -c Open)

if [ $DB_SRVCTL_LINES -eq $DB_SRVCTL_OPEN ]; then
        log_success "Duplicate database OK. Don't forget to backup this new DB."
else
        log_error "Problem when duplicating the database. Exiting."
        exit 1
fi

}

needsUpgrade()
{
  #srvctl stop database -d $ORACLE_UNQNAME
  echo "Try to start the database (sqlplus)"
  rm -f /tmp/$$.log
  echo "  - Try to OPEN"
  exec_sql -no_error "/ as sysdba" "
startup mount ;
alter database open ;" > /tmp/$$.log 2>&1

  cat /tmp/$$.log
  if grep RESETLOGS /tmp/$$.log
  then
    rm -f /tmp/$$.log
    echo "  - Try to OPEN RESETLOGS"
    exec_sql -no_error "/ as sysdba" "alter database open resetlogs ;" > /tmp/$$.log 2>&1
  fi
  cat /tmp/$$.log
  if grep "database must be opened with UPGRADE option" /tmp/$$.log >/dev/null
  then
    rm -f /tmp/$$.log
    return 0
  fi
  rm -f /tmp/$$.log
  return 1
}

upgradeDB()
{
  srvctl stop database -d $ORACLE_UNQNAME
  message "Start database in UPGRADE MODE"
  exec_sql "/ as sysdba" "startup upgrade" || die "Unable to start in upgrade mode"
  message "Upgrading ...."
  dbupgrade
}

usage()
{
  echo " Usage : $(basename $0) -s <DB_NAME of source> -d <DB_NAME of target> 
                                -t <2019-12-25_13:31:40> -i <DBID of source> 
                                -M "pdb name mappigs"
                                [-p n] [-n(oprompt)] [-F(oreground)]

  Duplicate a database from a backup with upgrade if needed

  After a few verifications, the scrip will automatically re-launch itself in the background an 
  run unattended

  The first steps will guide you on configuration steps (copying the config files and wallets from
  the source.

  Parameters :

    -s sourceDB      : Source DBNAME
    -d destDB        : Target DBNAME
    -t time          : Point in time to recover
    -i id            : DB Id of the source
    -p degree        : Restore parallelism
    -M NamesMap      : PDBs rename map : "OLD1>NEW1;OLD2>NEW2;..."
    -n               : Don't ask questions
    -F               : Remain foreground

  "
  exit 1
}
############################################
############################################
############################################

OCI_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
OCI_SCRIPT_DIR=/admindb/dupdb/backup_oci/scripts
. $OCI_SCRIPT_DIR/utils.sh
PROMPT=true
GO_BACKGROUND=Y
REMAP_PDBS=""

while getopts 's:d:t:p:i:nFM:h' c
do
  case $c in
    s) OCI_SOURCE_DB_NAME=$OPTARG ;;
    d) OCI_TARGET_DB_NAME=$OPTARG ;;
    t) OCI_BKP_DATE=$OPTARG ;;
    n) PROMPT=false ;;
    p) OCI_RMAN_PARALLELISM=$OPTARG ;;
    i) OCI_DBID=$OPTARG ;;
    F) GO_BACKGROUND=N ;;
    M) REMAP_PDBS=$OPTARG ;;
    h|?) usage ;;
  esac
done

#
#   define LOG DIR and LOG FILE
#
#LOG_DIR=${OCI_BKP_LOG_DIR}/$OCI_TARGET_DB_NAME
export FORMATTED_DATE=${FORMATTED_DATE:-$(date +%Y-%m-%d_%H-%M-%S)}
export LOG_DIR=${LOG_DIR:-$(dirname $OCI_SCRIPT_DIR)/logs/$OCI_TARGET_DB_NAME}

mkdir -p $LOG_DIR 2>/dev/null && LOG_FILE=$LOG_DIR/duplicate_from_${OCI_SOURCE_DB_NAME}_to_${OCI_TARGET_DB_NAME}-${FORMATTED_DATE}.log || LOG_FILE=/dev/null 
LOGS_TO_KEEP=20

set -o pipefail
{
  startRun "Database duplication from $OCI_SOURCE_DB_NAME to $OCI_TARGET_DB_NAME at $OCI_BKP_DATE"

   echo "
Parameters :
==========

    - Source DATABASE    : $OCI_SOURCE_DB_NAME
    - Target DATABASE    : $OCI_TARGET_DB_NAME
    - Source DBID        : $OCI_DBID
    - Parallel           : $OCI_RMAN_PARALLELISM
    - PITR Date          : $OCI_BKP_DATE
    - PDBs renaming      : $REMAP_PDBS
   "


#  
#    Verify environment and try o get the spfile from backups, if this 
# step terminates sucessfully, the only know reason for the restore to fail is 
# the TNSNAMES configuration, but we cannot verify it at this stage
#
  startStep "Initial verifications"
  init
  endStep

  if  [ "$GO_BACKGROUND" = "Y" ]
  then
    #
    #     A soon as the prerequisites are verified, the scrit can be re-launched in batch 
    #
    echo
    echo "+===========================================================================+"
    echo "|       Main verifications have been made, and source DB has been dropped   |"
    echo "| The script will be re-leunched in background with the same parameters     |"
    echo "+===========================================================================+"
    echo
    echo "  LOG FILE will be :"
    echo "   $LOG_FILE"
    echo 
    echo "+===========================================================================+"
    #
    #     On exporte les variables afin qu'elles soient reprises dans le script
    #
    rm -f $LOG_FILE
    nohup $0 $* -n -F >/dev/null 2>&1 &
    pid=$!
    waitFor=30
    echo " Script launched ..... (pid=$pid) monitoring for ($waitFor) seconds"
    echo -n "  Monitoring of $pid --> "
    i=1
    while [ $i -le $waitFor ]
    do
      sleep 1
      if ps -p $pid >/dev/null
      then
        [ $(($i % 10)) -eq 0 ] && { echo -n "+" ; } || { echo -n "." ; }
      else
         echo "Process has stopped (probable error) "
         echo 
         echo "      --+--> End of the log file"
         tail -15 $LOG_FILE | sed -e "s;^;        | ;"
         echo "        +----------------------"

         die "Duplication if not successfully launched"
      fi
      i=$(($i + 1))
    done  
    echo
    echo
    echo "+===========================================================================+"
    echo "Database duplication has been launched in background"
    echo "+===========================================================================+"
    exit
  fi

#
#    Removes the database files from ASM
#
  startStep "Remove target database" 
  dropDatabase
  endStep


  startStep "SPFILE restore"

  spFileRestore || die "Error restoring the SPFILE

   Most frequent errors at this stage :
   - opc backup config incorrect in 
     $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora
   - Source OPC wallet not copied in $(dirname $OCI_SCRIPT_DIR)/opc_wallet/${OCI_SOURCE_DB_NAME}
   - Incorrect source DBID ($OCI_DBID)
   - Source TDE wallet has not been copied in /var/opt/oracle/dbaas_acfs/$OCI_TARGET_DB_NAME
   INFO : Target wallet location :
   $(cat $TNS_ADMIN/sqlnet.ora | sed -e "/ENCRYPTION_WALLET_LOCATION/ p" \
                                  -e "1, /ENCRYPTION_WALLET_LOCATION/ d" \
                                  -e "/^ *$/,$ d")
"
  endStep


  startStep "Restore the controlfile"
  controlFileRestore  || die "Control file not restored, aborting"
  endStep

#
#     RMAN restore, this step supposes that the database is accessible via the TNS Alias
#
  startStep "Database restore"
  rmanConfig || die "RMAN configutation failed"
  databaseRestoreAndRecover || die "Database restoration failed"
  endStep


#
#    Test for upgrade, we rie to open the database and, if it clains an upgrade we start it
# in upgrade mode and then launch dbupgrade wich will upgrade container an all PDBs to the correct version
#
#    lines betwen if and fi are specific to duplication with upgrade
#
  UPGRADED=N
  if needsUpgrade
  then
    startStep "Upgrade the database"
    upgradeDB
    UPGRADED=Y
    endStep
  fi
  startStep "Post-restore Tasks"
  postRestore
  endStep

#
#   Custom tasks, depending on the application, put all non standard stuff in the 
# customPostUpgrade function
#
  if [ "$UPGRADED" = "Y" ]
  then
    customPostUpgrade
  fi
  endRun
} 2>&1 | tee $LOG_FILE

#
#     Remove special charcaters from the log file
#
cp -p $LOG_FILE $LOG_FILE.tmp
sed -e "s;\x1b\[34m;;g" \
    -e "s;\x1b\[0\;10m;;g" \
    -e "s;\x1b\[36m;;g" \
    -e "s;\x1b\[31m;;g" \
    $LOG_FILE.tmp > $LOG_FILE
rm -f $LOG_FILE.tmp

#
#      keep only N most recent logs
#
echo
echo "Cleaning logs"
echo "============="
echo
i=0
ls -1t $LOG_DIR/* | while read f
do
  i=$(($i + 1))
  [ $i -gt $LOGS_TO_KEEP ] && { echo "  - Deleting $f " ; rm -f $f ; }
done

