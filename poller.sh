#!/bin/sh
# galaxy-poller: snapshots docker state to telemetry.json once a minute
OUT=/out/telemetry.json
while true; do
  docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' > /tmp/ps.txt
  docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' > /tmp/st.txt
  BODY=$(awk -F'\t' '
    NR==FNR{cpu[$1]=$2;mem[$1]=$3;next}
    {
      c=cpu[$1]; gsub(/%/,"",c); if(c=="")c=0;
      split(mem[$1],a," "); v=a[1]+0;
      if(a[1] ~ /GiB/) v*=1024; else if(a[1] ~ /KiB/) v/=1024; else if(a[1] !~ /MiB/) v/=1048576;
      st=$3; gsub(/"/,"",st);
      printf "%s{\"name\":\"%s\",\"state\":\"%s\",\"status\":\"%s\",\"cpu\":%.2f,\"mem\":%.1f}", (n++?",":""), $1, $2, st, c, v
    }
  ' /tmp/st.txt /tmp/ps.txt)
  printf '{"ts":"%s","containers":[%s]}' "$(date -Iseconds)" "$BODY" > $OUT.tmp && mv $OUT.tmp $OUT
  sleep 60
done
