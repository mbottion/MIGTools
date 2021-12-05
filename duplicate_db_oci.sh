#!/bin/bash
VERSION=2.0
# Description : script to duplicate from an oracle OCI bucket to an existing enveloppe
# Author : Amaury FRANCOIS <amaury.francois@oracle.com>
# Logging added : Michel BOTTIONE

renamePdbs()
{
  startStep "Renaming PDBS if needed"
  pdbs=$(exec_sql "/ as sysdba" "select name from v\$pdbs where name != 'PDB\$SEED';") || die "Unable to get PDBS list $pdbs"
  for pdb in $pdbs
  do
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
alter session set container=$old ;

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
  done
  endStep
}
customPostUpgrade()
{
  if [ -f $OCI_SCRIPT_DIR/migrateDB.sh ]
  then
    . $OCI_SCRIPT_DIR/migrateDB.sh
  else
    echo "
===================================================================================
    No script migrateDB has been found in :
  $OCI_SCRIPT_DIR
  no migration operation will be performed.
===================================================================================
  "
  fi
}
# =========================================================================================
#
#      Perfoms minimal validations, after this procedure, the restore should 
# run normally, except if there is a connection issue which cannot easily tested here
# since the database may not be up at this satge
#
# =========================================================================================
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
  if [ "$RESTART_POST_UPGRADE" = "N" ]
  then
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

    log_success "OPC Backups configuration checked"


    #Check if credentials are presents for this database
    message "Credentials in wallet verification" 
    check_cred $OCI_TARGET_DB_NAME
    if [ $? -ne 0 ]; then
      die " Error when checking credentials presence in wallet for this database. Exiting.

Command :
-------

  HINT : After running the command enter the SYS password
         of the target DB ($OCI_TARGET_DB_NAME), twice.

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

    message "Check that the database is NOT running"
    if [ "$(srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME | grep -i running  | grep -vi "not running")" != "" ]
    then
      log_info "  - Shutting down tha database (abort)"
      srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME -o abort && log_success "Database stopped" || log_error "Unable to stop the database"
    fi

    message "Basic RMAN Check (restore the spfile to fake location)"
    echo "To check : 
      - OPC Configuration
      - TDE Configuration
     "

    TEMP_PFILE=$(mktemp)
    rman target /  << EOF | tee /tmp/$$.log
set echo on;
startup nomount;
set DBID=$OCI_DBID
RUN {
ALLOCATE CHANNEL ch1 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=/$OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora)';
RESTORE SPFILE TO PFILE '$TEMP_PFILE' FROM AUTOBACKUP ;
}
EOF
    status=$?
    rm -f $TEMP_FILE
    if [ $status -ne 0 ]
    then
      echo ""
      echo "==================================================="
      echo "An error occured, trying to find the root cause ..."
      echo "==================================================="
      echo "TNS_ADMIN=$TNS_ADMIN"
      echo ""

      if grep "cannot use command when connected to a mounted" /tmp/$$.log >/dev/null
      then
        echo "Target database is mounted, please stop it :
      
    srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME
    
      "
      fi
      if grep "no AUTOBACKUP found" /tmp/$$.log >/dev/null
      then
        echo "Ensure that the provided DBID ($OCI_DBID) is correct"
        echo "   - If the source database still exists, run the folowing"
        echo "     commands on the source server"
        echo "
===================================================================================

. \$HOME/${OCI_SOURCE_DB_NAME}.env
sqlplus -s / as sysdba <<%%
select 'Db Name : ' || name || ' DBID --> ' || dbid from v\\\$database ;
%%

===================================================================================

      "
      fi
    
      if grep "unable to open Oracle Database Backup Service" /tmp/$$.log >/dev/null || grep OPC_WALLET /tmp/$$.log >/dev/null
      then
        echo "There is a problem with OPC backups configuration"
        echo "   - Check $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora"
        echo "   - Ensure that the Source OPC Wallet has been copied into $OCI_BKP_ROOT_DIR/opc_wallet/${OCI_SOURCE_DB_NAME}" 
        echo "

    HINT : The name of the parameter file can be found on the machine hosting
           the source database ($OCI_SOURCE_DB_NAME) by running:

