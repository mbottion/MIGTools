#!/bin/bash

UTILS_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
OCI_BKP_ROOT_DIR=$(dirname $UTILS_SCRIPT_DIR)

#Backup default values
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
export OCI_RMAN_DEFAULT_PARALLELISM=16
export USE_CATALOG=YES
OCI_RMAN_SECTION_SIZE="16G"
OCI_RMAN_DEFAULT_RETENTION=62
OCI_RMAN_BACKUP_ALGORITHM=LOW
OCI_ARCH_RETENTION=8

OCI_BKP_LIB=$OCI_BKP_ROOT_DIR/lib/libopc.so
OCI_BKP_CONFIG_DIR=$OCI_BKP_ROOT_DIR/config
OCI_BKP_CREDWALLET_DIR=$OCI_BKP_ROOT_DIR/cred_wallet
OCI_BKP_TNS_DIR=$OCI_BKP_ROOT_DIR/tns
OCI_BKP_LOG_DIR=$OCI_BKP_ROOT_DIR/logs


#Functions
create_check_config(){

log_info "Checking if database config file exists"
if [ ! -f $OCI_BKP_CONFIG_DIR/opc${1}.ora ]; then
  die "Configuration file for database $1 does not exist,
please copy the configuration file AND the OPC Wallet
from the source server to the target server
    HINT : The name of the parameter file can be found on the machine hosting
           the source database ($OCI_SOURCE_DB_NAME) by running:
===================================================================================

. \$HOME/${OCI_SOURCE_DB_NAME}.env
f=\$(rman target / <<%% | grep \"OPC_PFILE=\" | sed -e \"s;^.*OPC_PFILE=;;\" -e \"s;).*$;;\"
show all ;
%%
) ;\\
echo -n \"Source config file : \$f\" ; test -f \$f && echo \" OK\" || echo \" NOT exists\" ;\\
wd=\$(grep OPC_WALLET \$f | sed -e \"s;^.*LOCATION=file:;;\" | cut -f1 -d\" \") ; \\
echo -n \"WALLET Dir         : \$wd\" ; test -d \$wd && echo \" OK\" || echo \" NOT exists\" ;\\
echo ; \\
echo \"Tar command (exemple) : 
 cd \$wd && tar cvzf /tmp/opc_$OCI_SOURCE_DB_NAME.tgz * -C \$(dirname \$f) \$(basename \$f) ; cd - \";\\
echo ; \\
echo \"copy the tar file on the source and place files in the required folders\" 

===================================================================================

   Once the file name found, open it to get the OPC wallet location
          1) copy the parameter file in $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora
          2) Modify the copied file to point to the local OPC Wallet (if not done, the modifcation
             will be made autoatically next time
             LOCAL_OPC_WALLET : $OCI_BKP_ROOT_DIR/opc_wallet/$OCI_SOURCE_DB_NAME
          3) copy the whole content of the wallet dir to $OCI_BKP_ROOT_DIR/opc_wallet/${OCI_SOURCE_DB_NAME}
             ie : 
          
   mkdir -p $OCI_BKP_ROOT_DIR/opc_wallet/${OCI_SOURCE_DB_NAME}
   cd $OCI_BKP_ROOT_DIR/opc_wallet/${OCI_SOURCE_DB_NAME}
   tar xvzf /tmp/opc_$OCI_SOURCE_DB_NAME.tgz
   mv opc${OCI_SOURCE_DB_NAME}.ora $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora
   cd -

"



#log_info "Configuration file for database $1 does not exist, creating it"
#cat << EOF > $OCI_BKP_CONFIG_DIR/opc${1}.ora
#OPC_HOST=$OCI_BKP_OS_URL
#OPC_WALLET='LOCATION=file:$OCI_BKP_CREDWALLET_DIR CREDENTIAL_ALIAS=alias_oci'
#OPC_CONTAINER=${OCI_BKP_BUCKET_PREFIX}${1,,}
#OPC_COMPARTMENT_ID=$OCI_BKP_COMPARTMENT_OCID
#OPC_AUTH_SCHEME=BMC
#EOF
fi
log_success "Database config file exists"

