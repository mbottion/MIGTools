VERSION=0.2
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
#   Appelé par l'option -T, permet de tester des parties de script
#
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
testUnit()
{
  startStep "Test de fonctionnalites"
  endStep
}
finalisationDG()
{

  startStep "Finalisation de la configuration DATAGUARD"

  exec_sql -verbose "/ as sysdba" "
set serveroutput on
begin   
  dbms_output.put_line('Clearing redo log groups');   
  for log_cur in ( select group# group_no from v\$log )   
  loop
    dbms_output.put_line('-    Groupe ' || log_cur.group_no) ;     
    execute immediate 'alter database clear logfile group '||log_cur.group_no;   
  end loop; 
end;
/
" "  - Nettoyage des REDO-LOGS"

  exec_sql -verbose "/ as sysdba" "
set serveroutput on
begin   
  dbms_output.put_line('Clearing stand-by redo log groups');   
  for log_cur in ( select group# group_no from v\$standby_log )   
  loop
    dbms_output.put_line('-    Groupe ' || log_cur.group_no) ;     
    execute immediate 'alter database clear logfile group '||log_cur.group_no;   
  end loop; 
end;
/
" "  - Nettoyage des STANDBY REDO-LOGS"

  echo "  - Dataguard Broker (Stand By : $stbyDbUniqueName)"
  exec_sql -verbose "/ as sysdba" \
                    "alter system set dg_broker_start=false SCOPE=BOTH SID='*';" \
                    "    - Arret broker"
  exec_sql -verbose "/ as sysdba" \
                    "alter system set dg_broker_config_file1='+DATAC1/$stbyDbUniqueName/DG/dr${stbyDbName}_1.dat' SCOPE=BOTH SID='*';" \
                    "    - Config Broker #1"
  exec_sql -verbose "/ as sysdba" \
                    "alter system set dg_broker_config_file2='+DATAC1/$stbyDbUniqueName/DG/dr${stbyDbName}_2.dat' SCOPE=BOTH SID='*' ;" \
                    "    - Config Broker #2"
  exec_sql -verbose "/ as sysdba" \
                    "alter system set dg_broker_start=true SCOPE=BOTH SID='*';" \
                    "    - Lancement broker"
  exec_sql -verbose "/ as sysdba" \
                    "alter database set standby database to maximize availability;" \
                    "    - Max availability"
  exec_sql -verbose "/ as sysdba" \
                    "alter system set DB_BLOCK_CHECKING=FALSE scope=both sid='*'; " \
                    "    - DB Block Checking = FALSE"

  echo "  - Dataguard Broker (Primary : $primDbUniqueName)"
  exec_sql -verbose "sys/Wel_Come_12@$primDbUniqueName as sysdba" \
                    "alter system set dg_broker_start=false SCOPE=BOTH SID='*';" \
                    "    - Arret broker"
  exec_sql -verbose "sys/Wel_Come_12@$primDbUniqueName as sysdba" \
                    "alter system set dg_broker_config_file1='+DATAC1/$primDbUniqueName/DG/dr${primDbName}_1.dat' SCOPE=BOTH SID='*';" \
                    "    - Config Broker #1"
  exec_sql -verbose "sys/Wel_Come_12@$primDbUniqueName as sysdba" \
                    "alter system set dg_broker_config_file2='+DATAC1/$primDbUniqueName/DG/dr${primDbName}_2.dat' SCOPE=BOTH SID='*' ;" \
                    "    - Config Broker #2"
  exec_sql -verbose "sys/Wel_Come_12@$primDbUniqueName as sysdba" \
                    "alter system set dg_broker_start=true SCOPE=BOTH SID='*';" \
                    "    - Lancement broker"
 # exec_sql -verbose "sys/Wel_Come_12@$primDbUniqueName as sysdba" \
 #                   "alter database set standby database to maximize availability;" \
 #                   "    - Max availability"
  exec_sql -verbose "sys/Wel_Come_12@$primDbUniqueName as sysdba" \
                    "alter system set DB_BLOCK_CHECKING=MEDIUM scope=both sid='*'; " \
                    "    - DB Block Checking = MEDIUM"

  echo "  - Mise en place de la configuration DATAGUARD Broker"
  sleep 10
  i=1
  while [ $i -le 10 ]
  do
    exec_dgmgrl "create configuration FSC as primary database is '$primDbUniqueName' connect identifier is '$primDbUniqueName'" \
                "Creation de la configuration (essai : $i/10)"
    if  [ $? -ne 0 ]
    then
      [ $i -lt 10 ] && { echo "    - Attente 10s" ; sleep 10 ; } || die "Impossible de creer la configuration" 
    else
      i=11
    fi
    i=$(($i + 1))
  done

  exec_dgmgrl "add database '$stbyDbUniqueName' as connect identifier is '$stbyDbUniqueName' maintained as physical" \
              "Ajout de la base stand-by" || die "Erreur DGMGRL"
  exec_dgmgrl "edit configuration set protection mode as MaxPerformance" \
              "Mode de protection" || die "Erreur DGMGRL"
  exec_dgmgrl "edit database '$primDbUniqueName' set property NetTimeout=30" \
              "NetTimeout (Primary)" || die "Erreur DGMGRL"
  exec_dgmgrl "edit database '$stbyDbUniqueName' set property LogXptMode='ASYNC'" \
              "LoXptMode (Stand-by)" || die "Erreur DGMGRL"
  exec_dgmgrl "edit database '$stbyDbUniqueName' set property NetTimeout=30" \
              "NetTimetout (STand-by)" || die "Erreur DGMGRL"
  exec_dgmgrl "edit database '$stbyDbUniqueName' set property FastStartFailoverTarget='$primDbUniqueName'" \
              "Target (Primary)" || die "Erreur DGMGRL"
  exec_dgmgrl "edit database '$primDbUniqueName' set property FastStartFailoverTarget='$stbyDbUniqueName'" \
              "Target (Stand-by)" || die "Erreur DGMGRL"
  exec_dgmgrl "edit database '$primDbUniqueName' set property LogXptMode='ASYNC'" \
              "LoXptMode (Primary)" || die "Erreur DGMGRL"
  exec_dgmgrl "edit instance '${primDbName}1' on database '$primDbUniqueName' set property StaticConnectIdentifier='${primDbUniqueName}1_DGMGRL'" \
              "Connection I1 (Primaire)" || die "Erreur DGMGRL"
  exec_dgmgrl "edit instance '${primDbName}2' on database '$primDbUniqueName' set property StaticConnectIdentifier='${primDbUniqueName}2_DGMGRL'" \
              "Connection I2 (Primaire)" || die "Erreur DGMGRL"
  exec_dgmgrl "edit instance '${stbyDbName}1' on database '$stbyDbUniqueName' set property StaticConnectIdentifier='${stbyDbUniqueName}1_DGMGRL'" \
              "Connection I1 (Stand-BY)" || die "Erreur DGMGRL"
  exec_dgmgrl "edit instance '${stbyDbName}2' on database '$stbyDbUniqueName' set property StaticConnectIdentifier='${stbyDbUniqueName}2_DGMGRL'" \
              "Connection I2 (Stand-BY)" || die "Erreur DGMGRL"
  exec_dgmgrl "enable configuration" \
              "enable configuration" || die "Erreur DGMGRL"

  endStep
}
exec_dgmgrl()
{
  local cmd=$1
  local lib=$2
  printf "%-75s : " "      - $lib"
  dgmgrl -silent sys/Wel_Come_12@$primDbUniqueName "$cmd" > $$.tmp 2>&1 \
    && { echo "OK" ; rm -f $$.tmp ; return 0 ; } \
    || { echo "ERREUR" ; cat $$.tmp ; rm -f $$.tmp ; return 1 ; }
}

duplicateDBForStandBY()
{
  startStep "Preparation de la base"


  tnsAliasesForDG $stbyDbUniqueName $hostStandBy  $portStandBy  $serviceStandBy  $domaineStandBy \
                  $primDbUniqueName $hostPrimaire $portPrimaire $servicePrimaire $domainePrimaire 

  echo "  - Recopie TNSNAMES sur autre noeud"
  otherNode=$(srvctl status database -d $ORACLE_UNQNAME | grep -v $(hostname -s) | sed -e "s;^.*on node ;;")
  printf "%-75s : " "    - Copie sur $otherNode"
  scp -o StrictHostKeyChecking=no $TNS_ADMIN/tnsnames.ora ${otherNode}:$TNS_ADMIN \
    && echo "Ok" \
    || die "Impossible de copie le TNSNAMES sur $otherNode"
  endStep

  startStep "Duplication de la base de donnees"
  echo
  printf "%-75s : " "    - Lancement en NO MOUNT pour restauration du control file"
  srvctl start database -d $stbyDbUniqueName -o nomount >$$.tmp 2>&1 \
    && { echo OK ; rm -f $$.tmp ; } \
    || { echo ERREUR ; cat $$.tmp ; rm -f $$.tmp ; die "Impossible de lancer en NOMOUT" ; }

  printf "%-75s : " "      - Restoration du control file"
  rman target / >$$.tmp 2>&1 <<%%
run { restore standby controlfile from service '$primDbUniqueName' ; }
%%
  [ $? -eq 0 ] && { echo OK ; rm -f $$.tmp ; } \
               || { echo ERREUR ; cat $$.tmp ; rm -f $$.tmp ; die "Erreur de restoration du control file" ; }
  exec_sql "/ as sysdba" "
alter system set log_file_name_convert=
       '+DATAC1/$primDbUniqueName','+DATAC1/$stbyDbUniqueName'
      ,'+RECOC1/$primDbUniqueName','+RECOC1/$stbyDbUniqueName' scope=spfile ;" "    - log_file_name_convert" \
      || die "Impossible de positionner log_file_name_convert"
  printf "%-75s : " "      - Arret de la base"
  srvctl stop database -d $stbyDbUniqueName  >$$.tmp 2>&1 \
  && { echo OK ; rm -f $$.tmp ; } \
  || { echo ERREUR ; cat $$.tmp ; rm -f $$.tmp ; die "Impossible de stopper la base" ; }
  
  echo
  printf "%-75s : " "    - Lancement en MOUNT pour restauration"
  srvctl start database -d $stbyDbUniqueName -o mount >$$.tmp 2>&1 \
    && { echo OK ; rm -f $$.tmp ; } \
    || { echo ERREUR ; cat $$.tmp ; rm -f $$.tmp ; die "Impossible de lancer en MOUT" ; }

  echo
  LOG_TMP=$LOG_DIR/restau_${primDbName}_$DAT.log
  echo "     Note : La restauration peut être suivie dans : "
  echo $LOG_TMP
  printf "%-75s : " "      - Restoration de la base"
  rman target sys/Wel_Come_12 >$LOG_TMP 2>&1 <<%%
run { 
allocate channel C1 type disk  ;
allocate channel C2 type disk  ;
allocate channel C3 type disk  ;
allocate channel C4 type disk  ;
allocate channel C5 type disk  ;
allocate channel C6 type disk  ;
allocate channel C7 type disk  ;
allocate channel C8 type disk  ;
restore  database from service '$primDbUniqueName' section size 64G; 
}
%%
  [ $? -eq 0 ] && { echo OK ; cat $LOG_TMP ; rm -f $LOG_TMP; } \
               || { echo ERREUR ; cat $LOG_TMP  ; rm -f $Log_TMP; die "Erreur de restauration de la base" ; }

  printf "%-75s : " "      - Recover de la base"
  rman target sys/Wel_Come_12 >$LOG_TMP 2>&1 <<%%
run { 
allocate channel C1 type disk  ;
allocate channel C2 type disk  ;
allocate channel C3 type disk  ;
allocate channel C4 type disk  ;
allocate channel C5 type disk  ;
allocate channel C6 type disk  ;
allocate channel C7 type disk  ;
allocate channel C8 type disk  ;
recover  database from service '$primDbUniqueName' section size 64G; 
}
%%
  [ $? -eq 0 ] && { echo OK ; cat $LOG_TMP ; rm -f $LOG_TMP; } \
               || { echo ERREUR ; cat $LOG_TMP  ; rm -f $Log_TMP; die "Erreur de Recover de la base" ; }

  endStep
  echo "  - Attente 30 secondes"
  sleep 30
  finalisationDG
}
createOnPrimary()
{
  tmpOut=/tmp/$$.tmp
  echo "  - Operations sur la base $primDbName cote PRIMARY"
  echo
  echo "    Une fois ces operations realisees, il faudra relancer"
  echo "    ce script sur le cluster de secours avec les options"
  echo "    fournies"
  echo

  printf "%-75s : " "  - Test acces base Primaire (SCAN)"
  tnsping $tnsPrimaire >/dev/null 2>&1 && echo "Ok" || { echo "ERREUR" ; die "TNS de la base primaire inaccessible" ; }
  printf "%-75s : " "  - Test acces base Stand-By (SCAN)"
  tnsping $tnsStandBy >/dev/null 2>&1 && echo "Ok" || { echo "ERREUR" ; die "TNS de la base primaire inaccessible" ; }

  printf "%-75s : " "  - Recuperation GRID_HOME"
  gridHome=$(grep "^+ASM1:" /etc/oratab | cut -f2 -d":")
  [ "$gridHome" = "" ] &&  { echo "Impossible" ; die "Impossible de determiner GRID_HOME" ; } || echo "OK ($gridHome)"
  
  . oraenv <<< +ASM1 >/dev/null
  asmPath=+DATAC1/$primDbUniqueName/DG
  printf "%-75s : " "  - Test de $asmPath"
  v=$(exec_sql "/ as sysdba" "
SELECT 'OK'
FROM ( SELECT
  concat('+' || gname, sys_connect_by_path(aname, '/')) full_alias_path
  FROM ( SELECT
  g.name            gname,
  a.parent_index    pindex,
  a.name            aname,
  a.reference_index rindex
FROM
  v\$asm_alias      a,
  v\$asm_diskgroup  g
WHERE
  a.group_number = g.group_number)
START WITH ( mod(pindex, power(2, 24)) ) = 0
CONNECT BY PRIOR rindex = pindex)
WHERE
    upper(full_alias_path) = upper('$asmPath');
")

  [ "$v" = "OK" ]  && echo OK || { echo ERR ; die "Le repertoire $asmPath n'existe pas
veuillez lancer la commande  suivante depuis l'utilisateur GRID

  asmcmd mkdir $asmPath

" ; }

 . $HOME/$primDbName.env

  checkDBParam "Base en force Logging"     "select force_logging from v\$database;"                           "YES"
  checkDBParam "Base en Flashback"         "select flashback_on  from v\$database;"                           "YES"
#  checkDBParam "log_archive_config vide"   "select value from v\$parameter where name='log_archive_config';"  ""

  changeParam "LOG_ARCHIVE_DEST_1"                 "'LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) MAX_FAILURE=1 REOPEN=5 DB_UNIQUE_NAME=$primDbUniqueName ALTERNATE=LOG_ARCHIVE_DEST_10'"
  changeParam "LOG_ARCHIVE_DEST_10"                "'LOCATION=+DATAC1 VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=$primDbUniqueName ALTERNATE=LOG_ARCHIVE_DEST_1'"
  changeParam "LOG_ARCHIVE_DEST_STATE_10"          "ALTERNATE"
  changeParam "LOG_ARCHIVE_CONFIG"                 "'DG_CONFIG=($primDbUniqueName,$stbyDbUniqueName)'"
  changeParam "log_archive_format"                 "'%t_%s_%r.dbf'"
  changeParam "DB_WRITER_PROCESSES"                "4"
  changeParam "log_archive_max_processes"          "8"
  changeParam "STANDBY_FILE_MANAGEMENT"            "AUTO"
  changeParam "remote_login_passwordfile"          "'EXCLUSIVE'"
  changeParam "db_block_checking"                  "'MEDIUM'"
  changeParam "db_block_checksum"                  "'TYPICAL'"
  changeParam "db_lost_write_protect"              "'TYPICAL'"
  changeParam "fast_start_mttr_target"             "300"
  changeParam "log_buffer"                         "268435456"
  changeParam "\"_redo_transport_min_kbytes_sec\"" "100"
  
  printf "%-75s : " "  - Taille des logs"
  tailleLogs=$(exec_sql "/ as sysdba" "select to_char(max(bytes)) from v\$log;")  \
    && echo $tailleLogs \
    || { echo "Erreur" ; echo "$tailleLogs" ; die "Erreur de recuperation de la taille des logs" ; }
  
  printf "%-75s : " "  - Dernier logs"
  lastLog=$(exec_sql "/ as sysdba" "select to_char(max(group#)) from v\$log;")  \
    && echo $lastLog \
    || { echo "Erreur" ; echo "$lastLog" ; die "Erreur de recuperation du numero du dernier log" ; }
  
  printf "%-75s : " "  - Nombre de Logs"
  nombreLogs=$(exec_sql "/ as sysdba" "select to_char(count(*)) from v\$log;")  \
    && echo $nombreLogs \
    || { echo "Erreur" ; echo "$nombreLogs" ; die "Erreur de recuperation du nombre de logs" ; }
  
  printf "%-75s : " "  - Nombre de Standby Logs"
  nombreStandbyLogs=$(exec_sql "/ as sysdba" "select to_char(count(*)) from v\$standby_log;")  \
    && echo $nombreStandbyLogs \
    || { echo "Erreur" ; echo "$nombreStandbyLogs" ; die "Erreur de recuperation du nombre de Standby logs" ; }
  
  if [ "$nombreStandbyLogs" = "0" ]
  then
    echo "  - Creation des STANDBY LOGS"
    exec_sql "/ as sysdba" "
select 'ALTER DATABASE ADD STANDBY LOGFILE THREAD ' || 
       thread# || 
       ' GROUP ' || to_char($lastLog + rownum)  || 
       ' (''+DATAC1'') SIZE $tailleLogs' 
from v\$log ;
    " | while read line
    do
      exec_sql "/ as sysdba" "$line;" "    --> $line" || die "Erreur de creation de standby log"
    done
  elif [ "$nombreStandbyLogs" = "$nombreLogs" ]
  then
    echo "  - Standby logs correct "
  else
    die "Le nombre de standby logs n'est pas correct, corriger avant de relancer"
  fi

  tnsAliasesForDG $primDbUniqueName $hostPrimaire $portPrimaire $servicePrimaire $domainePrimaire \
                  $stbyDbUniqueName $hostStandBy  $portStandBy  $serviceStandBy  $domaineStandBy

  echo "  - Recopie TNSNAMES sur autre noeud"
  otherNode=$(srvctl status database -d $ORACLE_UNQNAME | grep -v $(hostname -s) | sed -e "s;^.*on node ;;")
  printf "%-75s : " "    - Copie sur $otherNode"
  scp -o StrictHostKeyChecking=no $TNS_ADMIN/tnsnames.ora ${otherNode}:$TNS_ADMIN \
    && echo "Ok" \
    || die "Impossible de copie le TNSNAMES sur $otherNode"
  
  echo "  - Ajout des services DATAGUARD"
  addDGService ${primDbName}_dg    PRIMARY          Y
  addDGService ${primDbName}_dg_ro PHYSICAL_STANDBY N

}
addDGService()
{
  service=$1
  role=$2
  start=$3
  echo "    - $service (role=$role start=$start)"
  printf "%-75s : " "      - Existence de $service"
  if srvctl config service -s $service -d $ORACLE_UNQNAME >/dev/null
  then
    echo "Existe"
    printf "%-75s : " "        - Arret de $service"
    srvctl stop service -d $ORACLE_UNQNAME -s $service  >$$.tmp 2>&1 \
     && { echo "Ok" ; rm -f $$.tmp ; } \
     || { echo "Non Lance" ; rm -f $$.tmp ;  }
    printf "%-75s : " "        - Suppression de $service"
    srvctl remove service -d $ORACLE_UNQNAME -s $service  >$$.tmp 2>&1 \
     && { echo "Ok" ; rm -f $$.tmp ; } \
     || { echo "ERREUR" ; cat $$.tmp ; rm -f $$.tmp ; die "Impossible de supprimer $service"; }
  else
    echo "Non Existant"
  fi
  printf "%-75s : " "      - Ajout de $service"
  srvctl add service -d $ORACLE_UNQNAME -s $service -r ${primDbName}1,${primDbName}2 -l $role -q TRUE -e SESSION -m BASIC -w 10 -z 150 >$$.tmp 2>&1 \
     && { echo "Ok" ; rm -f $$.tmp ; } \
     || { echo "ERREUR" ; cat $$.tmp ; rm -f $$.tmp ; die "Impossible d'ajouter $service" ; }
  if [ "$start" = "Y" ]
  then
    printf "%-75s : " "      - Lancement de $service"
    srvctl start service -d $ORACLE_UNQNAME -s $service  >$$.tmp 2>&1 \
       && { echo "Ok" ; rm -f $$.tmp ; } \
       || { echo "ERREUR" ; cat $$.tmp ; rm -f $$.tmp ; die "Impossible de lancer $service" ; }
  fi
}
tnsAliasesForDG()
{
  tnsFile=$TNS_ADMIN/tnsnames.ora
  tnsBackup=$tnsFile.$(date +%Y%m%d)
  printf "%-75s : " "  - Existence de $(basename $tnsFile)"
  [ -f $tnsFile ] && echo "Ok" || { echo "ERREUR" ; die "$tnsFile non trouve" ; }
  printf "%-75s : " "  - Existence de $(basename $tnsBackup)"
  if [ -f $tnsBackup ]
  then
    echo "OK"
  else
    echo "Non Trouve"
    printf "%-75s : " "    - backup dans $(basename $tnsBackup)"
    cp -p $tnsFile $tnsBackup && echo "OK" || die "Impossible de sauvegarder $tnsFile"
  fi
  
dbTmp=$(echo $1 | cut -f1 -d"_")
domaine1=$5
domaine2=$10
  for suffix in dg dg_ro
  do
    addToTns $tnsFile "${dbTmp}_$suffix" "\
  (DESCRIPTION_LIST =
     (LOAD_BALANCE=off)
     (FAILOVER=on)
     (DESCRIPTION =
        (CONNECT_TIMEOUT=5)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=3)
        (ADDRESS_LIST =
           (LOAD_BALANCE=on)
           (ADDRESS = (PROTOCOL = TCP) (HOST = $2) (PORT = $3)))
        (CONNECT_DATA = (SERVER = DEDICATED) (SERVICE_NAME = ${dbTmp}_$suffix.$domaine1))
     )
     (DESCRIPTION =
        (CONNECT_TIMEOUT=5)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=3)
        (ADDRESS_LIST =
           (LOAD_BALANCE=on)
           (ADDRESS = (PROTOCOL = TCP) (HOST = $7) (PORT = $8)))
        (CONNECT_DATA = (SERVER = DEDICATED) (SERVICE_NAME = ${dbTmp}_$suffix.$domaine2))
     )
  ) "
  done

  for db in $1 $6
  do
    echo "  - Aliases pour $db"
    dbUniqueName=$1
    dbName=$(echo $dbUniqueName | cut -f1 -d"_")
    host=$2
    port=$3
    service=$4
    domaine=$5
    shift 5
    addToTns $tnsFile "$dbUniqueName" "\
 (DESCRIPTION =
   (ADDRESS = (PROTOCOL = TCP) (HOST = $host) (PORT = $port))
   (CONNECT_DATA =
     (SERVER = DEDICATED)
     (SERVICE_NAME = $service)
     (FAILOVER_MODE =
        (TYPE = select)
        (METHOD = basic)
     )
     (UR=A)
   )
 )"
    for i in 1 2
    do
      inst=${dbName}$i
      a=${dbUniqueName}$i
      addToTns $tnsFile "${a}" "\
 (DESCRIPTION =
   (ADDRESS = (PROTOCOL=TCP) (HOST = $host) (PORT = $port))
   (CONNECT_DATA =
      (SERVICE_NAME = $service)
      (INSTANCE_NAME=$inst)
      (SERVER=DEDICATED)
      (UR=A)
   )
 )"
      addToTns $tnsFile "${a}_DGMGRL" "\
 (DESCRIPTION =
   (ADDRESS = (PROTOCOL=TCP) (HOST = $host) (PORT = $port))
   (CONNECT_DATA =
      (SERVICE_NAME = ${dbUniqueName}_DGMGRL.$domaine)
      (INSTANCE_NAME=$inst)
      (SERVER=DEDICATED)
      (UR=A)
   )
 )"
    done
  done
}
addToTns()
{
  local TNS_FILE=$1
  local alias=$2
  local tns=$3
  printf "%-75s : " "      - Ajout de $alias"
  if grep "^[ \t]*$alias[ \t]*=" $TNS_FILE >/dev/null
  then
    echo "Existant a remplacer"
    printf "%-75s : " "        - Suppression Alias"
    cp -p $TNS_FILE $TNS_FILE.sv
    cat $TNS_FILE.sv | awk '
    BEGIN { toKeep="Y" }    
    {
      if ( match(toupper($0) , toupper("^[ \t]*'$alias'[ \t]*=") ) )
      {
        parentheseTrouvee=0
        egaleTrouve=0
        toKeep="N"
        while ( egaleTrouve == 0 ) 
        {
          for ( i = 1 ; i<= length($0) && substr($0,i,1) != "=" ; i ++ ) ;
          if ( substr($0,i,1) == "=" ) egaleTrouve = 1 ; else {getline} 
        }
        while ( parentheseTrouvee == 0 ) 
        {
          for (  ; i<= length($0) && substr($0,i,1) != "(" ; i ++ ) ;
          if ( substr($0,i,1) == "(" ) { parentheseTrouvee = 1 ;} else {getline ; i = 1 }
        }
        parLevel=1
        fini=0
        while ( fini == 0  )
        {
          for (  ; i<= length($0) ; i ++ ) 
          {
            c=substr($0,i,1)
            if ( c == "(" ) parLevel ++
            if ( c == ")" ) {parLevel -- ; if ( parLevel==1 ) {fini=1;toKeep="Y";next;} ;}
          }
          if ( fini == 0 ) { getline  }
          i = 1 
        }
      }
      if ( toKeep=="Y" ) {print}
    }
    END { printf("\n") }' > $TNS_FILE 2>$$.tmp \
      && { echo "OK" ; rm -f $$.tmp $TNS_FILE.sv ; } \
      || { echo "ERREUR" ; cat $$.tmp ; rm -f $$.tmp ; cp -p $TNS_FILE.sv $TNS_FILE ; die "Erreur de mise a jour TNS (suppr $alias)" ; }
  else
    echo "Nouvel Alias"
  fi
  cp -p $TNS_FILE $TNS_FILE.sv
  printf "%-75s : " "        - Ajout alias"
  echo "$alias = $tns" >> $TNS_FILE 2>$$.tmp \
    && { echo "OK" ; rm -f $$.tmp $TNS_FILE.sv ; } \
    || { echo "ERREUR" ; cat $$.tmp ; rm -f $$.tmp ; cp -p $TNS_FILE.sv $TNS_FILE ; die "Erreur de mise a jour TNS (ajout $alias)" ; }
}

