VERSION=1.0
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
#   Appelé par l'option -T, permet de tester des parties de script
#
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
testUnit()
{
  startStep "Test de fonctionnalites"
  echo   " Base Source "
  echo   " =========== "
  echo   "    CDB          : $srcDbName"
  echo   "    PDB          : $srcPdbName"
  echo   "    Scan         : $scanAddress"
  echo   "    Service      : $SERVICE_NAME"
  echo   " Base cible "
  echo   " =========== "
  echo   "    CDB          : $dstDbName"
  echo   "    PDB          : $dstPdbName"
  echo   " Parallel        : $PARALLEL"

  
  checkBeforeCopy

  endStep
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#       Clonage d'une PDB et migration si nécessaire (-C)
#
#
#    Le paramètres nécéssaires sont:
#    ==============================
#
#    1) le nom de la base source    (-d) : DB UNIQUE NAME complet
#    2) Le nom de la PDB source     (-p)
#    3) L'adresse SCAN de la source (-s) : host:port
#    3) le nom de la base cible     (-D) : Par défaut identique à la 
#                                          source
#    4) Le nom de la PDB cible      (-P) : Par défaut identique à la
#                                          source
#
#    Le mode de passe de TDE (-k) est récupéré dans le wallet
#  dbaas si celui-ci est accessible. Le parallélisme peu être 
#  contrôlé avec (-L). Si (-i) est spécifié, l'exécution est 
#  entièrement faite en interactif (attention aux déconnexions)
#
#   Fonctionnement
#   ==============
#    
#    Le clonage se fait avec un common user à créer sur la source.
# si ce common USER n'existe pas, le script s'arrête et propose
# les commandes à passer sur la ,base source (copie/coller)
#
#
#    A moins que l'option -i ne soit spécifiés dans les paramètres d'appel,
#  le script, lancé en interactif opère les premières vérifications, puis 
#  se relance automatiquement en nohup. Après ce lancement, on attend 30
#  secondes avant de rendre la main pour vérifier qu'il n'y a pas d'erreur 
#  au début de la copie.
#
#    - On récupère de la source, la liste des tablespaces et des fichier
#      les paramètres dont la valeur n'est pas par défaut, les nombres
#      dobjets invalides par schéma et type.
#    - La copie est faite avec un niveau de parallélisme par défaut
#      on peut le changer avec (-L)
#    - Si la PDB existe déjà, le cript continue et on passe
#      a la partie migration.
#    - La décision de lancer le DB upgrade dépend de l'état de la
#      base à l'ouverture. Si on est en MIGRATE, on lance dbupgrade
#    - Apres upgrade:
#      - Recompilation des schémas, après compilation, si des 
#        vues matérialisées sont invalides, on les détruit et 
#        on les recrée.
#      - LIste des objets invalides, tablespaces et paramètres
#      - Une dernière liste présente les valeurs de paramètres 
#        différents entre les deux bases.
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
copyAndMigrate()
{
  startRun "Copie et migration de la PDB ($srcPdbName@$srcDbName)"


  echo   " Base Source "
  echo   " =========== "
  echo   "    CDB          : $srcDbName"
  echo   "    PDB          : $srcPdbName"
  echo   "    Scan         : $scanAddress"
  echo   "    Service      : $SERVICE_NAME"
  echo   " Base cible "
  echo   " =========== "
  echo   "    CDB          : $dstDbName"
  echo   "    PDB          : $dstPdbName"
  echo   " Parallel        : $PARALLEL"
  # 
  # -----------------------------------------------------------------------------------------
  # 

  startStep "Verifications et preparation"

  checkBeforeCopy

  if  [ "$aRelancerEnBatch" = "Y" ]
  then
    echo
    echo "+===========================================================================+"
    echo "|       Les principales verifications ont ete faites, le script va etre     |"
    echo "| Relance en tache de fond (nohup) avec les memes parametres                |"
    echo "+===========================================================================+"
    echo
    echo "  Le fichier log sera:"
    echo "       $(basename $LOG_FILE)"
    echo "  dans $(dirname  $LOG_FILE)"
    echo 
    echo "+===========================================================================+"

    #
    #     On exporte les variables afin qu'elles soient reprises dans le script
    #  On ne repasse pas le mot de passe TDE sur la ligne de commande
    #
    export LOG_FILE
    export keyStorePassword
    export scanAddress
    export parallelDegree  
    export aRelancerEnBatch=N
    rm -f $LOG_FILE
    nohup $0 -d $srcDbName -p $srcPdbName -D $dstDbName -P $dstPdbName >/dev/null 2>&1 &
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


  getParameters      "$SRC_CONNECT_STRING" "$srcPdbName" "Source"
  getDatafiles       "$SRC_CONNECT_STRING" "$srcPdbName" "Source"
  getInvalidObjects  "$SRC_CONNECT_STRING" "$srcPdbName" "Source"

  endStep 

  # 
  # -----------------------------------------------------------------------------------------
  # 

  startStep "Recopie de la PDB"
  

  if [ "$dstPdbExists" = "N" ]
  then
    exec_sql       "/ as sysdba "      "
create pluggable database $dstPdbName
from  ${srcPdbName}@$DBLINK $PARALLEL
keystore identified by \"$keyStorePassword\" ;"                                "     - Recopie de ${srcPdbName}@$DBLINK dans $dstPdbName" \
            || die "Erreur de copie de la PDB"
  else
    echo "     - la PDB existe deja"
  fi
                            
  endStep 

  # 
  # -----------------------------------------------------------------------------------------
  # 

  startStep "Upgrade de la PDB"


  openMode=$(exec_sql "/ as sysdba" "select open_mode from v\$pdbs where name=upper('$dstPdbName');")
  if [ "$openMode" = "READ WRITE" ]
  then
    #
    #    Si la base est ouverte Read/Write, c'est normalement qu'elle est dans la bonne version
    #
    echo "     - La base est ouverte, on ne fait rien, pas besoin d'upgrade"
  else
    exec_sql      "/ as sysdba "   "alter pluggable database $dstPdbName close immediate instances=all ; "       "     - Fermeture PDB" \
            || die "Impossible de fermer la PDB Copiee"

    exec_sql      "/ as sysdba "   "alter pluggable database $dstPdbName open ; "                                "     - Tentative d'ouverture" \
            || die "Impossible d'ouvrir la base Copiee"

    openMode=$(exec_sql "/ as sysdba" "select open_mode from v\$pdbs where name=upper('$dstPdbName');")
    echo "       ====> [$openMode]"
    if [ "$openMode" = "MIGRATE" ]
    then
      #
      #      La base a besoin d'être mise à niveau, on lance l'upgrade
      #
      echo "     - Upgrade ....."
      dbupgrade -c $dstPdbName 2>&1 | sed -e "s;^;          ;" \
               || die "Erreur d'upgrade"
    elif [ "$openMode" = "READ WRITE" ]
    then
      echo "     - La base est ouverte, on ne fait rien"
    else
      echo "       =====> Et là, on fait quoi?????"
    fi
  fi

  endStep 


  # 
  # -----------------------------------------------------------------------------------------
  # 

  startStep "Controles et ouverture"
  exec_sql      "/ as sysdba"      "

clear columns
set lines 200
set pages 200
col message format a55
col status format a10
col action format a55
col time format a30
set recsep off
set tab off

select message,time,status,action from pdb_plug_in_violations ;"

  exec_sql     "/ as sysdba"     "alter pluggable database $dstPdbName close immediate instances = all;"     "     - Fermeture PDB" \
          || die "Impossible de fermer la base, migration effectuee"
  exec_sql     "/ as sysdba"     "alter pluggable database $dstPdbName open;"                                "     - Ouverture PDB" \
          || die  "Impossible d'ouvrir la base, migration effectuee"
  exec_sql     "/ as sysdba"     "alter pluggable database $dstPdbName save state;"                          "     - Enregistrement etat" \
          || die "Impossible d'enregistrer l'etat de la PDB migration effectuee"
  
  getParameters      "/ as sysdba" "$dstPdbName" "Cible"
  getDatafiles       "/ as sysdba" "$dstPdbName" "Cible"
  endStep

  # 
  # -----------------------------------------------------------------------------------------
  # 

  startStep "Recompilation finale et recreation des vues materielises si necessaire"
  recompEtVuesMat
  getInvalidObjects  "/ as sysdba" "$dstPdbName" "Cible"
  compareParametres
  addServices
  endStep

  
  # 
  # -----------------------------------------------------------------------------------------
  # 
  
  endRun

}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
#     Suppression d'une PDB (-R)
#
#    Le paramètres nécéssaires sont:
#    ==============================
#
#    1) le nom de la base cible    (-D) : DB NAME (fichier .env)
#    2) Le nom de la PDB cible     (-P)
#
#    Fonctionnement
#    ==============
#
#    Droppe la PDB si elle existe. Attention à ne pas exécuter ce
#  script sur une machine source!!!
#
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
deletePdb()
{
  startRun "Suppression PDB $dstPdbName@dstDbName"
  # 
  # -----------------------------------------------------------------------------------------
  # 
  startStep "Verifications et preparation"

  exec_sql       "/ as sysdba " "select 1 from dual ;"                              "  - Connexion SYSDBA a la cible" \
          || die "Unable to connect to the database"
  
  res=$(exec_sql "/ as sysdba"  "select 1 from v\$pdbs where name=upper('$dstPdbName');") || die "Erreur select PDB cible ($res)"
  printf "%-75s : " "  - Existence PDB Cible ($dstPdbName)"
  [ "$res" = "" ] && { echo "Non existante" ; dstPdbExists=N ; die "PDB Inexistante" ; }  \
                  || { echo "Existante" ; dstPdbExists=Y ; }
  
  endStep
  # 
  # -----------------------------------------------------------------------------------------
  # 
  startStep "Suppression PDB"
  
  exec_sql       "/ as sysdba " "alter pluggable database $dstPdbName close immediate instances=all ; " "     - Fermeture PDB" || die
  exec_sql       "/ as sysdba " "drop pluggable database $dstPdbName including datafiles ; "            "     - Suppression PDB" || die

  endStep

  # 
  # -----------------------------------------------------------------------------------------
  # 

  endRun
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
#     Vérification des pré-requis avant de réaliser une opération
#
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
checkBeforeCopy()
{
  exec_sql           "/ as sysdba "        "select 1 from dual ;"                                "  - Connexion SYSDBA a la cible"     \
          || die "Unable to connect to the database"

  exec_sql           "$SRC_CONNECT_STRING" "select 1 from dual ;"                                "  - Connexion $MIG_USER a la source" \
          || die "     

          Impossible de se connecter a l'utilisteur de clonage sur le source
     veuillez executer les commandes suivantes sur la machine source sous le compte oracle (copier/coller)

# --------------------------------------------------------------

. \$HOME/$(echo $srcDbName | cut -f1 -d "_").env && \
sqlplus / as sysdba <<%%
drop user $MIG_USER cascade ;
create user $MIG_USER identified by \"$MIG_PASS\" ;
grant 
   create session
  ,select any dictionary
  ,create pluggable database
  ,set container
to $MIG_USER container=all;
alter user $MIG_USER set container_data=all container=current;
%%

# --------------------------------------------------------------

         et relancer l'operation.

                "
  echo

  exec_sql -no_error "/ as sysdba"         "drop database link $DBLINK ; "                       "  - Suppression database link $DBLINK" 

  exec_sql           "/ as sysdba"         "
create  database link $DBLINK 
connect to $MIG_USER identified by \"$MIG_PASS\"
using   '//$scanAddress/$SERVICE_NAME' ;"                                                        "  - Creation database link $DBLINK" \
          || die "Impossible  de creer le DATABASE LINK"


  exec_sql           "/ as sysdba"         "alter system set global_names=FALSE scope=memory ;"  "  - Global_names=false (memory)" \
          || die "Impossble de changer la valeur"

  exec_sql           "/ as sysdba"         "select dummy from dual@$DBLINK;"                     "  - Verification du DBLINK" \
          || die "Impossble de lire via $DBLINK"

  echo

  res=$(exec_sql "/ as sysdba" "select 1 from cdb_pdbs where pdb_name=upper('$dstPdbName');") \
                || die "Erreur select PDB cible ($res)"

  printf "%-75s : " "  - Existence PDB Cible ($dstPdbName)" 
  [ "$res" = "" ] && { echo "Non existante" ; dstPdbExists=N ; }  \
                  || { echo "Existante" ; dstPdbExists=Y ; }

  res=$(exec_sql "$SRC_CONNECT_STRING" "select 1 from cdb_pdbs where pdb_name=upper('$srcPdbName');") \
                || die "Erreur select PDB SOurce ($res)"
  printf "%-75s : " "  - Existence PDB Source ($srcPdbName)"
  [ "$res" = "" ] && { echo "Non existante" ; srcPdbExists=N ; die "La PDB Source n'existe pas" ; }  \
                  || { echo "Existante" ; srcPdbExists=Y ; }


  wrl=$(exec_sql "/ as sysdba" "select wrl_parameter from v\$encryption_wallet where con_id=1;")
 
  echo
  echo "    TDE : $wrl"
  printf "%-75s : " "  - Verification du mot de passe TDE"
  echo $keyStorePassword |  mkstore -wrl $wrl -list >/dev/null
  [ $? -eq 0 ] && { echo "OK" ; } ||  { echo "Erreur" ; die "Mot de passe TDE invalide" ; }
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
#      Affiche les paramètres ayant des valeurs différentes sur la 
#  source et la cible. Niveaux CDB et PDB
#
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
compareParametres()
{
  echo
  echo "  - Parametres ayant des valeurs differentes dans les SPFILES"
  echo "    ========================================================="
  echo

exec_sql "/ as sysdba" "
set feedback on
col name format a40 trunc
col inst_id format 9      heading "I"
col value_src format a30
col value_dst format a30
col src_pdb format a10
col dst_pdb format a10
set heading on pages 2000

break on name on src_pdb
with 
source_parameters as (
select 
  * 
/**/from (
    SELECT
        p.name,
        p.value,
        p.inst_id,
        /**/nvl(d.name, 'CDB\$ROOT') pdb_name,
        p.con_id
    FROM
        gv\$system_parameter@$DBLINK  p
        LEFT OUTER JOIN (
            SELECT
                'PDB' name
                ,con_id
            FROM
                v\$pdbs@$DBLINK
            WHERE
                name = upper('$srcPdbName')) d ON ( p.con_id = d.con_id )
      )
where 
  con_id in (       SELECT 0      from dual@$DBLINK
              UNION SELECT con_id FROM v\$pdbs@$DBLINK WHERE  name = upper('$srcPdbName'))
)
,target_parameters as (
select 
  * 
/**/from (
    SELECT
        p.name,
        p.value,
        p.inst_id,
/**/        nvl(d.name, 'CDB\$ROOT') pdb_name,
        p.con_id
    FROM
        gv\$system_parameter  p
        LEFT OUTER JOIN (
            SELECT
                'PDB' name
                ,con_id
            FROM
                v\$pdbs
            WHERE
                name = upper('$dstPdbName')) d ON ( p.con_id = d.con_id )
      )
where 
  con_id in (       SELECT 0      from dual
              UNION SELECT con_id FROM v\$pdbs WHERE  name = upper('$dstPdbName'))
)
select 
  * 
/**/from (
    SELECT
   /**/     nvl(src.name, dst.name)                 name,
        src.pdb_name                            src_pdb,
        --dst.pdb_name                            dst_pdb,
   /**/     nvl(src.inst_id, dst.inst_id)           inst_id,
        src.value                               value_src,
        dst.value                               value_dst
     --   ,src.con_id src_con_id
     --   ,dst.con_id dst_con_id
    FROM
        source_parameters  src
        FULL OUTER JOIN target_parameters  dst ON ( src.name = dst.name
                                                   AND src.inst_id = dst.inst_id
                                                   AND src.pdb_name = dst.pdb_name )
      )
where 1=1
  and  value_src != value_dst
  and name not in ('background_dump_dest'      ,'cluster_interconnects'      ,'control_files'      ,'core_dump_dest'
                  ,'audit_file_dest'           ,'db_domain'                  ,'db_unique_name'     ,'dg_broker_config_file1'
                  ,'local_listener'            ,'dg_broker_config_file2'     ,'remote_listener'    ,'service_names'
                  ,'spfile'                    ,'user_dump_dest')
  and name not like 'log_archive%'
ORDER BY
    1,
    2,
    2,
    4
/

"
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Récupère la liste des paramètres modifiés sur une base
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
getParameters()
{
  local cnx=$1
  local pdb=$2
  local label=$3
  echo
  echo " - Parametres non par defaut sur la base $label"
  echo "   --------------------------------------------"
  echo
  exec_sql      "$cnx" "\
set pages 2000
set lines 400
set trimout on
set tab off
set heading on
set feedback on

column name format  a50
column value format a100 

alter session set container=$pdb ;

select 
  name
  ,value
from 
  v\$parameter 
where 
  isdefault='FALSE' ;

                " || die "Erreur a la recuperation des parametres de la $label"
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Récupère la liste des fichiers par tablespace
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
getDatafiles()
{
  local cnx=$1
  local pdb=$2
  local label=$3
  echo
  echo " - Liste des tablespaces et fichiers de la base $label"
  echo "   ----------------------------------------------------"
  echo
  exec_sql      "$cnx" "\
set pages 2000
set lines 400
set trimout on
set tab off
set heading on
set feedback on

break on tablespace_name skip 1 on report
compute sum of size_GB on report

column tablespace_name format a30
column file_name format a100
column size_GB  format 999G999G999D99

alter session set container=$pdb ;

select 
   tablespace_name
  ,file_name
  ,bytes/1024/1024/1024 size_GB
from
  dba_data_files 
order by tablespace_name, file_name;

                " || die "Erreur a la recuperation des fichiers de la base $label"
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#    LIste les objets invalides
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
getInvalidObjects()
{
  local cnx=$1
  local pdb=$2
  local label=$3
  echo
  echo " - Objets Invalides sur la base $label"
  echo "   --------------------------------------------"
  echo
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

                " || die "Erreur a la recuperation des parametres de la $label"
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#      Recompile et recrée les vues matérialisées (si nécessaire) en fait, 
#  c'est juste du PL/SQL!!!
#  
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
recompEtVuesMat()
{
  exec_sql "/ as sysdba" "
set feedback on
alter session set container=$dstPdbName ;

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
          dbms_output.put_line('.                Erreur a l''execution de : ' || stmt) ;
          raise ;
        end ;
      end if ;
      i := i+1 ;
    end loop ;
  end ;
begin
  dbms_output.put_line('.');
  dbms_output.put_line('.  Traitement post-upgrade');
  dbms_output.put_line('.  =======================');
  dbms_output.put_line('.');
  for invalidSchemas in (select owner,count(*) nb_invalid 
                         from dba_objects 
                         where status = 'INVALID' and owner not in ('SYS','PUBLIC')
                         group by owner
                        )
  loop
    dbms_output.put_line ('.');
    dbms_output.put_line (rpad(invalidSchemas.owner,20) || ': ' || invalidSchemas.nb_invalid || ' objets invalides') ;
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
      dbms_output.put_line('.             Reste : ' || reste || ' Objets invalides') ;
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
        dbms_output.put_line('.                  Reste : ' || reste || ' Objets invalides') ;
      end if ;
    end if ;
  end loop;
end ;
/
"
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#      Crée ou recrée les 4 services standards
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
addServices()
{
  echo
  echo "  - Ajout des services"
  echo "    ------------------"
  echo
  for SERVICE_SUFFIX in art batch api mes
  do
    sn=${dstPdbName,,}_${SERVICE_SUFFIX}
    echo    "    - $sn"

    if [ "$(srvctl status service -d $ORACLE_UNQNAME -s $sn | grep -i "is running")" != "" ]
    then
      echo -n "      - Arret           : "
      srvctl stop  service -d $ORACLE_UNQNAME -s $sn && echo "Ok" || die "Impossible de stopper le service $sn"
    fi

    if [ "$(srvctl status service -d $ORACLE_UNQNAME -s $sn | grep -i "does not exist")" = "" ]
    then
      echo -n "      - Suppression     : "
      srvctl remove   service -d $ORACLE_UNQNAME -s $sn && echo "Ok" || die "Impossible de supprimer le service $sn"
    fi

    sidPrefix=$(echo $ORACLE_SID  | sed -e "s;[0-9]$;;")
    echo -n "      - Creation        : "
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
                         && echo "Ok" || die "Impossible d'ajouter le service $sn"

    if [ "$(srvctl status service -d $ORACLE_UNQNAME -s $sn | grep -i "does not have defined services")" = "" ]
    then
      echo -n "      - Lancement       : "
      srvctl start service -d $ORACLE_UNQNAME -s $sn && echo "Ok" || die "Impossible d'ajouter le service $sn"
    else
      die "Service $sn non cree"
    fi

  done
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
                      || { echo "OK" ; [ "$VERBOSE" = "Y" ] && test -f $REDIR_FILE && cat $REDIR_FILE ; }
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
 echo "

Usage :
 $SCRIPT [-d srcDbName] [-p srcPdbName] [-D dstDbName] [-P dstPdbName] 
         [-k keyStorePass] [-s scan] [-L degreParal]  
         [-C|-R] [-h|-?]

         srcDbName    : Base source (db Unique Name complet)
         srcPdbName   : PDB Source
         dstDbName    : Base Cible (DB NAME)     : Defaut (deduit de la source, 
                                                   DBNAME seulement)
         dstPdbName   : PDB Cible                : Defaut la meme que la source
         keyStorePass : MOt de passe TDE Cible, necessaire seulement
                        si on ne peut pas le recuperer dans le Wallet
         scan         : Adresse Scan (host:port) : Defaut HPR
         degreParal   : Parallelisme             : Defaut 150
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

SCRIPT=migRunDest.sh

[ "$1" = "" ] && usage
toShift=0
while getopts :d:p:D:P:k:s:L:CRTi opt
do
  case $opt in
   # --------- Source Database --------------------------------
   d)   srcDbName=$OPTARG        ; toShift=$(($toShift + 2)) ;;
   p)   srcPdbName=$OPTARG       ; toShift=$(($toShift + 2)) ;;
   # --------- Target Database --------------------------------
   D)   dstDbName=$OPTARG        ; toShift=$(($toShift + 2)) ;;
   P)   dstPdbName=$OPTARG       ; toShift=$(($toShift + 2)) ;;
   # --------- Keystore, Scan ... -----------------------------
   k)   keyStorePassword=$OPTARG ; toShift=$(($toShift + 2)) ;;
   s)   scanAddress=$OPTARG      ; toShift=$(($toShift + 2)) ;;
   L)   parallelDegree=$OPTARG   ; toShift=$(($toShift + 2)) ;;
   # --------- Modes de fonctionnement ------------------------
   C)   mode=COPY                ; toShift=$(($toShift + 1)) ;;
   R)   mode=DELETE              ; toShift=$(($toShift + 1)) ;;
   T)   mode=TEST                ; toShift=$(($toShift + 1)) ;;
   i)   aRelancerEnBatch=N       ; toShift=$(($toShift + 1)) ;;
   # --------- Usage ------------------------------------------
   ?|h) usage ;;
  esac