log_info "Check value of OPC_WALLET location (should be LOCAL)"

dir=$(grep "OPC_WALLET=" $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora \
       | sed -e "s;^.*LOCATION=;;" -e "s;file:;;" -e "s; .*$;;")

echo "   - OPC_PFILE = $dir"
if [ "$dir" != "$OCI_BKP_ROOT_DIR/opc_wallet/$OCI_SOURCE_DB_NAME" ]
then
  echo "   - Incorrect value, modifying"
  sed -i "s;$dir;$OCI_BKP_ROOT_DIR/opc_wallet/$OCI_SOURCE_DB_NAME;" $OCI_BKP_CONFIG_DIR/opc${OCI_SOURCE_DB_NAME}.ora
  echo "   - To   : $OCI_BKP_ROOT_DIR/opc_wallet/$OCI_SOURCE_DB_NAME"
fi


log_info "Checking if credential wallet exists"
if [ -f $OCI_BKP_ROOT_DIR/opc_wallet/$OCI_SOURCE_DB_NAME/cwallet.sso ]; then
	log_success "Credential wallet exists"
else
	die "Credential wallet does not exist in $OCI_BKP_ROOT_DIR"
	return 1
fi
}

load_db_env(){
log_info "Checking database presence in /etc/oratab"
export OCI_BKP_DB_UNIQUE_NAME=$(grep "^${1}_" /etc/oratab | cut -d':' -f1)
export OCI_BKP_ORACLE_HOME=$(grep "^${1}_" /etc/oratab | cut -d':' -f2)

if [[ -z $OCI_BKP_DB_UNIQUE_NAME || -z $OCI_BKP_ORACLE_HOME ]]; then
	log_error "Error getting database information in /etc/oratab"
	return 1
else
	export ORACLE_HOME=$OCI_BKP_ORACLE_HOME
	export PATH=$ORACLE_HOME/bin:$PATH
	SHORT_HOSTNAME=$(hostname -s)
	export ORACLE_SID=${1}${SHORT_HOSTNAME: -1}
	log_info "Environment is : "
	echo "ORACLE_HOME     : $ORACLE_HOME"
	echo "ORACLE_SID      : $ORACLE_SID"
fi

log_success "Database $1 is present in /etc/oratab"

}

get_scan_addr(){
log_info "Checking local SCAN address"
#export ORACLE_HOME=$OCI_BKP_ORACLE_HOME
export OCI_SCAN_ADDR=$($ORACLE_HOME/bin/srvctl config scan | grep -v "SCAN VIP" | grep -oP "(?<=name: ).*(?=,)")

if [ $? -ne 0 ]; then
	log_error "Error getting local SCAN address"
	return 1
fi

log_success "Local SCAN address is : $OCI_SCAN_ADDR"

}

create_check_tns(){
log_info "Checking or creating tnsnames.ora for $1"
if [ ! -d $OCI_BKP_TNS_DIR/$1 ]; then
	mkdir $OCI_BKP_TNS_DIR/$1
fi

domain=$(srvctl config database -d ${OCI_BKP_DB_UNIQUE_NAME} | grep -i domain | cut -f2 -d: | sed -e "s; ;;g") || \
         { ERR1="Unable to get the database domain, please update $OCI_BKP_TNS_DIR/$1/tnsnames.ora" ; domain="DB_DOMAIN_UNKNOWN" ; }

[ "$domain" != "" ] && domain=".$domain"
if [ ! -f $OCI_BKP_TNS_DIR/$1/tnsnames.ora ]; then
cat > $OCI_BKP_TNS_DIR/$1/tnsnames.ora << EOF
$1 =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $OCI_SCAN_ADDR)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${OCI_BKP_DB_UNIQUE_NAME}${domain})
    )
  )

EOF
fi
log_info "Checking or creating sqlnet.ora"