changeParam()
{
  local param=$1
  local new_val=$2
  old_val=$(exec_sql "/ as sysdba" "select value from v\$parameter where name=lower('$param');")
  echo    "  - changement de $param --->"
  echo    "    - Valeur courante : $old_val"
  echo    "    - Nouvelle valeur : $new_val"
  o=$(echo $old_val | sed -e "s;^'*;;g" -e "s;'*$;;g")
  n=$(echo $new_val | sed -e "s;^'*;;g" -e "s;'*$;;g")
  if [ "$o" != "$n" ]
  then
    exec_sql "/ as sysdba" "alter system set $param=$new_val scope=both sid='*';" "    Changement de valeur"
  else
    echo "    - Valeur correcte, inchangé"
  fi
}
checkDBParam()
{
  local lib=$1
  local sql=$2
  local res=$3
  printf "%-75s : " "  - $lib"
  v=$(exec_sql "/ as sysdba" "$sql")
  [ "$v" = "$res" ] && echo "OK" || { echo "ERR" ; die "Erreur de verification des conditions initiales" ; }
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
# 
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
createDG()
{
  startRun "Creation d'une association DATAGUARD"
  echo
  echo "==============================================================="
  echo
  echo "  - SCAN Local       : $scanLocal"
  echo "    --> $hostLocal ($portLocal)"
  echo "  - SCAN oppose      : $scanOppose"
  echo "    --> $hostOppose ($portOppose)"
  echo "  - Base PRIMAIRE    : $primDbName ($primDbUniqueName)"
  echo "    --> Host   : $hostPrimaire - $portPrimaire"
  echo "    --> Scan   : $scanPrimaire"
  echo "    --> Tns    : $tnsPrimaire"
  echo "  - Base STANDBY     : $stbyDbName ($stbyDbUniqueName)"
  echo "    --> Host   : $hostStandBy - $portStandBy"
  echo "    --> Scan   : $scanStandBy"
  echo "    --> Tns    : $tnsStandBy"
  echo "  - TNS_ADMIN        : $TNS_ADMIN"
  echo "  - Execution sur    : $opePart"
  echo
  echo "==============================================================="
  echo

  if [ "$opePart" = "STANDBY" ]
  then

    . oraenv <<< +ASM1 >/dev/null
    asmPath=+DATAC1/$stbyDbUniqueName/DG
    printf "%-75s : " "  - Test de $asmPath"
    v=$(exec_sql "/ as sysdba" "
  SELECT 'OK'
  FROM ( SELECT
           concat('+' || gname, sys_connect_by_path(aname, '/')) full_alias_path
         FROM ( SELECT
                  g.name            gname,
                  a.parent_index    pindex,
                  a.name            aname,
                  a.reference_index rindex
                FROM
                  v\$asm_alias      a,
                  v\$asm_diskgroup  g
                WHERE
                  a.group_number = g.group_number)
         START WITH ( mod(pindex, power(2, 24)) ) = 0
         CONNECT BY PRIOR rindex = pindex)
  WHERE
    upper(full_alias_path) = upper('$asmPath');
")

    [ "$v" = "OK" ]  && echo OK || { echo ERR ; echo $v ; die "Le repertoire $asmPath n'existe pas
veuillez lancer la commande  suivante depuis l'utilisateur GRID

asmcmd mkdir $asmPath

" ; }

    . $HOME/$stbyDbName.env

    if [ -f /tmp/${primDbUniqueName}_ewallet.p12 ]
    then
      printf "%-75s : " "    - Copie de ewallet.p12"
      cp /tmp/${primDbUniqueName}_ewallet.p12 /var/opt/oracle/dbaas_acfs/$primDbName/tde_wallet/ewallet.p12 \
         && { echo OK ; rm -f /tmp/${primDbUniqueName}_ewallet.p12 ; } \
         || die "Impossible de copier ewallet.p12"
    fi

    if [ -f /tmp/${primDbUniqueName}_cwallet.sso ]
    then
      printf "%-75s : " "    - Copie de cwallet.sso"
      cp /tmp/${primDbUniqueName}_cwallet.sso /var/opt/oracle/dbaas_acfs/$primDbName/tde_wallet/cwallet.sso \
         && { echo OK ; rm -f /tmp/${primDbUniqueName}_cwallet.sso ; } \
         || die "Impossible de copier cwallet.sso"
    fi

    echo "  - On est sur la machine stand-by, la base ne doit pas pouvoir etre lancee"
    if [ "$(srvctl status database -d $stbyDbUniqueName | grep -i running | grep -vi "not running")" != "" ]
    then
      echo "    - La base est lancee, ... pas bon"
      printf "%-75s : " "  - Role de la base $laBase"
      if [ "$(ps -ef | grep "smon_${ORACLE_SID}" | grep -v grep | wc -l)" = "1" ]
      then
        dbRole=$(exec_sql "/ as sysdba" "select database_role from v\$database ;") 
      else
        dbRole="NonLancee"
      fi
      echo $dbRole
      if [ "$dbRole" = "PHYSICAL STANDBY" ]
      then
        echo "    --> Suite de la procedure"
        finalisationDG
      else
        echo "    - Arret de la base"
        srvctl stop  database -d $stbyDbUniqueName >/dev/null 2>&1
        echo "    - Essai de Relancement ...."
        srvctl start database -d $stbyDbUniqueName >/dev/null 2>&1
      fi
    else
      echo "    - La base n'est pas lancee, on essaie de la demarrer"
      srvctl start database -d $stbyDbUniqueName >/dev/null 2>&1
    fi
    laBase=$stbyDbUniqueName
  else
    laBase=$primDbUniqueName
  fi

  printf "%-75s : " "  - Role de la base $laBase" 
  if [ "$(ps -ef | grep "smon_${ORACLE_SID}" | grep -v grep | wc -l)" = "1" ]
  then
    dbRole=$(exec_sql "/ as sysdba" "select database_role from v\$database ;") || die "Erreur a la recuperation du role de la base"
  else
    dbRole="NonLancee"
  fi
  echo $dbRole

  if [ "$opePart" = "STANDBY" -a "$dbRole" = "PRIMARY" ]
  then
    echo 
    echo "  - Sauvegardes avant destruction"
    saveSpfile=$LOG_DIR/init_${stbyDbUniqueName}_${DAT}.ora
    exec_sql "/ as sysdba" "create pfile='$saveSpfile' from spfile;" "    - Sauvegarde du SPFILE" || die "Erreur de sauvegarde du spfile"
    echo "      --> INIT.ORA : $saveSpfile"
    printf "%-75s : " "    - Emplacement du spfile"
    spfileLoc=$(srvctl config database -d $ORACLE_UNQNAME | grep "Spfile:" | cut -f2 -d" ") \
      && { echo "Ok" ; } \
      || { echo "Erreur" ; echo $spfileLoc ; die "Impossible de recuperer l'emplacementt du SPFILE" ; }
    echo "      --> SPFILE : $spfileLoc"
    
    echo "

  =======================================================================
  ATTENTION, nous sommes sur la creation de la base stand-by, la base
  doit etre presente dans le clusterware, mais ne doit pas pouvoir
  etre lancee en PRIMAIRE. Ici, nous avons une base $stbyDbUniqueName 
  lancee.
  
  Vous devez (sans changer de serveur):  

      1) détruire manuellement tous les fichiers de cette base
         dans ASM avant de relancer la procedure

         pour ceci lancez les commandes suivantes sous \"grid\"
  
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ]  && asmcmd rm -rf +DATAC1/$stbyDbUniqueName || echo -e \"\\n\\nERREUR\\n\\n\"
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ]  && asmcmd mkdir  +DATAC1/$stbyDbUniqueName || echo -e \"\\n\\nERREUR\\n\\n\"
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ]  && asmcmd rm -rf +RECOC1/$stbyDbUniqueName || echo -e \"\\n\\nERREUR\\n\\n\"
[ \"\$(hostname -s)\" = \"$(hostname -s)\" ]  && asmcmd mkdir  +RECOC1/$stbyDbUniqueName || echo -e \"\\n\\nERREUR\\n\\n\"

     2) recreer le spfile de la base en executant sous \"oracle\"
        (copier/coller tout le bloc de code)