. \$HOME/${OCI_SOURCE_DB_NAME}.env
rman target / <<%% | grep \"OPC_PFILE=\" | sed -e \"s;^.*OPC_PFILE=;;\" -e \"s;).*$;;\"
show all ;
%%
    
          Once the file name found, open it to get the OPC wallet location

          1) copy the parameter file in $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora
          2) copy the whole content of the wallet dir to $OCI_BKP_ROOT_DIR/opc_wallet/${OCI_SOURCE_DB_NAME}
         "
      fi

      if grep "ORA-28759 occurred during wallet operation" /tmp/$$.log > /dev/null
      then
        echo "There is a problem reading OPC backups"
        echo "   - OPC Wallet has not been copied into $OCI_BKP_ROOT_DIR/opc_wallet/${OCI_SOURCE_DB_NAME}

    HINT : remove $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora, run the command again
           and follow the hints
" 
      fi

      if grep "HTTP response error" /tmp/$$.log > /dev/null
      then
        echo "Unable to access the backup bucket"
        echo "   - Check /$OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora

    HINT : remove $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora, run the command again
           and follow the hints
"
      fi

      if grep "unable to decrypt backup" /tmp/$$.log > /dev/null
      then
        echo "Unable du decrypt the backup"
        echo
        echo "   - Has the the wallet been copied from the source DB to the target DB?"
        echo
        echo "   - Target DB TDE configuration : "
        . $HOME/$OCI_TARGET_DB_NAME.env
        ld=$(cat $TNS_ADMIN/sqlnet.ora | sed -e "/ENCRYPTION_WALLET_LOCATION/ p" \
                                      -e "1, /ENCRYPTION_WALLET_LOCATION/ d" \
                                      -e "/^ *$/,$ d" \
                            | tr -d '\n' | sed -e "s;^[^/]*;;" -e "s;).*$;;")
        echo "Local TDE dir : $ld"
        echo "

    HINT : On the machine hosting the source DB (${OCI_SOURCE_DB_NAME}), execute
           (if the source DB is still available)

===================================================================================

. \$HOME/${OCI_SOURCE_DB_NAME}.env
wd=\$(cat \$TNS_ADMIN/sqlnet.ora | sed -e \"/ENCRYPTION_WALLET_LOCATION/ p\"        \\
                                 -e \"1, /ENCRYPTION_WALLET_LOCATION/ d\"           \\
                                 -e \"/^ *$/,$ d\"                                  \\
                          | tr -d '\n' | sed -e \"s;^[^/]*;;\" -e \"s;).*$;;\")    ;\\
                          echo -n \"TDE WALLET Dir     : \$wd\" ; test -d \$wd && echo \" OK\" || echo \" NOT exists\"  ; \\
echo ; \\
echo \"Tar command (exemple) : 
 cd \$wd && tar cvzf /tmp/tde_$OCI_SOURCE_DB_NAME.tgz * ; cd - \";\\
echo ; \\
echo \"copy the tar file on the source and place files in the required folders\" 

===================================================================================

   mkdir -p $ld
   cd $ld
   tar xvzf /tmp/tde_$OCI_SOURCE_DB_NAME.tgz
   cd -
   
   "
      fi

      echo
      rm -f /tmp/$$.log
      log_error "ERROR when checking RMAN"
      die "Check TDE and RMAN"
    fi
    log_success "RMAN and TDE configuration checked"

    rm -f /tmp/$$.log
    message "Check RMAN SQL*net connectivity"

    TEMP_PFILE=$(mktemp)
    rman target /@$OCI_TARGET_DB_NAME << EOF | tee /tmp/$$.log
select * from dual ;
EOF
    status=$?
    rm -f $TEMP_FILE
    sn=$(exec_sql "/ as sysdba" "select value from v\$parameter where name = 'service_names';")
    if [ $status -ne 0 -a "$(grep "TNS:listener: all appropriate instances are blocking new connections" /tmp/$$.log)" = "" \
                       -a "$sn" != "DUMMY" ]
    then
      echo ""
      echo "==================================================="
      echo "An error occured, trying to find the root cause ..."
      echo "==================================================="
      echo "TNS_ADMIN=$TNS_ADMIN"
      echo "service_names=$sn"
      echo "
    
        RMAN was not able to connect to the database, check
    that database name, host name, port and service name are correct in 
    $TNS_ADMIN/tnsnames.ora
    "
   
      die "RMAN is not able to connect to the database"
    fi  
    log_success "RMAN may be able to connect to the database"
    exec_sql "/ as sysdba" "Shutdown immediate ; " "Shutdown" || exec_sql "/ as sysdba" "Shutdown abort" "Force shutdown"
    message "We can go background if required now ...."
  fi
  return 0
}

