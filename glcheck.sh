#!/bin/sh
# glcheck.sh - read-only check for the GL.iNet 2026-11-20 incident indicators.
# Changes nothing. Run on the router:  sh glcheck.sh
BAD_IP="170.39.226.219"
hits=0
ok()   { printf '  [ OK ] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; hits=$((hits+1)); }
info() { printf '  [info] %s\n' "$1"; }

echo "GL.iNet incident check - $(cat /proc/gl-hw-info/model 2>/dev/null) fw $(cat /etc/glversion 2>/dev/null) - $(uptime | sed 's/.*up/up/;s/,  load.*//')"

echo; echo "1. Published indicator (crond -i /tmp/.log)"
if ps w 2>/dev/null | grep -v grep | grep -q 'tmp/\.log'; then bad "process mentioning tmp/.log is running"; else ok "no process mentioning tmp/.log"; fi
if [ -e /tmp/.log ]; then bad "/tmp/.log exists"; else ok "/tmp/.log not present"; fi

echo; echo "2. Unexpected crond / cron entries"
for p in $(pidof crond 2>/dev/null); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  case "$c" in
    *"-c /tmp/gl_crontabs"*|*"-c /etc/crontabs"*) ok "crond looks stock: $c" ;;
    *) bad "unusual crond: $c" ;;
  esac
done
n=$(cat /etc/crontabs/* 2>/dev/null | grep -vc '^[[:space:]]*\(#\|$\)')
if [ "$n" -gt 0 ]; then bad "/etc/crontabs has $n entries (see below)"; cat /etc/crontabs/* | sed 's/^/         /'; else ok "/etc/crontabs empty"; fi

echo; echo "3. Programs running from temp/RAM locations or deleted binaries"
found=0
for e in /proc/[0-9]*/exe; do
  t=$(readlink "$e" 2>/dev/null) || continue
  case "$t" in
    /tmp/*|/var/*|/dev/shm/*|*"(deleted)") found=1; bad "pid ${e#/proc/}: $t" ;;
  esac
done
[ "$found" = 0 ] && ok "none"

echo; echo "4. Reported attacker address $BAD_IP"
hex=$(printf '%02X%02X%02X%02X' 219 226 39 170)
if netstat -tn 2>/dev/null | grep -q "$BAD_IP" || grep -qi ":[0-9A-F]* $hex:" /proc/net/tcp 2>/dev/null; then
  bad "connection to $BAD_IP"
else ok "no connection"; fi
if logread 2>/dev/null | grep -q "$BAD_IP"; then bad "$BAD_IP appears in system log"; else ok "not in system log"; fi

echo; echo "5. For your eyes (not judged)"
info "established connections to non-local addresses:"
netstat -tn 2>/dev/null | awk '$6=="ESTABLISHED" && $5 !~ /^(127\.|192\.168\.|10\.)/ {print "         " $5}' | sort -u
info "rc.local commands:"
grep -v '^[[:space:]]*\(#\|$\)' /etc/rc.local 2>/dev/null | sed 's/^/         /'
info "GoodCloud enabled: $(uci -q get gl-cloud.@cloud[0].enable || echo n/a)   UPnP: $(pidof miniupnpd >/dev/null && echo running || echo off)"

echo
if [ "$hits" -eq 0 ]; then
  echo "RESULT: no indicators found (not proof of a clean device)."; exit 0
else
  echo "RESULT: $hits indicator(s) found - treat as suspect, see GL.iNet notice."; exit 1
fi