if [ \"\$(hostname -s)\" = \"$(hostname -s)\" ]  
then
  . $HOME/$stbyDbName.env && sqlplus / as sysdba <<%EOF%
  create spfile='$spfileLoc'
  from pfile='$saveSpfile' ;
%EOF%
else
  echo -e \"\\n\\nERREUR de serveur\\n\\n\" 
fi



  =======================================================================
  "
  printf "%-75s : " "  - Arret de la base $stbyDbUniqueName"
  srvctl stop database -d $stbyDbUniqueName >$$.tmp 2>&1 \
    && { echo "Base Stoppee, supprimez les fichiers" ; rm -f $$.tmp ; } \
    || { echo ERREUR ;  cat $$.tmp ; rm -f $$.tmp ; die "Erreur a l'arret de la base" ; }
    echo "
  =======================================================================
  "

  exit
  fi

  if [ "$dbRole" = "PRIMARY" -a "$opePart" = "PRIMARY" ]
  then
    createOnPrimary
    tdeWallet=$(exec_sql "/ as sysdba" "select wrl_parameter from v\$encryption_wallet;") || die "Impossible de recuperer le repertoire du wallet"
    printf "%-75s : " "  - Copie des fichers du Wallet"
    { cp -p $tdeWallet/ewallet.p12 /tmp/${primDbUniqueName}_ewallet.p12 \
 && cp -p $tdeWallet/cwallet.sso /tmp/${primDbUniqueName}_cwallet.sso ; } \
 && echo "OK" || die "Impossible de copier les fichiers du wallet"
 passwordFile=$(srvctl config database -d $ORACLE_UNQNAME | grep "Password file" | sed -e "s;^.*: *;;")
    echo "

========================================================================

    La preparation de la base primaire est maintenant terminee, la
suite des operations de déroule depuis la machine stand-by.

    Pour continuer :

    1) Recuperez le fichier password en lançant (sous \"grid\")

       asmcmd cp $passwordFile /tmp/${primDbUniqueName}_passwd.ora

    2) Transferez les trois fichiers ci-dessous sur le
       serveur stand-by (dans /tmp)

       /tmp/${primDbUniqueName}_ewallet.p12
       /tmp/${primDbUniqueName}_cwallet.sso
       /tmp/${primDbUniqueName}_passwd.ora

    3) Effacez ces trois fichiers

       rm -f /tmp/${primDbUniqueName}_ewallet.p12
       rm -f /tmp/${primDbUniqueName}_cwallet.sso
       rm -f /tmp/${primDbUniqueName}_passwd.ora

    4) Connectez-vous à la machine de secours (noeud 1) et lancez :
 
  $SCRIPT -m RunOnStandBY -d $primDbUniqueName -D $stbyDbUniqueName -s $scanLocal