echo "DB_UNIQUE_NAME=$ORACLE_UNQNAME"
echo "TNS_ADMIN=$TNS_ADMIN"
. $HOME/$OCI_TARGET_DB_NAME.env
tdeDir=$(cat $TNS_ADMIN/sqlnet.ora | sed -e "/ENCRYPTION_WALLET_LOCATION/ p"       \
                                         -e "1, /ENCRYPTION_WALLET_LOCATION/ d"    \
                                         -e "/^ *$/,$ d"                           \
                                   | tr '\n' ' '                                   \
                                   |  sed -e "s;^.*DIRECTORY=;;" -e "s;).*$;;")

[ ! -d "$tdeDir" ] && { log_error "TDE wallet dir determined as : ($tdeDir), does not exists" ; tdeDir="" ; }
[ "$tdeDir" = "" ] && { ERR2="Unable to get TDE dir, please update $OCI_BKP_TNS_DIR/$1/sqlnet.ora" ; tdeDir="/UNKNOWN_DIR" ; }
if [ ! -f $OCI_BKP_TNS_DIR/$1/sqlnet.ora ]; then
cat > $OCI_BKP_TNS_DIR/$1/sqlnet.ora << EOF
WALLET_LOCATION =(SOURCE=(METHOD = FILE)(METHOD_DATA=(DIRECTORY = $OCI_BKP_CREDWALLET_DIR)))
SQLNET.WALLET_OVERRIDE = TRUE

ENCRYPTION_WALLET_LOCATION =
 (SOURCE=
  (METHOD=FILE)
   (METHOD_DATA=
    (DIRECTORY=$tdeDir)))

EOF
fi
export TNS_ADMIN=$OCI_BKP_TNS_DIR/$1

ERR=N
[ "$ERR1" != "" ] && { echo "    - $ERR1" ; ERR=Y ; }
[ "$ERR2" != "" ] && { echo "    - $ERR2" ; ERR=Y ; }

[ "$ERR" = "Y" ] && die "Network files need to be updated"

return 0
}

check_db_connection()
{
rman target /@$1 >/dev/null 2>&1<< EOF
EOF
if [ $? -ne 0 ]; then
	log_error "Not able to connect to the database using local TNS configuration."
	return 1
else
	log_success "TNS configuration and connection to the database is OK"
fi
}

check_sys_db_password()
{
STATUS=$(echo -e "set newpage none\nset head off\nset feedback off\nselect 'OK' from dual ;" | sqlplus -s sys/$2@$1 as sysdba | grep -v "^$")
if [ "$STATUS" != "OK"  ]; then
        log_error "Can't connect to the database as SYS with provided password. "
        return 1
else
        log_success "Successfully connect SYS with provided paswword. Continuing"
fi
}

check_rman_connection()
{
rman target /@$1 catalog /@RC$1 >/dev/null 2>&1<< EOF
EOF
if [ $? -ne 0 ]; then
	log_error "Not able to connect to the RMAN catalog using local TNS configuration"
	log_info  "Warning: Using control file for backup instead of RMAN catalog"
	USE_CATALOG=NO
else
	log_success "TNS configuration and connection to the RMAN catalog are OK"
	USE_CATALOG=YES
fi
}

check_rman_password()
{
RCUSER=RC`echo $1 | tr '[:lower:]' '[:upper:]'`
rcuser=rc`echo $1 | tr '[:upper:]' '[:lower:]'`
rman catalog $RCUSER/"${2}"@RC$1 >/dev/null 2>&1<< EOF
EOF
if [ $? -ne 0 ]; then
        log_error "Can't connect to the RMAN catalog using provided password. Exiting"
else
        log_success "Connection to the RMAN Catalog with provided passwd is OK"
fi
}

check_cred() {
$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep "^[0-9]" | grep -i $1 |grep -v RC$1 > /dev/null 2>&1
if [ $? -ne 0 ]; then
	log_error "No Entry for $1 in wallet $OCI_BKP_CREDWALLET_DIR. Please add the entry using mkstore command"
	return 1
else
	log_success "Entry for $1 found in wallet $OCI_BKP_CREDWALLET_DIR"
fi
}

check_rman_cred() {
$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep "^[0-9]" | grep -i RC$1 > /dev/null 2>&1
if [ $? -ne 0 ]; then
	log_error "No Entry for RC$1 (RMAN catalog user) in wallet $OCI_BKP_CREDWALLET_DIR. Please add the entry using mkstore command"
	return 1
else
	log_success "Entry for RC$1 (RMAN catalog user) found in wallet $OCI_BKP_CREDWALLET_DIR"
fi
}

