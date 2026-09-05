#!/bin/bash
# VM state watchdog per debugloop.md. Runs on the build box against a phone over adb.
#   vmwatch.sh precheck <serial>                 -- VM must be OFF: avail==pool_want && served==0; reclaims / reports stale VMs
#   vmwatch.sh postlaunch <serial> <mem_mb> [secs] -- after a launch: served >= mem_mb/2 pages within secs (default 60) else FAIL
#   vmwatch.sh monitor <serial> <logfile> [interval] -- background loop: host uptime (reboot => HOST_REBOOT), refill_stat, crosvm pids
P=/sys/module/gh_hugepage_reserve/parameters
sh() { adb -s "$2" shell "su -c \"$1\"" 2>/dev/null | tr -d '\r'; }
stat() { sh "grep -E '^(state|pool_avail|pool_want|served|active_vms)=' $P/refill_stat | tr '\n' ' '; echo; cut -d' ' -f1 /proc/uptime; ps -A -o PID,ARGS | grep '[c]rosvm' | cut -c1-60" "$1"; }
case "$1" in
precheck)
  S=$2; out=$(stat $S); echo "$out"
  avail=$(echo "$out" | grep -o 'pool_avail=[0-9]*' | cut -d= -f2); want=$(echo "$out" | grep -o 'pool_want=[0-9]*' | cut -d= -f2); served=$(echo "$out" | grep -o 'served=[0-9]*' | head -1 | cut -d= -f2)
  if [ "${served:-0}" != "0" ] || echo "$out" | grep -q crosvm; then echo "PRECHECK_FAIL: a VM is still up (served=$served); inspect, then vm_stop / kill -TERM (never -9)"; exit 2; fi
  if [ "${avail:-0}" -lt "${want:-3072}" ]; then echo "reclaim: avail=$avail < want=$want, pressing acquire=3"; sh "echo 3 > $P/acquire" $S; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do sleep 5; a=$(sh "cut -d= -f2 $P/pool_avail" $S); [ "$a" -ge "$want" ] && break; done; echo "after reclaim: avail=$a"; [ "$a" -ge "$want" ] || { echo "PRECHECK_FAIL: pool did not refill"; exit 3; }; fi
  echo "PRECHECK_OK";;
postlaunch)
  S=$2; need=$(( ${3:-4096} / 2 )); secs=${4:-60}; for i in $(seq 1 $((secs/5))); do sleep 5; out=$(stat $S); served=$(echo "$out" | grep -o 'served=[0-9]*' | head -1 | cut -d= -f2); if [ "${served:-0}" -ge "$need" ]; then echo "POSTLAUNCH_OK served=$served >= $need after $((i*5))s"; exit 0; fi; done
  echo "POSTLAUNCH_FAIL: served=${served:-0} < $need after ${secs}s -- the VM died or never booted; read the launcher stderr / app error NOW"; echo "$out"; exit 4;;
monitor)
  S=$2; LOG=$3; iv=${4:-5}; last=; echo "monitor start $(date -u +%T)" >> $LOG
  while true; do up=$(sh "cut -d' ' -f1 /proc/uptime" $S); st=$(sh "grep -E '^(state|pool_avail|served|active_vms)=' $P/refill_stat | tr '\n' ' '" $S); pids=$(sh "ps -A -o PID | grep -c ." $S)
    if [ -n "$last" ] && [ -n "$up" ] && [ "${up%.*}" -lt "${last%.*}" ]; then echo "$(date -u +%T) HOST_REBOOT detected: uptime $last -> $up; bootreason=$(sh 'getprop ro.boot.bootreason' $S)" >> $LOG; fi
    [ -n "$up" ] && last=$up; echo "$(date -u +%T) up=$up $st" >> $LOG; sleep $iv; done;;
*) echo "usage: $0 precheck|postlaunch|monitor ..."; exit 1;;
esac
