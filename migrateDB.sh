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




if [ "$OCI_SCRIPT_DIR" = "" ]
then
  echo "This script is intended to be called from duplicate_db_oci.sh"
  exit 1
fi

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
    
    recompEtVuesMat $pdb
    getInvalidObjects  "/ as sysdba" "$pdb"
    addServices $pdb

  done

  log_info "Apply known FIX_CONTROLS and activate 19c disabled fixes + non dynamic parameters"

  exec_sql "/ as sysdba" "
Prompt FIX_CONTROLS for CNAF : 7268249:0,5909305:OFF
alter system reset \"_fix_control\" scope=both ;
ALTER SYSTEM set \"_fix_control\"='27268249:0','5909305:OFF' scope=both ;

Prompt Activate all 19c FIXES
Set serveroutput on

execute dbms_optim_bundle.enable_optim_fixes('ON','BOTH', 'YES') ; 

Prompt SGA_MAX_SIZE=200G
alter system set sga_max_size=200G scope=spfile ;
Prompt COMPATIBLE=19.0.0
alter system set sga_max_size=200G scope=spfile ;
Prompt ADAPTIVE_PLANS=FALSE
alter system set optimizer_adaptive_plans=false scope=spfile ;


" || die "There was a problem activating FIX_CONTROLS or parameters"


log_success "Done"

log_info "Last database restart"
srvctl stop database -d $ORACLE_UNQNAME || die "Unable to stop the $ORACLE_UNQNAME database"
srvctl start database -d $ORACLE_UNQNAME || die "Unable to start the $ORACLE_UNQNAME database"
log_success "Database restarted"

log_info "Database and services Status"
srvctl status database -d $ORACLE_UNQNAME
echo
srvctl config database -d $ORACLE_UNQNAME
echo
srvctl status service  -d $ORACLE_UNQNAME

echo "
               +=========================================================================+
               |     Database sucessfully upgraded , SGA has been reduced, please        |
               |update parameters and don't forget applicative parameters                |
               +=========================================================================+


"
  endStep


  
  # 
  # -----------------------------------------------------------------------------------------
  # 