========================================================================
"
  elif [ "$dbRole" = "NonLancee" -a "$opePart" = "STANDBY" ]
  then
    duplicateDBForStandBY
  else
    die "Je ne sais pas (encore) faire (opePart=$opePart, dbRole=$dbRole) !"
  fi
  endRun
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Trace
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
startRun()
{
  START_INTERM_EPOCH=$(date +%s)
  echo   "========================================================================================" 
  echo   " Demarrage de l'execution"
  echo   "========================================================================================" 
  echo   "  - $1"
  echo   "  - Demarrage a    : $(date)"
  echo   "========================================================================================" 
  echo
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Trace
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
endRun()
{
  END_INTERM_EPOCH=$(date +%s)
  all_secs2=$(expr $END_INTERM_EPOCH - $START_INTERM_EPOCH)
  mins2=$(expr $all_secs2 / 60)
  secs2=$(expr $all_secs2 % 60 | awk '{printf("%02d",$0)}')
  echo
  echo   "========================================================================================" 
  echo   "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo   "  - Fin a         : $(date)" 
  echo   "  - Duree         : ${mins2}:${secs2}"
  echo   "========================================================================================" 
  echo   "Script LOG in : $LOG_FILE"
  echo   "========================================================================================" 
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Trace
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
startStep()
{
  STEP="$1"
  STEP_START_EPOCH=$(date +%s)
  echo
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo "       - Debut Etape   : $STEP"
  echo "       - Demarrage a   : $(date)" 
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Trace
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
endStep()
{
  STEP_END_EPOCH=$(date +%s)
  all_secs2=$(expr $STEP_END_EPOCH - $STEP_START_EPOCH)
  mins2=$(expr $all_secs2 / 60)
  secs2=$(expr $all_secs2 % 60 | awk '{printf("%02d",$0)}')
  echo
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo "       - Fin Etape     : $STEP"
  echo "       - Terminee a    : $(date)" 
  echo "       - Duree         : ${mins2}:${secs2}"
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Abort du programme
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
die() 
{
  echo "
ERROR :
  $*"
  exit 1
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#      Exécute du SQL avec contrôle d'erreur et de format
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
                      || { echo "OK" ; [ "$VERBOSE" = "Y" ] && test -f $REDIR_FILE && sed -e "s;^;    > ;" $REDIR_FILE ; }
  fi 
  rm -f $REDIR_FILE
  [ $status -ne 0 ] && return 1
  return $status
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Teste un répertoire et le crée
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#  Usage
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
usage() 
{
 echo " $*

Usage :
 $SCRIPT [-d primDbName] [-D stbyDbName]
         [-k keyStorePass] [-s scan] [-L degreParal]  [-G diskGroup]
         [-C|-R] [-h|-?]

         primDbName   : Base PRIMAIRE (db Name seulement)
         stbyDbName   : Base StandBy (db Unique Name seulement - elle doit exister)
         keyStorePass : MOt de passe TDE Cible, necessaire seulement
                        si on ne peut pas le recuperer dans le Wallet
         diskGroup    : DB_CREATE_FILE_Dest de 
                        la cible                 : Defaut inchange
         scan         : Adresse Scan (host:port) de la contrepartie: Defaut HPR
         -C           : Copie et migration d'une base (le script se relance
                        en nohup apres que les premieres verifications sont faites
                        sauf si -i est precise)
         -R           : Supprime la PDB cible
         -i           : Ne relance pas le script en Nohup 
                        (pour enchainer par exemple)
         -?|-h        : Aide

  Version : $VERSION
  "
  exit
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
set -o pipefail

SCRIPT=setUpDG.sh

[ "$1" = "" ] && usage
toShift=0
while getopts m:d:D:k:s:L:G:CRTi opt
do
  case $opt in
   # --------- Source Database --------------------------------
   d)   primDbName=$OPTARG       ; toShift=$(($toShift + 2)) ;;
   D)   stbyDbName=$OPTARG       ; toShift=$(($toShift + 2)) ;;
   # --------- Target Database --------------------------------
   # --------- Keystore, Scan ... -----------------------------
   k)   keyStorePassword=$OPTARG ; toShift=$(($toShift + 2)) ;;
   s)   scanOppose=$OPTARG       ; toShift=$(($toShift + 2)) ;;
   G)   dstDiskGroup=$OPTARG     ; toShift=$(($toShift + 2)) ;;
   # --------- Modes de fonctionnement ------------------------
   C)   mode=CREATE              ; toShift=$(($toShift + 1)) ;;
   R)   mode=DELETE              ; toShift=$(($toShift + 1)) ;;
   T)   mode=TEST                ; toShift=$(($toShift + 1)) ;;
   i)   aRelancerEnBatch=N       ; toShift=$(($toShift + 1)) ;;
   m)   ope=$OPTARG              ; toShift=$(($toShift + 2)) ;;
   # --------- Usage ------------------------------------------
   ?|h) usage "Aide demandee";;
  esac