add_cred() {
EXIST=`$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep "^[0-9]" | grep $1 | grep -v RC$1 | wc -l `
if [ $EXIST -eq 0 ]; then
	$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -createCredential $OCI_DB_NAME sys "${2}" >/dev/null 2>&1
	if [ $? -ne 0 ]; then
		log_error "Failed to add DB Credentials into the store. Exiting"
		exit 1
	else
		log_success "DB Credentials added into the store. Continuing"
	fi
else
	log_info "DB Credentials already existing in the store. Continuing"
fi
}

add_rman_cred() {
RCUSER=RC`echo $1 | tr '[:lower:]' '[:upper:]'`
rcuser=rc`echo $1 | tr '[:upper:]' '[:lower:]'`
EXIST=`$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep "^[0-9]" | grep RC$1 | wc -l `
if [ $EXIST -eq 0 ]; then
	$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -createCredential $RCUSER $rcuser "${2}" >/dev/null 2>&1
	if [ $? -ne 0 ]; then
		log_error "Failed to add RMAN Credentials into the store. Exiting"
		exit 1
	else
		log_success "RMAN Credentials added into the store. Continuing"
	fi
else
	log_info "RMAN Credentials already existing in the store. Continuing"
fi
}

read_password() {
PASSWORD=''
PASSWORD2=''
while [ $PASSWORD != $PASSWORD2 ]
do
        PASSWORD=''
        PASSWORD2=''
        prompt="Password: "
        while IFS= read -p "$prompt" -r -s -n 1 char
        do
                if [[ $char == $'\0'  ]]
                then
                        break
                fi
                prompt='*'
                PASSWORD+="$char"
        done
	echo
        prompt="Password again: "
	while IFS= read -p "$prompt" -r -s -n 1 char
        do
		if [[ $char == $'\0'  ]]
		then
			break
                fi
		prompt='*'
		PASSWORD2+="$char"
	done
done
echo $PASSWORD
}

register_db()
{
rman target /@$1 catalog /@RC$1 >/dev/null 2>&1<< EOF
register database;
list incarnation;
EOF
if [ $? -ne 0 ]; then
	log_error "Failed to register DB into the RMAN Catalog"
	return 1
else
	log_success "Succesfully registered DB into the RMAN Catalog"
fi
}

create_catalog ()
{
echo export CIBLEDB=$OCI_DB_NAME                  > $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh
echo export CIBLE_RCUSER_PASSWORD=`echo $RMAN_PASSWORD` >> $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh
scp $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh oracle@$OCI_RMAN_SERVER:/home/oracle/scripts/rman-catalog >/dev/null 2>&1
if [ $? -ne 0 ];
then
	log_error "Failed to copy $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh to oracle@$OCI_RMAN_SERVER:/home/oracle/scripts/rman-catalog"
	rm -f $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh
	exit 1
else
	log_success "Parameter file params_$OCI_DB_NAME.sh copied successfully on serveur $OCI_RMAN_HOSTNAME_SERVER ($OCI_RMAN_SERVER)"
	rm -f $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh
fi
ssh oracle@$OCI_RMAN_SERVER  /home/oracle/scripts/rman-catalog/create_rman_catalog.sh params_${OCI_DB_NAME}.sh
if [ $? -ne 0 ];
then
	log_error "Failed to execute remotly on server $OCI_RMAN_SERVER script /home/oracle/scripts/rman-catalog/create_rman_catalog.sh with oracle user. Exiting"
	log_error "Check SSH equivalency between local user and oracle user on oracle@$OCI_RMAN_HOSTNAME_SERVER ($OCI_RMAN_SERVER)"
	exit 1
else
	log_success "Remote RMAN Catalog creation script execution success on oracle@$OCI_RMAN_HOSTNAME_SERVER ($OCI_RMAN_SERVER)"
fi
}