done
shift $toShift 

# -----------------------------------------------------------------------------
#
#       Analyse des paramètres et valeurs par défaut
#
# -----------------------------------------------------------------------------

#
#      Base de données source (Db Unique Name)
#
srcDbName=${srcDbName:-tmpmig_fra15w}
srcPdbName=${srcPdbName:-TST1}
#
#      Base de données cible (DB Name , par défaut, le même que la
#  source, même PDB 
#
if [ "$dstDbName" = "" ]
then
  dstDbName=$(echo $srcDbName | cut -f1 -d"_")   # Par défaut, on prend la partie DBNAME du DB UNIQUE name Source
fi
if [ "$dstPdbName" = "" ]
then
  dstPdbName=${srcPdbName}                       # Par défaut, identique à la source
fi
#
#   Mode de fonctionnement
#
mode=${mode:-COPY}                               # Par défaut Copie
aRelancerEnBatch=${aRelancerEnBatch:-Y}          # Par défaut, le script de realne en nohup après les
                                                 # vérifications (pour la copie seulement)
#
#   Adresse SCAN (Par défaut, HPR) DOMAINE=même domaine que
# le scan.
#
if [ "$scanAddress" = "" ]
then
  scanAddress="hprexacs-7sl1q-scan.dbad2.hpr.oraclevcn.com:1521"
