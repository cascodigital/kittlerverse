#!/bin/sh
# galaxy-poller: snapshots docker state to telemetry.json once a minute.
# Keep this boring and cheap: docker ps/stats/inspect plus one internal Cockpit probe.
OUT=${OUT:-/out/telemetry.json}

while true; do
  docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' > /tmp/ps.txt
  docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' > /tmp/st.txt
  docker inspect --format '{{.Name}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.ExitCode}}|{{.State.Error}}' $(docker ps -aq) 2>/dev/null \
    | sed 's#^/##' > /tmp/inspect.txt

  BODY=$(awk -F'\t' '
    function esc(s){gsub(/\\/,"\\\\",s);gsub(/"/,"\\\"",s);gsub(/\r/," ",s);gsub(/\n/," ",s);return s}
    FNR==1{file++}
    file==1{cpu[$1]=$2;mem[$1]=$3;next}
    file==2{split($0,i,"|");restart[i[1]]=i[2]+0;oom[i[1]]=i[3];health[i[1]]=i[4];exitcode[i[1]]=i[5]+0;err[i[1]]=i[6];next}
    file==3{
      c=cpu[$1]; gsub(/%/,"",c); if(c=="")c=0;
      split(mem[$1],a," "); v=a[1]+0;
      if(a[1] ~ /GiB/) v*=1024; else if(a[1] ~ /KiB/) v/=1024; else if(a[1] !~ /MiB/) v/=1048576;
      st=$3; gsub(/"/,"",st);
      sev="ok"; reason="";
      if($2 != "running"){sev="down"; reason=$2}
      if(tolower(st) ~ /restarting/){sev="warn"; reason="restarting"}
      if(health[$1] == "unhealthy"){sev="critical"; reason="unhealthy"}
      if(oom[$1] == "true"){sev="critical"; reason="oom_killed"}
      if(reason == "" && err[$1] != "") reason=err[$1];
      printf "%s{\"name\":\"%s\",\"state\":\"%s\",\"status\":\"%s\",\"cpu\":%.2f,\"mem\":%.1f,\"restart\":%d,\"oom\":%s,\"health\":\"%s\",\"exit\":%d,\"alert\":\"%s\",\"reason\":\"%s\"}", \
        (n++?",":""), esc($1), esc($2), esc(st), c, v, restart[$1], (oom[$1]=="true"?"true":"false"), esc(health[$1]), exitcode[$1], sev, esc(reason)
    }
  ' /tmp/st.txt /tmp/inspect.txt /tmp/ps.txt)

  COCKPIT_SERVICE=""
  if docker ps --format '{{.Names}}' | grep -qx cockpit; then
    COCKPIT_STATUS=$(docker exec cockpit python -c 'import json,sys,urllib.request
try:
  data=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/search/status", timeout=4))
  ok=bool(data.get("bm25_ready")) and bool(data.get("embed_ready"))
  print(("ok" if ok else "critical")+":bm25=%s embed=%s" % (data.get("bm25_ready"), data.get("embed_ready")))
except Exception as e:
  print("critical:"+str(e)[:120])
' 2>/dev/null || printf 'critical:probe_failed')
  else
    COCKPIT_STATUS="critical:container_not_running"
  fi
  COCKPIT_ALERT=${COCKPIT_STATUS%%:*}
  COCKPIT_DETAIL=${COCKPIT_STATUS#*:}
  COCKPIT_DETAIL=$(printf '%s' "$COCKPIT_DETAIL" | sed 's/\\/\\\\/g;s/"/\\"/g')
  COCKPIT_SERVICE=",\"services\":[{\"name\":\"cockpit-search\",\"target\":\"cockpit\",\"alert\":\"$COCKPIT_ALERT\",\"detail\":\"$COCKPIT_DETAIL\"}]"

  printf '{"ts":"%s","containers":[%s]%s}' "$(date -Iseconds)" "$BODY" "$COCKPIT_SERVICE" > $OUT.tmp && mv $OUT.tmp $OUT
  sleep 60
done
