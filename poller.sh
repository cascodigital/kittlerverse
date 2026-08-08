#!/bin/sh
# galaxy-poller: snapshots docker state to telemetry.json once a minute.
# Keep this boring and cheap: docker ps/stats/inspect plus one internal Cockpit probe.
#
# MULTI-HOST (2026-08-08): collects the local socket (host id "46") and every remote
# declared in REMOTES. Remotes are reached over ssh with a key restricted by a forced
# command to a read-only probe script (~/bin/galaxy-probe on the remote) — the poller
# can never do more than read `docker ps/stats/inspect` there.
OUT=${OUT:-/out/telemetry.json}
SSH_KEY=${SSH_KEY:-/keys/galaxy_dotpi}
# id|ssh target  (one per line)
REMOTES=${REMOTES:-"dotpi|aristofeles@192.168.2.102"}

esc_sh() { printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }

# emit_json <host-id> <stats-file> <inspect-file> <ps-file>
# prints the container objects (comma-separated, no wrapping brackets)
emit_json() {
  awk -F'\t' -v host="$1" '
    function esc(s){gsub(/\\/,"\\\\",s);gsub(/"/,"\\\"",s);gsub(/\r/," ",s);gsub(/\n/," ",s);return s}
    FNR==1{file++}
    file==1{cpu[$1]=$2;mem[$1]=$3;next}
    file==2{split($0,i,"|");restart[i[1]]=i[2]+0;oom[i[1]]=i[3];health[i[1]]=i[4];exitcode[i[1]]=i[5]+0;err[i[1]]=i[6];next}
    file==3{
      if($1=="")next;
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
      printf "%s{\"name\":\"%s\",\"host\":\"%s\",\"state\":\"%s\",\"status\":\"%s\",\"cpu\":%.2f,\"mem\":%.1f,\"restart\":%d,\"oom\":%s,\"health\":\"%s\",\"exit\":%d,\"alert\":\"%s\",\"reason\":\"%s\"}", \
        (n++?",":""), esc($1), esc(host), esc($2), esc(st), c, v, restart[$1], (oom[$1]=="true"?"true":"false"), esc(health[$1]), exitcode[$1], sev, esc(reason)
    }
  ' "$2" "$3" "$4"
}

while true; do
  BODY=""
  HOSTS_JSON=""

  # ---------- local host (the Orange Pi) ----------
  docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' > /tmp/46.ps
  docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' > /tmp/46.st
  docker inspect --format '{{.Name}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.ExitCode}}|{{.State.Error}}' $(docker ps -aq) 2>/dev/null \
    | sed 's#^/##' > /tmp/46.in
  LOCAL=$(emit_json 46 /tmp/46.st /tmp/46.in /tmp/46.ps)
  LOCAL_N=$(grep -c . /tmp/46.ps 2>/dev/null || echo 0)
  BODY="$LOCAL"
  HOSTS_JSON="{\"id\":\"46\",\"reachable\":true,\"containers\":$LOCAL_N,\"error\":\"\"}"

  # ---------- remotes ----------
  for R in $REMOTES; do
    RID=${R%%|*}; RTGT=${R#*|}
    RAW=/tmp/$RID.raw
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
           -o UserKnownHostsFile=/tmp/known_hosts -o ConnectTimeout=8 \
           "$RTGT" true > $RAW 2>/tmp/$RID.err; then
      OK=1
    else
      OK=0
    fi
    if [ "$OK" = "1" ]; then
      awk -v id="$RID" '
        /^###PS$/     {sec="ps";  next}
        /^###STATS$/  {sec="st";  next}
        /^###INSPECT$/{sec="in";  next}
        /^###END$/    {sec="";    next}
        sec!=""{print > ("/tmp/" id "." sec)}
      ' $RAW
      for f in ps st in; do [ -f /tmp/$RID.$f ] || : > /tmp/$RID.$f; done
      REM=$(emit_json "$RID" /tmp/$RID.st /tmp/$RID.in /tmp/$RID.ps)
      REM_N=$(grep -c . /tmp/$RID.ps 2>/dev/null || echo 0)
      [ -n "$REM" ] && BODY="$BODY,$REM"
      HOSTS_JSON="$HOSTS_JSON,{\"id\":\"$RID\",\"reachable\":true,\"containers\":$REM_N,\"error\":\"\"}"
      rm -f /tmp/$RID.ps /tmp/$RID.st /tmp/$RID.in
    else
      ERR=$(esc_sh "$(tail -c 160 /tmp/$RID.err 2>/dev/null | tr '\n' ' ')")
      HOSTS_JSON="$HOSTS_JSON,{\"id\":\"$RID\",\"reachable\":false,\"containers\":0,\"error\":\"$ERR\"}"
    fi
    rm -f $RAW
  done

  # ---------- critical probe: cockpit search ----------
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
  COCKPIT_DETAIL=$(esc_sh "${COCKPIT_STATUS#*:}")
  SERVICES=",\"services\":[{\"name\":\"cockpit-search\",\"target\":\"cockpit\",\"alert\":\"$COCKPIT_ALERT\",\"detail\":\"$COCKPIT_DETAIL\"}]"

  printf '{"ts":"%s","hosts":[%s],"containers":[%s]%s}' \
    "$(date -Iseconds)" "$HOSTS_JSON" "$BODY" "$SERVICES" > $OUT.tmp && mv $OUT.tmp $OUT
  sleep 60
done
