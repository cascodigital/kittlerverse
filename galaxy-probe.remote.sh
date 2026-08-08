#!/bin/sh
# galaxy-probe — read-only docker snapshot for the Kittlerverse poller on 192.168.2.46.
# Invoked as a forced command from authorized_keys: no shell, no arguments honoured.
printf '###PS\n'
docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}'
printf '###STATS\n'
docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
printf '###INSPECT\n'
IDS=$(docker ps -aq)
[ -n "$IDS" ] && docker inspect --format '{{.Name}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.ExitCode}}|{{.State.Error}}' $IDS 2>/dev/null | sed 's#^/##'
printf '###END\n'