fi

parallelDegree=${parallelDegree:-150}            # Défaut 150
DOMAIN=$(echo $scanAddress | sed -e "s;^[^\.]*\.\([^\:]*\).*$;\1;")  # Domaine du Scan
SERVICE_NAME=$srcDbName.$DOMAIN

# -----------------------------------------------------------------------------
#
#    Constantes et variables dépendantes
#
# -----------------------------------------------------------------------------
DBLINK=pdbclone                              # Nom du DB LInk
PARALLEL="PARALLEL $parallelDegree"          # Parallélisme
DAT=$(date +%Y%m%d_%H%M)                     # DATE (for filenames)
BASEDIR=$HOME/migrate19                      # Base dir for logs & files
LOG_DIR=$BASEDIR/$srcDbName                  # Log DIR
MIG_USER="C##PDBCLONE"                       # Cible du DBLINK
MIG_PASS="SBT48UMwPJIjsFUilwFz"              # MOt de passe
SRC_CONNECT_STRING="\"$MIG_USER\"/\"$MIG_PASS\"@//$scanAddress/$SERVICE_NAME"

if [ "$LOG_FILE" = "" ]
then
  case $mode in
    COPY)      LOG_FILE=$LOG_DIR/migRun_MIG_${dstDbName}_${dstPdbName}_${DAT}.log ;;
    DELETE)    LOG_FILE=$LOG_DIR/migRun_DEL_${dstDbName}_${dstPdbName}_${DAT}.log ;;
    TEST)      LOG_FILE=/dev/null ;;
    *)         die "Mode inconnu" ;;
  esac