done
shift $toShift 
# -----------------------------------------------------------------------------
#
#       Analyse des paramètres et valeurs par défaut
#
# -----------------------------------------------------------------------------
if [ "${ope^^}" = "RUNONSTANDBY" ]
then
  opePart="STANDBY"
  shift
else
  opePart="PRIMARY"
fi


#
#      Base de données source (Db Name)
#
primDbName=${primDbName:-tmpmig}
if [ "$(echo $primDbName | grep "_")" != "" ]
then
  primDbUniqueName=$primDbName
  primDbName=$(echo $primDbName | cut -f1 -d"_")
fi

stbyDbName=${stbyDbName:-tmpmig_fra1jz}
if [ "$(echo $stbyDbName | grep "_")" != "" ]
then
  stbyDbUniqueName=$stbyDbName
  stbyDbName=$(echo $stbyDbName | cut -f1 -d"_")
fi
#
#   Adresse SCAN (Par défaut, HPR) DOMAINE=même domaine que
# le scan.
#
if [ "$scanOppose" = "" ]
then
  scanOppose="hprexacs-7sl1q-scan.dbad2.hpr.oraclevcn.com:1521"
fi

#
#   Mode de fonctionnement
#
mode=${mode:-CREATE}                             # Par défaut Create
aRelancerEnBatch=${aRelancerEnBatch:-Y}          # Par défaut, le script de realne en nohup après les
                                                 # vérifications (pour la copie seulement)

