egrep "Finished|channel|Starting recover at|Starting restore at|destination for restore of datafile" $1 | grep -v allocate | awk '
BEGIN {
  t="---------------------------------------------------------------------------------------------------------------------------------------------------------------"
}
function h(l) {
  printf("\n")
  printf("        +------------------------------------------------------------------------+\n")
  printf("        | %-70.70s |\n",l)
  printf("        +------------------------------------------------------------------------+\n")
  printf("\n")
  printf("+-%-10.10s-+-%-9.9s-+-%-9.9s-+-%-150.150s-+-%-7.7s-+-%-12.12s-+\n",t,t        ,t         ,t     ,t       ,t      )
  printf("| %-10.10s | %-9.9s | %-9.9s | %-150.150s | %-7.7s | %-12.12s |\n","Type","Channel","File Num","Name","Section","Time")
  printf("+-%-10.10s-+-%-9.9s-+-%-9.9s-+-%-150.150s-+-%-7.7s-+-%-12.12s-+\n",t,t        ,t         ,t     ,t       ,t      )
}
/Starting recover at/ {
  ope="RECOVER"
  ope_lib="Recover"
  h(sprintf("RMAN Recovery LOG (%s %s",$4,$5))
}
/Starting restore at/ {
  ope="RESTORE"
  ope_lib="Restore"
  h(sprintf("RMAN Restoration LOG %s %s",$4,$5))
}
/using network backup set from/ {
  c=$2
  gsub(":","",c)
  getline tmp
  gsub(":","",tmp)
  gsub("\r","",tmp)
  split(tmp,a," ")
  tab[c]=sprintf("| %-10.10s | %-9.9s | %-9.9s | %-150.150s",ope_lib,c,a[6],a[7])
}
/restoring datafile/ {
  c=$2
  gsub(":","",c)
  tab[c]=sprintf("| %-10.10s | %-9.9s",ope_lib,c)
  tab[c]=sprintf("%s | %-9.9s",tab[c],$5)
  tab[c]=sprintf("%s | %-150.150s",tab[c],$7)
}
/restoring section/ {
  c=$2
  gsub(":","",c)
  tab[c]=sprintf("%s | %-3.3s/%-3.3s",tab[c],$5,$7)
}
/restore complete/ {
  c=$2
  gsub(":","",c)
  tab[c]=sprintf("%s | %-12.12s |",tab[c],$7)
  printf("%s\n",tab[c])
  tab[c]=""
}
/Finished restore|Finished recover/ {
  secondFooter=0
  printf("+-%10.10s-+-%-9.9s-+-%-9.9s-+-%-150.150s-+-%-7.7s-+-%-12.12s-+\n",t,t        ,t         ,t     ,t       ,t      )
  for ( i=1 ; i <= 32 ; i ++ )
  {
    c=sprintf("C%d",i)
    if ( tab[c] != "" )
    {
      printf("%s | In progress  |\n",tab[c])
      secondFooter=1
    }
  }
  if ( secondFooter == 1 )
  {
    printf("+-%10.10s-+-%-9.9s-+-%-9.9s-+-%-150.150s-+-%-7.7s-+-%-12.12s-+\n",t,t        ,t         ,t     ,t       ,t      )
  }
}'