# =========================================================================================
#
#      Remove database files from ASM
#
# =========================================================================================
dropDatabase() 
{
  [[ $PROMPT == "true" ]] && ask_confirm "This command will stop and drop $OCI_TARGET_DB_NAME"
  message "Stopping and Dropping the database"
  log_info "Getting database status on all nodes"
  srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

  log_info "Stopping database on all nodes"
  srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME -o abort > /dev/null 2>&1
  exec_sql "/ as sysdba" "Shutdown abort ; "

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

# =========================================================================================
#
#      Restore teh spfile and modify it to fit the new database 
#
# =========================================================================================
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
RESTORE SPFILE TO PFILE '$TEMP_PFILE' FROM AUTOBACKUP ;
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
  sed -i "/local_listener/d" $TEMP_PFILE #MBO ==> Reste des anciens ...
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

  log_info "Align DB_DOMAIN"

  echo "   - Domain (srvctl) : $SAVED_DOMAIN"
  if [ "$SAVED_DOMAIN" != "" ]
  then
    echo "db_domain=$SAVED_DOMAIN" >> $TEMP_PFILE
    srvctl modify database -d $OCI_BKP_DB_UNIQUE_NAME -domain $SAVED_DOMAIN || die "Unable to set DB DOMAIN"
  fi

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

# =========================================================================================
#
#      Retore the control file, be careful, it contains references to old redo-logs
#
# =========================================================================================
controlFileRestore()
{
  message "Control file restore"
  log_info "Restoring the controlfile"
  rman target / << EOF
set echo on;
set DBID=$OCI_DBID
RUN {
ALLOCATE CHANNEL ch1 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora)';
RESTORE CONTROLFILE FROM AUTOBACKUP ;
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

# =========================================================================================
#
#      Initial RMAN configuration
#
# =========================================================================================
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
# =========================================================================================
#
#       Restire the database and recover until the date chosen.
#
# =========================================================================================
databaseRestoreAndRecover()
{
  log_info "Getting list of tempfiles"
  SWITCH_TEMPFILE_CLAUSE=$(exec_sql "/ as sysdba" "
set feed off head off lines 200 pages 300
select 'set newname for tempfile '||file#||' to new;' from v\$tempfile;")

  cat <<%%
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
%%

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
  exec_sql "/ as sysdba" "ALTER DATABASE DISABLE BLOCK CHANGE TRACKING;" "Disable BCT"

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
# =========================================================================================
#
#       Recreates the controlfile and open resetlogs or resetlogs upgrade if 
#  the database must be upgraded. Can be improved by genarating a control-file creation
#  script that would be more precise instead of modifying the one backedup.
#
# =========================================================================================
postRestore_CreateCtr()
{
if [ "$1" = "Y" ]
then
  sed -i "s;OPEN RESETLOGS;OPEN RESETLOGS UPGRADE;" ${TRACE_CTL_FILE}
  sed -i "s;PLUGGABLE DATABASE ALL OPEN;PLUGGABLE DATABASE ALL OPEN UPGRADE;" ${TRACE_CTL_FILE}
fi

log_info "Stopping the database"
srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME

log_info "Database status"
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

log_info "Setting environment using env file"
. ~/${OCI_TARGET_DB_NAME}.env

log_info "Recreating the control file"
exec_sql "/ as sysdba" "@${TRACE_CTL_FILE}" "Run ${TRACE_CTL_FILE} UPGRADE=$1" || die "Error Recreating the controlfile"
}
# =========================================================================================
#
#       Sometimes, OEM leaves AQ subscribers that prevent the database to stop rapidly
#  this block will remove the subscribers and the corresponding AQ Agents.
#
# =========================================================================================
postRestore_RemoveSubsbcribers()
{
log_info "Removing AQ Subscribers" 

exec_sql "/ as sysdba" "
set serveroutput on
DECLARE
   q_subscribers dbms_aqadm.aq\$_subscriber_list_t;
BEGIN 
  q_subscribers := dbms_aqadm.queue_subscribers('ALERT_QUE');
  dbms_output.put_line ('Removing obsolete subscriptions to ALERT_QUE') ;
  dbms_output.put_line ('============================================') ;
  dbms_output.put_line ('Nb : ' || q_subscribers.LAST);
  FOR sub_i IN nvl(q_subscribers.FIRST,0) .. nvl(q_subscribers.LAST,0)
  LOOP
    if (q_subscribers(sub_i).name != 'HAE_SUB') 
    then
      dbms_output.put_line('.  Agent : '|| q_subscribers(sub_i).name);
      dbms_output.put_line('.    Remove subscriber ...');
      dbms_aqadm.remove_subscriber( queue_name => 'SYS.ALERT_QUE', subscriber => q_subscribers(sub_i));
      dbms_output.put_line('.    Remove agent ...');
      begin
        dbms_aqadm.drop_aq_agent(q_subscribers(sub_i).name);
      exception when others then 
         dbms_output.put_line('.    ==> ' || sqlerrm );
      end ;
    end if ;
  END LOOP;
  q_subscribers := dbms_aqadm.queue_subscribers('PDB_MON_EVENT_QUEUE\$');
  dbms_output.put_line ('Removing obsolete subscriptions to PDB_MON_EVENT_QUEUE\$') ;
  dbms_output.put_line ('=======================================================') ;
  dbms_output.put_line ('Nb : ' || q_subscribers.LAST);
  FOR sub_i IN nvl(q_subscribers.FIRST,0) .. nvl(q_subscribers.LAST,0)
  LOOP
    if (q_subscribers(sub_i).name != 'HAE_SUB') 
    then
      dbms_output.put_line('.  Agent : '|| q_subscribers(sub_i).name);
      dbms_output.put_line('.    Remove subscriber ...');
      dbms_aqadm.remove_subscriber( queue_name => 'SYS.PDB_MON_EVENT_QUEUE\$', subscriber => q_subscribers(sub_i));
      dbms_output.put_line('.    Remove agent ...');
      begin
        dbms_aqadm.drop_aq_agent(q_subscribers(sub_i).name);
      exception when others then 
         dbms_output.put_line('.    ==> ' || sqlerrm );
      end ;
    end if ;
  END LOOP;
exception when no_data_found then null ;
END; 
/
"
}
# =========================================================================================
#
#       Finally, change the DBID and the DB NAME
#
# =========================================================================================
postRestore_ChangeDBName()
{
  log_info "Starting in mount exclusive"
  exec_sql "/ as sysdba" "startup mount exclusive;" "DB exclusive" || die "Unable to mount in exclusive mode"

  log_info "Changing the db name using nid"
  #$OCI_SCRIPT_DIR/change_db_name.exp $ORACLE_HOME $OCI_TARGET_DB_NAME
  echo Y | $ORACLE_HOME/bin/nid target=sys/dummy dbname=$OCI_TARGET_DB_NAME 
  if [ $? -ne 0 ] 
  then
    echo "  - Error when changing the DB NAME, try one more time"
    exec_sql -no_error "/ as sysdba" "
whenever sqlerror continue
prompt shutdown abort
shutdown abort
prompt startup/shutdown
startup
shutdown immediate
"
    log_info "Starting in mount exclusive"
    exec_sql "/ as sysdba" "startup mount exclusive;" "DB exclusive" || die "Unable to mount in exclusive mode"
    log_info "Changing the db name using nid"
    echo Y | $ORACLE_HOME/bin/nid target=sys/dummy dbname=$OCI_TARGET_DB_NAME 
    [ $? -ne 0 ] && die "Error Changing DB NAME"
  fi

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

}
# =========================================================================================
#
#       Last restart after upgrade, and before custom upgrade if needed
#
# =========================================================================================
postRestore_Restart()
{
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
# =========================================================================================
#
#       Post restore when the DB has not been upgraded
#
# =========================================================================================
postRestore()
{

  postRestore_CreateCtr

  log_info "Checking database state"
  DB_STATE=$(exec_sql "/ as sysdba" "select status from gv\$instance;")

  if [[ $DB_STATE =~ "OPEN" ]]; then
    log_success "Database started in OPEN mode "
  else
    log_error "Unable to restart the database in OPEN mode. Exiting"
    exit 1
  fi

  rm ${TRACE_CTL_FILE}

  postRestore_RemoveSubsbcribers

  log_info "Stopping the database"
  srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME

  log_info "Database status"
  srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

  postRestore_ChangeDBName


  postRestore_Restart
}

# =========================================================================================
#
#       Test if the database needs to be upgraded (we test the value of the compatible parameter)
#
# =========================================================================================
needsUpgrade()
{
  [ "$RESTART_POST_UPGRADE" = "Y" ] && return 0
  echo
  echo "Check if database needs to be upgraded (based on compatible parameter)"
  echo
  dbVersion=$(exec_sql "/ as sysdba" "select regexp_replace(value,'([^0-9]*)([0-9]*).*','\2') from v\$parameter where name = 'compatible' ;")
  homeVersion=$(exec_sql "/ as sysdba" "select regexp_replace(banner,'([^0-9]*)([0-9]*).*','\2') from v\$version ;")
  
  echo "    - Database version    : $dbVersion"
  echo "    - ORACLE HOME version : $homeVersion"
  echo
  
  if [ $homeVersion -gt $dbVersion ]
  then
    return 0
  fi
  return 1
}

# =========================================================================================
#
#       Upgrade the database to the version of the ORACLE HOME
#
# =========================================================================================
upgradeDB()
{
  srvctl stop database -d $ORACLE_UNQNAME
  message "Start database in UPGRADE MODE"
  exec_sql "/ as sysdba" "startup upgrade" || die "Unable to start in upgrade mode"
  message "Upgrading ...."
  dbupgrade
  if [ $? -ne 0 ]
  then
    die "DATABASE upgrade failed, you can perform the upgrade manually and restart the 
script again, in that case, just add the  -R option to the command line"
  fi
}

usage()
{
  echo " Usage : $(basename $0) -s <DB_NAME of source> -d <DB_NAME of target> 
                                -t <2019-12-25_13:31:40> -i <DBID of source> 
                                -M \"pdb name mappigs\" -R
                                [-p n] [-n(oprompt)] [-F(oreground)]

  Version : $VERSION
  
  Duplicate a database from a backup with upgrade if needed

  After a few verifications, the script will automatically re-launch itself in the background an 
  run unattended (except if -F is specified)

  The first steps will guide you on configuration steps (copying the config files and wallets from
  the source.

  If the duplicated database is not in the same version than the target ORACLE HOME, an 
  upgrade will be launched. As part of the upgrade, you can modify the customPostUpgrade()
  function in the script to perform specific actions.

  The -M parameter allows you to rename all or some PDBs once they have been duplicated.

  Parameters :

    -s sourceDB      : Source DBNAME
    -d destDB        : Target DBNAME
    -t time          : Point in time to recover
    -i id            : DB Id of the source
    -p degree        : Restore parallelism
    -M NamesMap      : PDBs rename map : \"OLD1>NEW1;OLD2>NEW2;...\"
    -R               : Restart the processing after a manual upgrade
    -n               : Don't ask questions
    -F               : Remain foreground

  "
  exit 1
}
############################################
############################################
############################################

OCI_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
#OCI_SCRIPT_DIR=/admindb/dupdb/backup_oci/scripts
. $OCI_SCRIPT_DIR/utils.sh
PROMPT=true
GO_BACKGROUND=Y
REMAP_PDBS=""
RESTART_POST_UPGRADE=N

while getopts 's:d:t:p:i:nFM:Rh' c
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
    R) RESTART_POST_UPGRADE=Y ;;
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

  #
  #     The configured domain is sometimes lost on failed executions
  # we save it to reposition it later
  #
  . $HOME/$OCI_TARGET_DB_NAME.env || die "unable to set target env" 
  if [ "$SAVED_DOMAIN" = "" ]
  then
   export SAVED_DOMAIN=$(srvctl config database -d $ORACLE_UNQNAME  | grep -i domain | cut -f2 -d: | sed -e "s; ;;g")
  fi

   echo "
Parameters :
==========

    - Source DATABASE      : $OCI_SOURCE_DB_NAME
    - Target DATABASE      : $OCI_TARGET_DB_NAME
    - Target DB DOMAIN     : $SAVED_DOMAIN
    - Source DBID          : $OCI_DBID
    - Parallel             : $OCI_RMAN_PARALLELISM
    - PITR Date            : $OCI_BKP_DATE
    - PDBs renaming        : $REMAP_PDBS
    - RESTART_POST_UPGRADE : $RESTART_POST_UPGRADE
   "
  #  
  #    Verify environment and try o get the spfile from backups, if this 
  # step terminates sucessfully, the only know reason for the restore to fail is 
  # the TNSNAMES configuration, but we cannot verify it at this stage 
  #

  startStep "Initial verifications"
  init
  endStep

  if [ "$RESTART_POST_UPGRADE" = "N" ]
  then
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
  fi
  UPGRADED=N
  if needsUpgrade
  then
    if [ "$RESTART_POST_UPGRADE" = "N" ]
    then
      startStep "Post-restore Tasks (PRE-UPGRADE)"
      postRestore_CreateCtr Y
      endStep
      startStep "Upgrade the database"
      upgradeDB
    else
      startStep "Finish the process after a manual upgrade"
    fi
    postRestore_RemoveSubsbcribers 
    UPGRADED=Y
    endStep
    exec_sql "/ as sysdba" "shutdown abort" "Shutdown abort"
    startStep "Post-restore Tasks (POST-UPGRADE)"
    postRestore_ChangeDBName 
    postRestore_Restart
    endStep
  else
    startStep "Post-restore Tasks (NO UPGRADE)"
    postRestore 
    endStep
  fi


  renamePdbs
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
sed -e "s;\x1b\[34m;;g" \
    -e "s;\x1b\[0\;10m;;g" \
    -e "s;\x1b(B\x1b\[m;;g" \
    -e "s;\x1b\[36m;;g" \
    -e "s;\x1b\[31m;;g" \
    $LOG_FILE > $LOG_FILE.tmp && cp -p $LOG_FILE.tmp $LOG_FILE
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