config_rman() {
rman target /@$1 $CATALOG 2>&1<< EOF
CONFIGURE CHANNEL DEVICE TYPE DISK CLEAR;
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF $OCI_KEEP_DAYS DAYS;
CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE DEFAULT DEVICE TYPE TO 'SBT_TAPE';
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE SBT_TAPE TO '%F'; # default
CONFIGURE DEVICE TYPE 'SBT_TAPE' PARALLELISM $OCI_RMAN_PARALLELISM BACKUP TYPE TO COMPRESSED BACKUPSET;
CONFIGURE CHANNEL DEVICE TYPE 'SBT_TAPE' PARMS  'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${1}.ora)';
CONFIGURE ENCRYPTION FOR DATABASE ON;
CONFIGURE ENCRYPTION ALGORITHM 'AES128'; # default
CONFIGURE COMPRESSION ALGORITHM '$OCI_RMAN_BACKUP_ALGORITHM' AS OF RELEASE 'DEFAULT' OPTIMIZE FOR LOAD TRUE;
CONFIGURE SNAPSHOT CONTROLFILE NAME TO '+RECOC1/$OCI_BKP_DB_UNIQUE_NAME/snapcf_${1}.f';
EOF

}

# Display helpers
GREEN=$(tput setaf 6)
BLUE=$(tput setaf 4)
RED=$(tput setaf 1)
NC=$(tput sgr0)

message()
{
echo
echo "-----------------------------------------------------------------"
echo $1
echo "-----------------------------------------------------------------"
}

message_end()
{
echo "-----------------------------------------------------------------"
echo
}

log_info()
{
FDATE=$(date "+%Y-%m-%d %H:%M:%S")
echo
echo -e "$BLUE[INFO]$NC[${FDATE}] $1"
echo
}

log_error()
{
FDATE=$(date "+%Y-%m-%d %H:%M:%S")
echo
echo -e "$RED[ERROR]$NC[${FDATE}] $1"
echo
}

log_success()
{
echo
FDATE=$(date "+%Y-%m-%d %H:%M:%S")
echo -e "$GREEN[SUCCESS]$NC[${FDATE}] $1"
echo
}

ask_confirm(){
echo "$1"
read -p "Are you sure you want to continue ? (y/N) "
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
	exit 1
fi
}

startRun()
{
  START_INTERM_EPOCH=$(date +%s)
  echo   "========================================================================================" 
  echo   " ${SCRIPT:-$(basename $0)} : Execution start"
  echo   "========================================================================================" 
  echo   "  - $1"
  echo   "  - Start date     : $(date)"
  echo   "========================================================================================" 
  echo
}
endRun()
{
  END_INTERM_EPOCH=$(date +%s)
  all_secs2=$(expr $END_INTERM_EPOCH - $START_INTERM_EPOCH)
  mins2=$(expr $all_secs2 / 60)
  secs2=$(expr $all_secs2 % 60 | awk '{printf("%02d",$0)}')
  echo
  echo   "========================================================================================" 
  echo   "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo   "  - End Date      : $(date)" 
  echo   "  - Duration      : ${mins2}:${secs2}"
  echo   "========================================================================================" 
  echo   "Script LOG in : $LOG_FILE"
  echo   "========================================================================================" 
}
startStep()
{
  STEP="$1"
  STEP_START_EPOCH=$(date +%s)
  echo
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo "       - Step start    : $STEP"
  echo "       - at            : $(date)" 
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo
}
endStep()
{
  STEP_END_EPOCH=$(date +%s)
  all_secs2=$(expr $STEP_END_EPOCH - $STEP_START_EPOCH)
  mins2=$(expr $all_secs2 / 60)
  secs2=$(expr $all_secs2 % 60 | awk '{printf("%02d",$0)}')
  echo
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo "       - Step End      : $STEP"
  echo "       - Ended at      : $(date)" 
  echo "       - Duration      : ${mins2}:${secs2}"
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
}
die() 
{
  log_error "$*"
  echo   "========================================================================================" 
  echo   "Script LOG in : $LOG_FILE"
  echo   "========================================================================================" 
  exit 1
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#      SQL Execution
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
  if [ $status -eq 0 -a "$(egrep "SP2-|ORA-01012" $REDIR_FILE)" != "" ]
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