# -----------------------------------------------------------------------------
#
#    Constantes et variables dépendantes
#
# -----------------------------------------------------------------------------
DAT=$(date +%Y%m%d_%H%M)                     # DATE (for filenames)
BASEDIR=$HOME/dataguard                      # Base dir for logs & files
LOG_DIR=$BASEDIR/$primDbName                  # Log DIR

if [ "$LOG_FILE" = "" ]
then
  case $mode in
    CREATE)    LOG_FILE=$LOG_DIR/dataGuard_CRE_${primDbName}_${DAT}.log ;;
    DELETE)    LOG_FILE=$LOG_DIR/dataGuard_DEL_${primDbName}_${DAT}.log ;;
    TEST)      LOG_FILE=/dev/null ;;
    *)         die "Mode inconnu" ;;
  esac
fi

# -----------------------------------------------------------------------------
#    Controles basiques (il faut que l'on puisse poitionner l'environnement
# base de données cible (et que ce soit la bonne!!!
# -----------------------------------------------------------------------------

checkDir $LOG_DIR || die "$LOG_DIR is incorrect"
if [ "$opePart" = "PRIMARY" ]
then

  [ -f "$HOME/$primDbName.env" ] || die "$primDbName.env non existent"
  . "$HOME/$primDbName.env"
  [ "$(exec_sql "/ as sysdba" "select  name from v\$database;")" != "${primDbName^^}" ] && die "Environnement mal positionne"
  primDbUniqueName=$ORACLE_UNQNAME
  
  scanStandBy=$scanOppose
  domaineStandBy=$(echo $scanStandBy | sed -e "s;^[^\.]*\.\([^\:]*\).*$;\1;")  # Domaine du Scan
  serviceStandBy=$stbyDbUniqueName.$domaineStandBy
  tnsStandBy="//$scanStandBy/$serviceStandBy"
  
  scanLocal=$(srvctl config scan  | grep -i "SCAN name" | cut -f2 -d: | cut -f1 -d, | sed -e "s; ;;g"):1521
  scanPrimaire=$scanLocal
  domainePrimaire=$(echo $scanLocal | sed -e "s;^[^\.]*\.\([^\:]*\).*$;\1;")  # Domaine du Scan
  servicePrimaire=$primDbUniqueName.$domainePrimaire
  tnsPrimaire="//$scanLocal/$servicePrimaire"
  grep "^${primDbUniqueName}:" /etc/oratab >/dev/null 2>&1 || die "$primDbUniqueName n'est pas dans /etc/oratab"

  hostLocal=$(echo $scanLocal | cut -f1 -d:)
  portLocal=$(echo $scanLocal | cut -f2 -d:)
  hostOppose=$(echo $scanOppose | cut -f1 -d:)
  portOppose=$(echo $scanOppose | cut -f2 -d:)
  hostPrimaire=$hostLocal
  portPrimaire=$portLocal
  hostStandBy=$hostOppose
  portStandBy=$portOppose

