#!/bin/sh
# galaxy-probe — read-only docker snapshot for the Kittlerverse poller on 192.168.2.46.
# Invoked as a forced command from authorized_keys: no shell, no arguments honoured.
printf "###PS\n"
docker ps -a --format "{{.Names}}\t{{.State}}\t{{.Status}}"
printf "###STATS\n"
docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
printf "###INSPECT\n"
IDS=$(docker ps -aq)
[ -n "$IDS" ] && docker inspect --format "{{.Name}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.ExitCode}}|{{.State.Error}}" $IDS 2>/dev/null | sed "s#^/##"
# ---- host vitals (2026-09-17). Raw values only; the poller does the math. ----
printf "###VITALS\n"
read -r _up _rest < /proc/uptime; printf "uptime=%s\n" "${_up%.*}"
printf "load=%s\n" "$(cut -d\  -f1-3 /proc/loadavg)"
printf "cores=%s\n" "$(nproc)"
awk "/^MemTotal:/{t=\$2}/^MemAvailable:/{a=\$2}END{printf \"memtotal=%d\nmemavail=%d\n\",t,a}" /proc/meminfo
printf "cpustat=%s\n" "$(head -1 /proc/stat)"
_t=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1); printf "temp=%s\n" "${_t:-0}"
df -k /dados 2>/dev/null | tail -1 | awk "{printf \"disk_total=%.0f\ndisk_used=%.0f\ndisk_pct=%d\n\",\$2,\$3,\$5+0}"
printf "###END\n"
