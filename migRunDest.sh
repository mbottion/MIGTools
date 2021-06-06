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

  exec_sql           "/ as sysdba "        "select 1 from dual ;"                                "  - Connexion SYSDBA a la cible"     

  exec_sql           "$SRC_CONNECT_STRING" "select 1 from dual ;"                                "  - Connexion $MIG_USER a la source" 

  getInvalidObjects  "$SRC_CONNECT_STRING" "$srcPdbName" "Source"
  getInvalidObjects  "/ as sysdba"         "$dstPdbName" "Cible"

  endStep
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
compute sum of size_GB on tablespace_name 
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

  exec_sql           "/ as sysdba "        "select 1 from dual ;"                                "  - Connexion SYSDBA a la cible"     \
          || die "Unable to connect to the database"

  exec_sql           "$SRC_CONNECT_STRING" "select 1 from dual ;"                                "  - Connexion $MIG_USER a la source" \
          || die "Unable to connect to the database"

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
    echo " Script relance ....."
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
  getInvalidObjects  "/ as sysdba" "$dstPdbName" "Cible"

  endStep 
  
  # 
  # -----------------------------------------------------------------------------------------
  # 
  
  endRun

}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
die() 
{
  echo "
ERROR :
  $*"
  exit 1
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
usage() 
{
 echo "

Usage :
 $SCRIPT [-d srcDbName] [-p srcPdbName] [-D dstDbName] [-P dstPdbName] 
         [-k keyStorePass] [-s scan] [-L degreParal]  
         [-C|-R] [-h|-?]

         srcDbName    : Base source (db Unique Name)
         srcPdbName   : PDB Source
         dstDbName    : Base Cible (DB NAME)     : Defaut (deduit de la source)
         dstPdbName   : PDB Cible                : Defaut la meme que la source
         keyStorePass : MOt de passe TDE
         scan         : Adresse Scan (host:port) : Defaut HPR
         degreParal   : Parallelisme             : Defaut 20
         -C           : Copie et migration d'une base (le script se relance
                        en nohup apres que les premieres verifications sont faites
                        sauf si -i est precise)
         -R           : Supprime la PDB cible
         -i           : Ne relance pas le script en Nohup 
                        (pour enchainer par exemple)
         -?|-h        : Aide
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
  dstDbName=$(echo $srcDbName | cut -f1 -d"_")
fi
if [ "$dstPdbName" = "" ]
then
  dstPdbName=${srcPdbName}
fi
#
#   Mot de passe TDE
#
keyStorePassword=${keyStorePassword:-Wel_Come_12}
#
#   Mode de fonctionnement
#
mode=${mode:-COPY}
aRelancerEnBatch=${aRelancerEnBatch:-Y}
#
#   Adresse SCAN (Par défaut, HPR) DOMAINE=même domaine que
# le scan.
#
if [ "$scanAddress" = "" ]
then
  scanAddress="hprexacs-7sl1q-scan.dbad2.hpr.oraclevcn.com:1521"
fi
parallelDegree=${parallelDegree:-100} # On ne met rien, le degre de parallelisme est choisi automatiquement
DOMAIN=$(echo $scanAddress | sed -e "s;^[^\.]*\.\([^\:]*\).*$;\1;")
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
MIG_PASS="Wel_Come_12"                       # MOt de passe
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
#      Lancement de l'exécution
# -----------------------------------------------------------------------------

case $mode in
 COPY)   copyAndMigrate 2>&1 | tee $LOG_FILE ;;
 DELETE) deletePdb      2>&1 | tee $LOG_FILE ;;
 TEST)   testUnit       2>&1 | tee $LOG_FILE ;;
esac