else

  [ -f "$HOME/$stbyDbName.env" ] || die "$primDbName.env non existent"
  . "$HOME/$stbyDbName.env"
  stbyDbUniqueName=$ORACLE_UNQNAME

  scanLocal=$(srvctl config scan  | grep -i "SCAN name" | cut -f2 -d: | cut -f1 -d, | sed -e "s; ;;g"):1521
  scanStandBy=$scanLocal
  domaineStandBy=$(echo $scanLocal | sed -e "s;^[^\.]*\.\([^\:]*\).*$;\1;")  # Domaine du Scan
  serviceStandBy=$stbyDbUniqueName.$domaineStandBy
  tnsStandBy="//$scanLocal/$serviceStandBy"
  
  scanPrimaire=$scanOppose
  domainePrimaire=$(echo $scanPrimaire | sed -e "s;^[^\.]*\.\([^\:]*\).*$;\1;")  # Domaine du Scan
  servicePrimaire=$primDbUniqueName.$domainePrimaire
  tnsPrimaire="//$scanPrimaire/$servicePrimaire"

  hostLocal=$(echo $scanLocal | cut -f1 -d:)
  portLocal=$(echo $scanLocal | cut -f2 -d:)
  hostOppose=$(echo $scanOppose | cut -f1 -d:)
  portOppose=$(echo $scanOppose | cut -f2 -d:)
  hostPrimaire=$hostOppose
  portPrimaire=$portOppose
  hostStandBy=$hostLocal
  portStandBy=$portLocal

  grep "^${stbyDbUniqueName}:" /etc/oratab >/dev/null 2>&1 || die "$stbyDbUniqueName n'est pas dans /etc/oratab"

fi


# -----------------------------------------------------------------------------
#      Lancement de l'exécution
# -----------------------------------------------------------------------------

case $mode in
 CREATE) createDG       2>&1 | tee $LOG_FILE ;;
 DELETE) deletePdb      2>&1 | tee $LOG_FILE ;;
 TEST)   testUnit       2>&1 | tee $LOG_FILE ;;
esac