fi

# -----------------------------------------------------------------------------
#    Controles basiques (il faut que l'on puisse poitionner l'environnement
# base de données cible (et que ce soit la bonne!!!
# -----------------------------------------------------------------------------

checkDir $LOG_DIR || die "$LOG_DIR is incorrect"
[ -f "$HOME/$dstDbName.env" ] || die "$dstDbName.env non existent"
. "$HOME/$dstDbName.env"
[ "$(exec_sql "/ as sysdba" "select  name from v\$database;")" != "${dstDbName^^}" ] && die "Environnement mal positionne"

# -----------------------------------------------------------------------------
#    Récupération du mot de passe TDE
# -----------------------------------------------------------------------------

if [ "$keyStorePassword" = "" ]
then
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
    die "Impossible de trouver le repertoire du Wallet dbaas, utiliser l'option -k pour fournir le mot de passe TDE de la base cible"
  fi
  keyStorePassword=$(mkstore -wrl $dir -viewEntry tde_ks_passwd | grep tde_ks_passwd | cut -f2 -d"=" | sed -e "s;^ *;;")
fi
[ "$keyStorePassword" = "" ] && die "Mot de passe TDE inconnu, utiliser -"

# -----------------------------------------------------------------------------
#      Lancement de l'exécution
# -----------------------------------------------------------------------------

case $mode in
 COPY)   copyAndMigrate 2>&1 | tee $LOG_FILE ;;
 DELETE) deletePdb      2>&1 | tee $LOG_FILE ;;
 TEST)   testUnit       2>&1 | tee $LOG_FILE ;;
esac

