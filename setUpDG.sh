VERSION=1.0
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
verificationDG()
{
  echo
  echo "  - Tests de connexion et etat DG"
  echo "    ============================="
  echo

  printf "%-75s : " "      - Connexion à ${primDbName}_dg    dbUniqueName (nominal) = $primDbUniqueName"
  res=$(exec_sql "sys/${dbPassword}@ ${primDbName}_dg as sysdba" "select db_unique_name from v\$database ;")
  if [ "$res" = "$primDbUniqueName" ] 
  then
    echo "OK --> $res" 
  elif [ "$res" = "$stbyDbUniqueName" ]
  then
    echo "Retourne --> $res"
  else
    echo "Erreur"
    echo "$res"
    die "Mauvaise connexion à ${primDbName}_dg"
  fi

  printf "%-75s : " "      - Connexion à ${primDbName}_dg_ro dbUniqueName (nominal) = $stbyDbUniqueName"
  res=$(exec_sql "sys/${dbPassword}@ ${primDbName}_dg_ro as sysdba" "select db_unique_name from v\$database ;")
  if [ "$res" = "$stbyDbUniqueName" ]
  then
    echo "OK --> $res" 
  elif [ "$res" = "$primDbUniqueName" ]
  then
    echo "Retourne --> $res" 
  else
    echo "Erreur"
    echo "$res"
    die "Mauvaise connexion à ${primDbName}_dg_ro"
  fi

  echo ===============================================================
  echo Configuration
  echo ===============================================================
  dgmgrl -silent / "show configuration"

  echo ===============================================================
  echo Show database $primDbUniqueName
  echo ===============================================================
  dgmgrl -silent / "show database verbose $primDbUniqueName"

  echo ===============================================================
  echo Show database $stbyDbUniqueName
  echo ===============================================================
  dgmgrl -silent / "show database verbose $stbyDbUniqueName"

  echo ===============================================================
  echo Validate database $primDbUniqueName
  echo ===============================================================
  dgmgrl -silent / "validate database verbose $primDbUniqueName"

  echo ===============================================================
  echo Validate database $stbyDbUniqueName
  echo ===============================================================
  dgmgrl -silent / "validate database verbose $stbyDbUniqueName"
  echo ===============================================================
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
#   Etapes post duplication
#   - Reinitialisation des LOGS et STANDBY LOGS
#   - Parametrage des deux bases pour le Broker
#   - Creation de la configuration broker
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
finalisationDG()
{

  startStep "Finalisation de la configuration DATAGUARD"
  echo

  echo "
       NOTE : Si la procedure echoue dans cette phase, il es
       possible de la relancer, elle reprendra ici, attention
       neanmoins, si la base source evolue trop, il est 
       possible que la synchronisation ne puisse plus etre
       faite
      "

  echo
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
" "  - Nettoyage des REDO-LOGS (Erreur a la deuxieme execution)"

  echo
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
" "  - Nettoyage des STANDBY REDO-LOGS (Erreur a la deuxieme execution)"

  echo
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

  echo
  echo "  - Dataguard Broker (Primary : $primDbUniqueName)"
  exec_sql -verbose "sys/${dbPassword}@$primDbUniqueName as sysdba" \
                    "alter system set dg_broker_start=false SCOPE=BOTH SID='*';" \
                    "    - Arret broker"
  exec_sql -verbose "sys/${dbPassword}@$primDbUniqueName as sysdba" \
                    "alter system set dg_broker_config_file1='+DATAC1/$primDbUniqueName/DG/dr${primDbName}_1.dat' SCOPE=BOTH SID='*';" \
                    "    - Config Broker #1"
  exec_sql -verbose "sys/${dbPassword}@$primDbUniqueName as sysdba" \
                    "alter system set dg_broker_config_file2='+DATAC1/$primDbUniqueName/DG/dr${primDbName}_2.dat' SCOPE=BOTH SID='*' ;" \
                    "    - Config Broker #2"
  exec_sql -verbose "sys/${dbPassword}@$primDbUniqueName as sysdba" \
                    "alter system set dg_broker_start=true SCOPE=BOTH SID='*';" \
                    "    - Lancement broker"
  exec_sql -verbose "sys/${dbPassword}@$primDbUniqueName as sysdba" \
                    "alter system set DB_BLOCK_CHECKING=MEDIUM scope=both sid='*'; " \
                    "    - DB Block Checking = MEDIUM"

  echo
  echo "  - Mise en place de la configuration DATAGUARD Broker"
  sleep 10
  i=1
  while [ $i -le 10 ]
  do
    exec_dgmgrl "create configuration FSC as primary database is '$primDbUniqueName' connect identifier is '$primDbUniqueName'" \
                "Creation de la configuration (essai : $i/10)"  2>&1 | tee $$.tmp2
    if  [ $? -ne 0 ]
    then
      if grep -i "already exists" $$.tmp2>/dev/null
      then
        exec_dgmgrl "remove configuration" "Suppression de la configuration"
      fi
      rm -f $$.tmp2
      [ $i -lt 10 ] && { echo "    - Attente 10s" ; sleep 10 ; } || die "Impossible de creer la configuration" 
    else
      i=11
    fi
    i=$(($i + 1))
  done
  rm -f $$.tmp2

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

  sleep 10

  echo
  echo "  - Ajout des services DATAGUARD"
  echo "    ============================"
  echo
  if [ "$(ps -ef | grep smon_$ORACLE_SID | grep -v grep)" = "" ]
  then
    exec_srvctl "start database -d $ORACLE_UNQNAME" \
                "    - Lancement de la base de donnes" \
                "Ok" "Erreur" "Impossible de lancer la base"
  fi
  printf "%-75s : " "    - Role de la base $stbyDbUniqueName"
  dbRole=$(exec_sql "/ as sysdba" "select database_role from v\$database; ") \
    && { echo "$dbRole" ; } \
    || { echo Erreur ; echo $dbRole ; die "Impossible de selectionne le role de la base" ; }

  [ "$dbRole" = "PRIMARY" ] && die "Le role de la base est incorrect"

  printf "%-75s : " "    - Etat de la base $stbyDbUniqueName"
  dbState=$(exec_sql "/ as sysdba" "select open_mode from v\$database; ") \
    && { echo "$dbState" ; } \
  || { echo Erreur ; echo $dbState ; die "Impossible de selectionne l'etat de la base" ; }

  if [ "$dbState" = "MOUNTED" ]
  then

    exec_srvctl "stop database -d $ORACLE_UNQNAME" \
                "    - Arret de la base de donnes" \
                "Ok" "Erreur" "Impossible de stopper la base" 

    exec_srvctl "start database -d $ORACLE_UNQNAME" \
                "    - Lancement de la base de donnes" \
                "Ok" "Erreur" "Impossible de lancer la base" 

    printf "%-75s : " "    - Etat de la base $stbyDbUniqueName"
    dbState=$(exec_sql "/ as sysdba" "select open_mode from v\$database; ") \
      && { echo "$dbState" ; } \
      || { echo Erreur ; echo $dbState ; die "Impossible de selectionne l'etat de la base" ; }

  fi

  if [ "$(echo $dbState | grep -i "READ ONLY")" = "" ]
  then
    exec_sql "/ as sysdba" "alter database open read only; " "    - Ouverture de la base en lecture seule" \
      || die "Impossible d'ouvrir la base de donnees"
  fi


  addDGService ${primDbName}_dg    PRIMARY          N
  addDGService ${primDbName}_dg_ro PHYSICAL_STANDBY Y

  verificationDG


  endStep
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#   Duplication de la base de donnees vers la stand-by. 
#     - Generation des entrees TNSNAMES
#     - Recopie du TNSNAMES sur l'autre noeud
#     - Lancement en NOMOUNT et restauration Control File
#     - Lancement en MOUNT et restauration puis recover
#     - On lance ensuite la finalisation qui peut etre relancee plusieurs fois
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
  exec_srvctl "start database -d $stbyDbUniqueName -o nomount" \
              "    - Lancement en NO MOUNT pour restauration du control file" \
              "Ok" "Erreur" "Impossible de lancer en NOMOUT"

  printf "%-75s : " "      - Restoration du control file"
  rman target / >$$.tmp 2>&1 <<%%
run { restore standby controlfile from service '$primDbUniqueName' ; }
%%
  [ $? -eq 0 ] && { echo OK ; rm -f $$.tmp ; } \
               || { echo ERREUR ; cat $$.tmp ; rm -f $$.tmp ; die "Erreur de restoration du control file" ; }
  exec_sql "/ as sysdba" "
alter system set log_file_name_convert=
       '+DATAC1/$primDbUniqueName','+DATAC1/$stbyDbUniqueName'
      ,'+RECOC1/$primDbUniqueName','+RECOC1/$stbyDbUniqueName' scope=spfile ;" "      - log_file_name_convert" \
      || die "Impossible de positionner log_file_name_convert"

  exec_srvctl "stop database -d $stbyDbUniqueName" \
              "      - Arret de la base" \
              "Ok" "Erreur" "Impossible de stopper la base"
  echo
  exec_srvctl "start database -d $stbyDbUniqueName -o mount" \
              "    - Lancement en MOUNT pour restauration" \
              "Ok" "Erreur" "Impossible de lancer en MOUNT"

  echo
  LOG_TMP=$LOG_DIR/restau_${primDbName}_$DAT.log
  echo "     Note : La restauration peut être suivie dans : "
  echo "     $LOG_TMP"
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
               || { echo ERREUR ; cat $LOG_TMP  ; rm -f $LOG_TMP; die "Erreur de restauration de la base" ; }

  echo "     Note : La restauration peut être suivie dans : "
  echo "     $LOG_TMP"
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
               || { echo ERREUR ; cat $LOG_TMP  ; rm -f $LOG_TMP; die "Erreur de Recover de la base" ; }

  endStep
  echo
  echo "  - Attente 30 secondes"
  sleep 30
  finalisationDG
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
#         Cette procedure prepare la base stand-by pour mise en place de la base
#  stand-by. Il n'y a aucun arret de la base pendant cette phase
#
#    - Verifications de base 
#    - Recuperation du wallet et du fichier password
#    - Mise a jour des parametres necessaires
#    - Generation des alias TNS utiles pour le broker
#    - Ajout des services DATAGUARD
#    - Si le SSH est ouvert vers le serveur stand-by on
#      recopie les fichiers, sinon il faudra les recopier
#      manuellement dans /tmp en gardant les mêmes noms.
#
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
preparePrimary()
{
  tmpOut=/tmp/$$.tmp
  echo "  - Operations sur la base $primDbName cote PRIMARY"
  echo
  echo "    Une fois ces operations realisees, il faudra relancer"
  echo "    ce script sur le cluster de secours avec les options"
  echo "    fournies en fin d'execution"

  echo
  echo "  - Verifications"
  echo "    ============="
  echo

  printf "%-75s : " "  - Test acces base Primaire (SCAN)"
  tnsping $tnsPrimaire >/dev/null 2>&1 && echo "Ok" || { echo "ERREUR" ; die "TNS de la base primaire inaccessible" ; }

  printf "%-75s : " "  - Test acces base Stand-By (SCAN)"
  tnsping $tnsStandBy >/dev/null 2>&1 && echo "Ok" || { echo "ERREUR" ; die "TNS de la base primaire inaccessible" ; }

  printf "%-75s : " "  - Recuperation GRID_HOME"
  gridHome=$(grep "^+ASM1:" /etc/oratab | cut -f2 -d":")
  [ "$gridHome" = "" ] &&  { echo "Impossible" ; die "Impossible de determiner GRID_HOME" ; } || echo "OK ($gridHome)"

  checkDBParam "Base en force Logging"     "select force_logging from v\$database;"                           "YES"
  checkDBParam "Base en Flashback"         "select flashback_on  from v\$database;"                           "YES"
  
  echo
  echo "  - Recopie des fichiers utiles a la creation de la base stand-by"
  echo "    ============================================================="
  echo
  printf "%-75s : " "  - Emplacement du Wallet TDE"
  tdeWallet=$(exec_sql "/ as sysdba" "select wrl_parameter from v\$encryption_wallet;") 
  [ -d "$tdeWallet" ] && { echo $tdeWallet ; } \
                      || { echo "Erreur" ; echo $tdeWallet ; die "Impossible de recuperer le repertoire du wallet" ; }

  printf "%-75s : " "  - Copie des fichers du Wallet"
  { cp $tdeWallet/ewallet.p12 /tmp/${primDbUniqueName}_ewallet.p12 \
    && cp $tdeWallet/cwallet.sso /tmp/${primDbUniqueName}_cwallet.sso ; } \
       && echo "OK"  \
       || die "Impossible de copier les fichiers du wallet"

  #
  #   On doit avoir l'environnement ASM pour utiliser ASMCMD
  #
  echo
  printf "%-75s : " "  - Password File"
  passwordFile=$(srvctl config database -d $ORACLE_UNQNAME | grep "Password file" | sed -e "s;^.*: *;;")

  . oraenv <<< $ASM_INSTANCE >/dev/null
  $gridHome/bin/asmcmd --privilege sysdba ls $passwordFile >/dev/null 2<&1 \
    && { echo $passwordFile ; } \
    || { echo "Erreur"  ; echo $passwrdFile ; die "Impossible de trouver le fichier Password" ; }

  printf "%-75s : " "  - Copie du fichier password"

  #
  #     Ce bricolage immonde permet de contourner le probleme 
  # de droits d'accès au fichier qui appartient à grid au départ
  #
  rm -rf /tmp/recup$$
  mkdir /tmp/recup$$
  chmod 777 /tmp/recup$$
  $gridHome/bin/asmcmd --privilege sysdba cp $passwordFile /tmp/recup$$/${primDbUniqueName}_passwd.ora >$$.tmp 2<&1 \
    && { echo "Ok" ; cp /tmp/recup$$/${primDbUniqueName}_passwd.ora /tmp/${primDbUniqueName}_passwd.ora ; rm -f $$.tmp ; } \
    || { echo "Erreur"  ; cat $$.tmp ; rm -f $$.tmp ; die "Impossible de recuperer le fichier Password" ; }
  rm -rf /tmp/recup$$

  asmPath=+DATAC1/$primDbUniqueName/DG
  printf "%-75s : " "  - Test de $asmPath"
  $gridHome/bin/asmcmd --privilege sysdba ls -d $asmPath >/dev/null 2>&1 \
    && { v="OK" ; echo "OK" ; } \
    || { v="KO" ; echo "Non Existant" ; }

  if [ "$v" != "OK" ]
  then
    printf "%-75s : " "  - Creation de $asmPath"
    $gridHome/bin/asmcmd --privilege sysdba mkdir $asmPath >$$.tmp 2>&1 \
      && { echo OK ; rm -f $$.tmp ; } \
      || { echo ERREUR ; cat $$.tmp ; rm -f $$.tmp ; die "Impossible de creer $asmPath" ; }
  fi
  . $primEnvFile

#
  echo
  echo "  - Changement des parametres de la base"
  echo "    ===================================="
  echo
  changeParam "LOG_ARCHIVE_DEST_1"                 "'LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) MAX_FAILURE=1 REOPEN=5 DB_UNIQUE_NAME=$primDbUniqueName ALTERNATE=LOG_ARCHIVE_DEST_10'"
  changeParam "LOG_ARCHIVE_DEST_10"                "'LOCATION=+DATAC1 VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=$primDbUniqueName ALTERNATE=LOG_ARCHIVE_DEST_1'"
  changeParam "LOG_ARCHIVE_DEST_STATE_10"          "ALTERNATE"
  changeParam "LOG_ARCHIVE_CONFIG"                 "'DG_CONFIG=($primDbUniqueName,$stbyDbUniqueName)'"
  changeParam "log_archive_format"                 "'%t_%s_%r.dbf'"
  #changeParam "DB_WRITER_PROCESSES"                "4"
  changeParam "log_archive_max_processes"          "8"
  changeParam "STANDBY_FILE_MANAGEMENT"            "AUTO"
  changeParam "remote_login_passwordfile"          "'EXCLUSIVE'"
  changeParam "db_block_checking"                  "'MEDIUM'"
  changeParam "db_block_checksum"                  "'TYPICAL'"
  changeParam "db_lost_write_protect"              "'TYPICAL'"
  changeParam "fast_start_mttr_target"             "300"
  #changeParam "log_buffer"                         "268435456"
  changeParam "\"_redo_transport_min_kbytes_sec\"" "100"
  
  printf "%-75s : " "    - Taille des logs"
  tailleLogs=$(exec_sql "/ as sysdba" "select to_char(max(bytes)) from v\$log;")  \
    && echo $tailleLogs \
    || { echo "Erreur" ; echo "$tailleLogs" ; die "Erreur de recuperation de la taille des logs" ; }
  
  printf "%-75s : " "    - Dernier logs"
  lastLog=$(exec_sql "/ as sysdba" "select to_char(max(group#)) from v\$log;")  \
    && echo $lastLog \
    || { echo "Erreur" ; echo "$lastLog" ; die "Erreur de recuperation du numero du dernier log" ; }
  
  printf "%-75s : " "    - Nombre de Logs"
  nombreLogs=$(exec_sql "/ as sysdba" "select to_char(count(*)) from v\$log;")  \
    && echo $nombreLogs \
    || { echo "Erreur" ; echo "$nombreLogs" ; die "Erreur de recuperation du nombre de logs" ; }
  
  printf "%-75s : " "    - Nombre de Standby Logs"
  nombreStandbyLogs=$(exec_sql "/ as sysdba" "select to_char(count(*)) from v\$standby_log;")  \
    && echo $nombreStandbyLogs \
    || { echo "Erreur" ; echo "$nombreStandbyLogs" ; die "Erreur de recuperation du nombre de Standby logs" ; }
  
  if [ "$nombreStandbyLogs" = "0" ]
  then
    echo "    - Creation des STANDBY LOGS"
    exec_sql "/ as sysdba" "
select 'ALTER DATABASE ADD STANDBY LOGFILE THREAD ' || 
       thread# || 
       ' GROUP ' || to_char($lastLog + rownum + 1)  || 
       ' (''+DATAC1'') SIZE $tailleLogs' 
from (          select thread# ,group#      from v\$log
      union all select thread# ,max(group#) from v\$log group by thread#
     ) ;
    " | while read line
    do
      exec_sql "/ as sysdba" "$line;" "        --> $line"  || break
    done || die "Erreur de creation de standby log"
  elif [ $nombreStandbyLogs -eq $(($nombreLogs+2)) -a $nombreStandbyLogs -ne 0 ]
  then
    echo "    - Standby logs correct "
  else
    die "Le nombre de standby logs n'est pas correct, corriger avant de relancer"
  fi

  echo
  echo "  - Generation des Alias TNS necessaires"
  echo "    ===================================="
  echo
  tnsAliasesForDG $primDbUniqueName $hostPrimaire $portPrimaire $servicePrimaire $domainePrimaire \
                  $stbyDbUniqueName $hostStandBy  $portStandBy  $serviceStandBy  $domaineStandBy

  echo
  echo "    - Recopie TNSNAMES sur autre noeud"
  otherNode=$(srvctl status database -d $ORACLE_UNQNAME | grep -v $(hostname -s) | sed -e "s;^.*on node ;;")
  printf "%-75s : " "    - Copie sur $otherNode"
  scp -o StrictHostKeyChecking=no $TNS_ADMIN/tnsnames.ora ${otherNode}:$TNS_ADMIN \
    && echo "Ok" \
    || die "Impossible de copie le TNSNAMES sur $otherNode"
  
  echo
  echo "  - Ajout des services DATAGUARD"
  echo "    ============================"
  echo
  addDGService ${primDbName}_dg    PRIMARY          Y
  addDGService ${primDbName}_dg_ro PHYSICAL_STANDBY N


  echo
  echo "  - Tentative de recopie des fichiers sur $dbServerOppose"
  echo "    ====================================================="
  echo      
  echo "    Si cette phase echoue, il faudra recopier ces fichiers manuellement"
  echo      
  for f in /tmp/${primDbUniqueName}_*
  do
    printf "%-75s : " "    - Copie de $(basename $f) sur $dbServerOppose"
    scp -q $f ${dbServerOppose}:/tmp >/dev/null 2>&1                         \
      && { echo "OK" ; rm -f $f ; }                                          \
      || echo "A copier manuellement dans /tmp@$dbServerOppose"
  done 

}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
#     Ajout des services _dg et _dg_ro sur la base de données (a faire sur
#  les deux bases de donnees
#
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
    exec_srvctl -silent "stop service -d $ORACLE_UNQNAME -s $service" \
                "        - Arret de $service" \
                "Ok" "Non Lance" 
    exec_srvctl "remove service -d $ORACLE_UNQNAME -s $service" \
                "        - Suppression de $service" \
                "Ok" "Erreur" "Impossible de supprimer $service"
  else
    echo "Non Existant"
  fi
  tmp=$(exec_sql "/ as sysdba" "select open_mode from v\$database;")
  if [ "$tmp" = "READ WRITE" ]
  then
    exec_sql "/ as sysdba" "
      delete from cdb_service\$ where name = '$service' ;
      commit ;
      " "      - Suppression du service de cdb_service\$" || die "Impossible de nettoyer cdb_service\$"
  fi
    exec_srvctl "add service -d $ORACLE_UNQNAME -s $service -r ${primDbName}1,${primDbName}2 -l $role -q TRUE -e SESSION -m BASIC -w 10 -z 150" \
                "      - Ajout de $service" \
                "Ok" "Erreur" "Impossible d'ajouter $service"
    exec_srvctl "start service -d $ORACLE_UNQNAME -s $service" \
                "      - Lancement de $service" \
                "Ok" "Erreur" "Impossible de lancer $service"
  if [ "$start" != "Y" ]
  then
    exec_srvctl "stop service -d $ORACLE_UNQNAME -s $service" \
                "          - Arret de $service (start=$start)" \
                "Ok" "Erreur" "mpossible de stopper $service"
  fi
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Cree l'ensemble des alias necessaires au fonctionnement du DG
#  on met à jour le tnsnames.ora associé à la base de données. 
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
tnsAliasesForDG()
{
  tnsFile=$TNS_ADMIN/tnsnames.ora
  tnsBackup=$tnsFile.$(date +%Y%m%d)
  printf "%-75s : " "    - Existence de $(basename $tnsFile)"
  [ -f $tnsFile ] && echo "Ok" || { echo "ERREUR" ; die "$tnsFile non trouve" ; }
  printf "%-75s : " "    - Existence de $(basename $tnsBackup)"
  if [ -f $tnsBackup ]
  then
    echo "OK"
  else
    echo "Non Trouve"
    printf "%-75s : " "      - backup dans $(basename $tnsBackup)"
    cp -p $tnsFile $tnsBackup && echo "OK" || die "Impossible de sauvegarder $tnsFile"
  fi

  echo  
  dbTmp=$(echo $1 | cut -f1 -d"_")
  domaine1=$5
  domaine2=${10}
  echo
  echo "      ============================="
  echo "    - Aliases pour les services"
  echo "      ============================="
  echo
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
  
  echo 

  for db in $1 $6
  do
    echo
    echo "      ============================="
    echo "    - Aliases pour $db"
    echo "      ============================="
    echo
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
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#      Ajoute ou remplace un alias dans le tnsnames.ora
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
addToTns()
{
  local TNS_FILE=$1
  local alias=$2
  local tns=$3
  printf "%-75s : " "          - Ajout de $alias"
  if grep "^[ \t]*$alias[ \t]*=" $TNS_FILE >/dev/null
  then
    echo "Existant a remplacer"
    printf "%-75s : " "            - Suppression Alias"
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
  printf "%-75s : " "            - Ajout alias"
  echo "$alias = $tns" >> $TNS_FILE 2>$$.tmp \
    && { echo "OK" ; rm -f $$.tmp $TNS_FILE.sv ; } \
    || { echo "ERREUR" ; cat $$.tmp ; rm -f $$.tmp ; cp -p $TNS_FILE.sv $TNS_FILE ; die "Erreur de mise a jour TNS (ajout $alias)" ; }
  echo
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#    Change un parametre si la valeur voulue n'est pas positionnée
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
changeParam()
{
  local param=$1
  local new_val=$2
  old_val=$(exec_sql "/ as sysdba" "select value from v\$parameter where name=lower('$param');")
  echo    "    - changement de $param --->"
  echo    "      - Valeur courante : $old_val"
  echo    "      - Nouvelle valeur : $new_val"
  o=$(echo $old_val | sed -e "s;^'*;;g" -e "s;'*$;;g")
  n=$(echo $new_val | sed -e "s;^'*;;g" -e "s;'*$;;g")
  if [ "$o" != "$n" ]
  then
    exec_sql "/ as sysdba" "alter system set $param=$new_val scope=both sid='*';" "        - Changement de valeur"
  else
    echo "        - Valeur correcte, inchangé"
  fi
  echo
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#   Verifie que le resultat d'un ordre SQL correspond a ce qui est attendu
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
checkDBParam()
{
  local lib=$1
  local sql=$2
  local res=$3
  printf "%-75s : " "    - $lib"
  v=$(exec_sql "/ as sysdba" "$sql")
  [ "$v" = "$res" ] && echo "OK" || { echo "ERR" ; die "Erreur de verification des conditions initiales" ; }
}

getPassDB()
{
  local dir=""
  if [ -d /acfs01/dbaas_acfs/$ORACLE_UNQNAME/db_wallet ]
  then
    dir=/acfs01/dbaas_acfs/$ORACLE_UNQNAME/db_wallet
  elif [ -d /acfs01/dbaas_acfs/$ORACLE_SID/db_wallet ]
  then
    dir=/acfs01/dbaas_acfs/$ORACLE_SID/db_wallet
  elif [ -d /acfs01/dbaas_acfs/$(echo $ORACLE_SID|sed -e "s;.$;;")/db_wallet ]
  then
    dir=/acfs01/dbaas_acfs/$(echo $ORACLE_SID|sed -e "s;.$;;")/db_wallet
  else
    echo
  fi
  mkstore -wrl $dir -viewEntry passwd | grep passwd | sed -e "s;^ *passwd = ;;"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
#      Suppression des repertoires de la base de donnes Stand-By
#  S'il y a un SPFILE on le sauvegarde et on le recree. S'il
#  n'y a pas de SPFILE, on essaie de trouver une ancienne sauvegarde
#
#     Si DELETEONLY n'est pas specifie, on recree les principaux
#  repertoires
#
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
cleanASMBeforeCopy()
{
  echo
  echo  "      
  ======================================================================
  
       Suppression de la base $laBase et mise en place des fichiers
  recopies depuis la PRIMAIRE (TDE et passwd)

       Si le fichier passwd est dans ASM,  il est sauvegarde
  puis recree au meme endroit.

       Au cas ou cette etape echoue, il est possible de la relancer.
  
  ======================================================================
  "
  local laBase=$1
  [ "$2" = "FORCE" ] && rep=Y || read -p "      Souhaitez vous la stopper et supprimer tous les fichiers y/[N] : " rep
  rep=${rep:N}

  if [ "${rep^^}" = "Y" ]
  then
    
    echo
    exec_dgmgrl "remove configuration" "Suppression de la configuration DGMGRL si elle existe"

    echo
    saveSpfile=$LOG_DIR/init_${stbyDbUniqueName}_${DAT}.ora
    exec_sql "/ as sysdba" "
whenever sqlerror continue
startup nomount;
whenever sqlerror exit failure
create pfile='$saveSpfile' from spfile;" "    - Sauvegarde du SPFILE" ; status=$?
    if [ $status -ne 0 ]
    then
      saveSpFile=""
      echo "      --> Pas de fichier SPFILE dans ASM"
      echo "          Recherche d'une precedente sauvegarde"
      saveSpfile=$(ls -1t $LOG_DIR/init*.ora | tail -1)
      echo "        --> INIT.ORA (Backup) : $saveSpfile"
    else
      echo "      --> INIT.ORA   : $saveSpfile"
    fi
    [ ! -f $saveSpFile ] && die "Impossible d'obtenir une sauvegarde du SPFILE"
    
    echo
    printf "%-75s : " "    - Emplacement du spfile"
    spfileLoc=$(srvctl config database -d $ORACLE_UNQNAME | grep "Spfile:" | cut -f2 -d" ") \
      && { echo "Ok" ; } \
      || { echo "Erreur" ; echo $spfileLoc ; die "Impossible de recuperer l'emplacementt du SPFILE" ; }
    echo "      --> SPFILE : $spfileLoc"

    echo
    printf "%-75s : " "    - Emplacement du Password File"
    pwfileLoc=$(srvctl config database -d $ORACLE_UNQNAME | grep "Password file" | sed -e "s;^.*: *;;") \
      && { echo "Ok" ; } \
      || { echo "Erreur" ; echo $pwfileLoc ; die "Impossible de recuperer l'emplacementt du SPFILE" ; }
    echo "      --> PWFILE : $pwfileLoc"
    if [ ! -f /tmp/${primDbUniqueName}_passwd.ora ]
    then
      exec_asmcmd "cp $pwfileLoc /tmp/${primDbUniqueName}_passwd.ora" \
                  "    - Sauvegarde du fichier password" "Ok" "Erreur" "Impossible de sauvegarder le fichier passwd"
    fi

    echo

    printf "%-75s : " "    - Arret de la base $laBase"
    srvctl stop  database -d $stbyDbUniqueName -o abort >/dev/null 2>&1 
    [ "$(ps -ef | grep smon_$ORACLE_SID | grep -v grep)" = "" ]  \
      && echo "Stoppee" \
      || die "Impossible de stopper la base $laBase"

    sleep 10

    . oraenv <<< $ASM_INSTANCE >/dev/null || die "Impossible de passer sous ASM"

    echo
    removeASMDir "+DATAC1/$stbyDbUniqueName"
    removeASMDir "+RECOC1/$stbyDbUniqueName"
    echo
    if [ "$2" != "DELETEONLY" ]
    then
      createASMDir +DATAC1/$stbyDbUniqueName
      createASMDir +DATAC1/$stbyDbUniqueName/PASSWORD
      createASMDir +DATAC1/$stbyDbUniqueName/DG
      createASMDir +RECOC1/$stbyDbUniqueName
      if [ -f /tmp/${primDbUniqueName}_passwd.ora ]
      then
       exec_asmcmd "pwcopy /tmp/${primDbUniqueName}_passwd.ora $pwfileLoc" \
                   "    - Copie du ficher passwd" "Ok" "Erreur" "mpossible de copier le fichier password"
      fi
    fi
    createASMDir "+DATAC1/$stbyDbUniqueName"

    . $stbyEnvFile || die "Impossible de positionner l'environnement de la base $stbyDbUniqueName"

    exec_sql "/ as sysdba" "
whenever sqlerror continue
startup nomount pfile='$saveSpfile';
whenever sqlerror exit failure
create spfile='$spfileLoc' from pfile='$saveSpfile' ;
shutdown abort; " \
             "    - Creation du SPFILE" || die "Impossible de recreer le SPFILE"

    if [ -f /tmp/${primDbUniqueName}_ewallet.p12 ]
    then
      echo
      printf "%-75s : " "    - Copie de ewallet.p12"
      cp /tmp/${primDbUniqueName}_ewallet.p12 /var/opt/oracle/dbaas_acfs/$primDbName/tde_wallet/ewallet.p12 \
         && { echo OK ; } \
         || die "Impossible de copier ewallet.p12"
    fi

    if [ -f /tmp/${primDbUniqueName}_cwallet.sso ]
    then
      echo
      printf "%-75s : " "    - Copie de cwallet.sso"
      cp /tmp/${primDbUniqueName}_cwallet.sso /var/opt/oracle/dbaas_acfs/$primDbName/tde_wallet/cwallet.sso \
         && { echo OK ; } \
         || die "Impossible de copier cwallet.sso"
    fi
  else
    die "Abandon de la procedure"
  fi
}
deleteStandBy()
{
  startRun "Suppression de la stand-by et dde la configuration DG"
  cleanASMBeforeCopy $stbyDbUniqueName DELETEONLY
  endRun
}
showVars()
{
  echo
  echo "==============================================================="
  echo
  echo "  - SCAN Local       : $scanLocal"
  echo "    --> $hostLocal ($portLocal)"
  echo "  - SCAN oppose      : $scanOppose"
  echo "    --> $hostOppose ($portOppose)"
  echo "  - Db server oppose : $dbServerOppose"
  echo "  - Base PRIMAIRE    : $primDbName ($primDbUniqueName)"
  echo "    --> Host         : $hostPrimaire - $portPrimaire"
  echo "    --> Scan         : $scanPrimaire"
  echo "    --> Tns          : $tnsPrimaire"
  echo "  - Base STANDBY     : $stbyDbName ($stbyDbUniqueName)"
  echo "    --> Host         : $hostStandBy - $portStandBy"
  echo "    --> Scan         : $scanStandBy"
  echo "    --> Tns          : $tnsStandBy"
  echo "  - TNS_ADMIN        : $TNS_ADMIN"
  echo "  - Execution sur    : $opePart"
  echo
  echo "==============================================================="
  echo
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#       Procedure principale qui va lancer la creation de la base
# stand-by ou la preparation de la primaire.
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
createDG()
{
  startRun "Creation d'une base stand-by"
  showVars

  if [ "$opePart" = "STANDBY" ]
  then

    startStep "Verifications et preparation"


    echo

    echo
    echo "    - On est sur la machine stand-by, la base ne doit pas pouvoir etre lancee"
    if [ "$(srvctl status database -d $stbyDbUniqueName | grep -i running | grep -vi "not running")" != "" ]
    then
      echo "      - La base est lancee, ... "
      printf "%-75s : " "  - Role de la base $laBase"
      if [ "$(ps -ef | grep "smon_${ORACLE_SID}" | grep -v grep | wc -l)" = "1" ]
      then
        dbRole=$(exec_sql "/ as sysdba" "select database_role from v\$database ;") 
      else
        dbRole="NonLancee"
      fi
      echo "$dbRole"
      if [ "$dbRole" = "PHYSICAL STANDBY" ]
      then
        echo "    --> Suite de la procedure"
        endStep
        finalisationDG
      elif [ "$dbRole" = "PRIMARY" ]
      then
        echo "  - La base est PRIMAIRE"
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
  printf "%-75s : " "    - Role de la base $laBase" 
  if [ "$(ps -ef | grep "smon_${ORACLE_SID}" | grep -v grep | wc -l)" = "1" ]
  then
    dbRole=$(exec_sql "/ as sysdba" "select database_role from v\$database ;") || die "Erreur a la recuperation du role de la base"
  else
    dbRole="NonLancee"
  fi
  echo $dbRole

  if [ "$dbRole" = "PRIMARY" -a "$opePart" = "PRIMARY" ]
  then
    preparePrimary
    
    if [    -f /tmp/${primDbUniqueName}_ewallet.p12 \
         -o -f /tmp/${primDbUniqueName}_cwallet.sso \
         -o -f /tmp/${primDbUniqueName}_passwd.ora ]
    then
      scpMessage="
    - copier manuellement les fichiers ci dessous sur $dbServerOppose
          /tmp/${primDbUniqueName}_ewallet.p12
          /tmp/${primDbUniqueName}_cwallet.sso
          /tmp/${primDbUniqueName}_passwd.ora
      dans le repertoire /tmp, puis effacez-les du serveur courant"
    else
     scpMessage="
      (Les fichiers necessaires a la mise en place de
       la base stand-by ont ete copies sur $dbServerOppose,
       vous n'avez pas d'operation manuelle a realiser)"
    fi  
    echo "

========================================================================

    La preparation de la base primaire est maintenant terminee, la
suite des operations de déroule depuis la machine stand-by.

    Pour continuer :

    - Connectez-vous à la machine de secours (noeud 1) et lancez :

    $0 -m RunOnStandBY -d $primDbUniqueName -D $stbyDbUniqueName -s $scanPrimaire -R
    
    puis :

    $0 -m RunOnStandBY -d $primDbUniqueName -D $stbyDbUniqueName -s $scanPrimaire

    Rajouter '-i' pour que le déroulement se fasse en interactif.

========================================================================
"
  elif [ "$dbRole" = "PRIMARY" -a "$opePart" = "STANDBY" ]
  then
    echo "
    ATTENTION : La base sur le serveur courant est primaire, 
    veuillez vérifier le serveur et supprimer la base manuellement 
    si nécessaire en utilisant la commande suivante:

    $0 -d $primDbUniqueName -D $stbyDbUniqueName -R

    puis relancer la procedure precedente:

    $0 -m RunOnStandBY -d $primDbUniqueName -D $stbyDbUniqueName -s $scanPrimaire 
  
    Rajouter '-i' pour que le déroulement se fasse en interactif.

  "
  elif [ "$dbRole" = "NonLancee" -a "$opePart" = "STANDBY" ]
  then
  if  [ "$aRelancerEnBatch" = "Y" ]
    then
      echo
      echo "+===========================================================================+"
      echo "|       Les principales verifications ont ete faites, le script va etre     |"
      echo "| Relance en tache de fond (nohup) avec les memes parametres                |"
      echo "+===========================================================================+"
      echo
      echo "  Le fichier log sera:"
      echo "   $LOG_FILE"
      echo 
      echo "+===========================================================================+"

      #
      #     On exporte les variables afin qu'elles soient reprises dans le script
      #

      export LOG_FILE
      export aRelancerEnBatch=N
      export dbPassword
      export stbyEnvFile
      rm -f $LOG_FILE
      nohup $0 -m RunOnStandBY -d $primDbUniqueName -D $stbyDbUniqueName -s $scanOppose >/dev/null 2>&1 &
      pid=$!
      waitFor=30
      echo " Script relance ..... (pid=$!) surveillance du process ($waitFor) secondes"
      echo -n "  Surveillance de $pid --> "
      i=1
      while [ $i -le $waitFor ]
      do
        sleep 1
        if ps -p $pid >/dev/null
        then
          [ $(($i % 10)) -eq 0 ] && { echo -n "+" ; } || { echo -n "." ; }
        else
           echo "Processus termine (erreur probable)"
           echo 
           echo "      --+--> Fin du fichier LOG"
           tail -15 $LOG_FILE | sed -e "s;^;        | ;"
           echo "        +----------------------"

           die "Le processus batch s'est arrete" 
        fi
        i=$(($i + 1))
      done  
      echo
      echo
      echo "+===========================================================================+"
      echo "La copie semble avoir ete lancee correctemenent"
      echo "+===========================================================================+"
      exit
    fi
    cleanASMBeforeCopy $laBase FORCE
    duplicateDBForStandBY
    [    -f /tmp/${primDbUniqueName}_ewallet.p12 \
      -o -f /tmp/${primDbUniqueName}_cwallet.sso \
      -o -f /tmp/${primDbUniqueName}_passwd.ora ] && rm -f /tmp/${primDbUniqueName}_ewallet.p12 \
                                                           /tmp/${primDbUniqueName}_cwallet.sso \
                                                           /tmp/${primDbUniqueName}_passwd.ora
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
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Execution de commandes DGMGRL avec gestion de la trace
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
exec_dgmgrl()
{
  local cmd=$1
  local lib=$2
  printf "%-75s : " "    - $lib"
  dgmgrl -silent sys/Wel_Come_12@$primDbUniqueName "$cmd" > $$.tmp 2>&1 \
    && { echo "OK" ; rm -f $$.tmp ; return 0 ; } \
    || { echo "ERREUR" ; cat $$.tmp ; rm -f $$.tmp ; return 1 ; }
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Execution de commandes SRVCTL avec gestion de la trace
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
exec_srvctl()
{
  SILENT=N
  [ "$1" = "-silent" ] &&  { local SILENT=Y ; shift ; }
  local cmd=$1
  local lib=$2
  local okMessage=$3
  local koMessage=$4
  local dieMessage=$5
  local tmpOut=${TMPDIR:-/tmp}/$$.tmp

  printf "%-75s : " "$lib"
  if srvctl $cmd > $tmpOut 2>&1 
  then
    echo "$okMessage" 
    rm -f $tmpOut
    return 0 
  else
    echo "$koMessage" 
    [ "$SILENT" = "N" ] && cat $tmpOut
    rm -f $tmpOut
    [ "$diemessage" = "" ] && return 1 || die "$dieMessage"
  fi
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Execution de commandes ASM avec gestion de la trace
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
exec_asmcmd()
{
  local cmd=$1
  local lib=$2
  local okMessage=$3
  local koMessage=$4
  local dieMessage=$5
  local tmpOut=${TMPDIR:-/tmp}/$$.tmp

  printf "%-75s : " "$lib"
  if asmcmd --privilege sysdba $cmd > $tmpOut 2>&1 
  then
    echo "$okMessage" 
    rm -f $tmpOut
    return 0 
  else
    echo "$koMessage" 
    cat $tmpOut
    rm -f $tmpOut
    [ "$diemessage" = "" ] && return 1 || die "$dieMessage"
  fi
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Suppression de repertoires
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
removeASMDir()
{
  local dir=$1

  if asmcmd --privilege sysdba ls -d $dir >/dev/null 2>&1
  then
    exec_asmcmd "rm -rf $dir" "    - Suppression du repertoire $dir" "Ok" "Erreur" "Impossible de supprimer $dir"
    return $?
  else
    return 0
  fi
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Creation de repertoires
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
createASMDir()
{
  local dir=$1
  if ! asmcmd --privilege sysdba ls -d $dir >/dev/null 2>&1
  then
    exec_asmcmd "mkdir $dir" "    - Creation du repertoire $dir" "Ok" "Erreur" "Impossible de creer $dir"
    return $?
  else
    return 0
  fi
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
         [-s scan]
         [-C|-R|-V] [-h|-?]

         primDbName   : Base PRIMAIRE (db Unique Name)
         stbyDbName   : Base StandBy (db Unique Name - elle doit exister)
         scan         : Adresse Scan (host:port) de la contrepartie: Defaut HPR
         -C           : Copie et migration d'une base (le script se relance
                        en nohup apres que les premieres verifications sont faites
                        sauf si -i est precise)
         -R           : Supprime la base (a lancer sur machine stand-by)
         -V           : Verification de fonctionnement
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

[ "$(id -un)" != "oracle" ] && die "Merci de lancer ce script depuis l'utilisateur \"oracle\""
[ "$(hostname -s | sed -e "s;.*\([0-9]\)$;\1;")" != "1" ] && die "Lancer ce script depuis le premier noeud du cluster"

[ "$1" = "" ] && usage
toShift=0
while getopts m:d:D:s:hCRTVi opt
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
   V)   mode=VERIFICATION        ; toShift=$(($toShift + 1)) ;;
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
#      Base de données source (Db Unique Name)
#
if [ "$(echo $primDbName | grep "_")" != "" ]
then
  primDbUniqueName=$primDbName
  primDbName=$(echo $primDbName | cut -f1 -d"_")
else
  die "Donner un DB Unique Name complet (base_suffixe)"
fi

if [ "$(echo $stbyDbName | grep "_")" != "" ]
then
  stbyDbUniqueName=$stbyDbName
  stbyDbName=$(echo $stbyDbName | cut -f1 -d"_")
else
  die "Donner un DB Unique Name complet (base_suffixe)"
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
ASM_INSTANCE=$(ps -ef | grep smon_+ASM | grep -v grep |sed -e "s;^.*+ASM;+ASM;")

if [ "$LOG_FILE" = "" ]
then
  case $mode in
    CREATE)       LOG_FILE=$LOG_DIR/dataGuard_CRE_${primDbName}_${DAT}.log ;;
    DELETE)       LOG_FILE=$LOG_DIR/dataGuard_DEL_${primDbName}_${DAT}.log ;;
    TEST)         LOG_FILE=/dev/null                                       ;;
    VERIFICATION) LOG_FILE=/dev/null                                       ;;
    *)            die "Mode inconnu"                                       ;;
  esac
fi

# -----------------------------------------------------------------------------
#    Controles basiques (il faut que l'on puisse poitionner l'environnement
# base de données cible (et que ce soit la bonne!!!
# -----------------------------------------------------------------------------
checkDir $LOG_DIR || die "$LOG_DIR is incorrect"
primEnvFile=${primEnvFile:-$HOME/$primDbName.env}
stbyEnvFile=${stbyEnvFile:-$HOME/$stbyDbName.env}
if [ "$mode" = "CREATE" ]
then
  if [ "$opePart" = "PRIMARY" ]
  then

    . $primEnvFile || die "Impossible de positionner l'environnement PRIMAIRE"
    [ "$ORACLE_UNQNAME" != "$primDbUniqueName" ] && die "Attention, l'environnement positionne ne correspond pas a : $primDbUniqueName"
    echo "    - Mode : CREATE (Depuis base PRIMAIRE ($ORACLE_UNQNAME)"

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

  elif [ "$opePart" = "STANDBY" ]
  then

    . $stbyEnvFile || die "Impossible de positionner l'environnement STANDBY"
    [ "$ORACLE_UNQNAME" != "$stbyDbUniqueName" ] && die "Attention, l'environnement positionne ne correspond pas a : $stbyDbUniqueName"
    echo "    - Mode : CREATE (Depuis base STANDBY ($ORACLE_UNQNAME)"

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
  tnsTestConnect=$tnsPrimaire
elif [ "$mode" = "VERIFICATION" -o "$mode" = "TEST" ]
then
  if grep "^${stbyDbUniqueName}:" /etc/oratab >/dev/null 2>&1
  then
    . $stbyEnvFile || die "Impossible de positionner l'environnement STANDBY"
    [ "$ORACLE_UNQNAME" != "$stbyDbUniqueName" ] && die "Attention, l'environnement positionne ne correspond pas a : $stbyDbUniqueName"
    echo "    - Mode : VERIFICATION (Depuis base STAND-BY ($ORACLE_UNQNAME)"
  else
    . $primEnvFile || die "Impossible de positionner l'environnement PRIMAIRE"
    [ "$ORACLE_UNQNAME" != "$primDbUniqueName" ] && die "Attention, l'environnement positionne ne correspond pas a : $primDbUniqueName"
    echo "    - Mode : VERIFICATION (Depuis base PRIMAIRE ($ORACLE_UNQNAME)"
  fi
  tnsTestConnect=$ORACLE_UNQNAME
elif [ "$mode" = "DELETE" ]
then
  . $stbyEnvFile || die "Impossible de positionner l'environnement STANDBY"
  [ "$ORACLE_UNQNAME" != "$stbyDbUniqueName" ] && die "Attention, l'environnement positionne ne correspond pas a : $stbyDbUniqueName"
    echo "    - Mode : DELETE (Depuis base PRIMAIRE ($ORACLE_UNQNAME)"
  tnsTestConnect=
fi

dbServerOppose=$(echo $hostOppose | sed -e "s;^\(.*\)\(-scan\)\(.*\)$;\11\3;")

#showVars
#exit

# -----------------------------------------------------------------------------
#      Lancement de l'exécution
# -----------------------------------------------------------------------------
if [ "$tnsTestConnect" != "" ]
then
  if  [ "$dbPassword" = "" ]
  then
    . $stbyEnvFile || die "Impossible de positionner l'environnement de la base $stbyDbName"
    printf "%-75s : " "    - Recuperation du mot de passe dans le wallet DBaaS"
    dbPassword=$(getPassDB)   
    [ "$dbPassword" != "" ] && echo "OK" || echo "Vide"
    if [ "$dbPassword" != "" ]
    then
      printf "%-75s : " "    - Verification de la connection a la base source"
      res=$(exec_sql "sys/${dbPassword}@$tnsTestConnect as sysdba" "select 'X' from dual ;")
      [ "$res" != "X" ] && { dbPassword="" ; echo "Incorrect" ; echo "$res" ; } || echo OK
    fi
  fi
  if [ "$dbPassword" = "" ]
  then
    echo "
    Le mot de passe dans le wallet de la base courante ne semble pas etre
  celui de la base primaire, entrez le mot de passe (ou changer celui du wallet).
  "
    read -sp "    - Mot de passe SYS de la base primaire : " dbPassword
    echo
    printf "%-75s : " "    - Verification de la connection a la base source"
    res=$(exec_sql "sys/${dbPassword}@$tnsTestConnect as sysdba" "select 'X' from dual ;")
    [ "$res" != "X" ] && { dbPassword="" ; echo "Incorrect" ; echo "$res" ; die "MOt de passe de la base primaire incorrect" ; } || echo OK
  fi
fi

case $mode in
 CREATE)         createDG       2>&1 | tee $LOG_FILE ;;
 DELETE)         deleteStandBy  2>&1 | tee $LOG_FILE ;;
 TEST)           testUnit       2>&1 | tee $LOG_FILE ;;
 VERIFICATION)   verificationDG 2>&1 | tee $LOG_FILE ;;
esac

