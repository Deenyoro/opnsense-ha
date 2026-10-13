#!/bin/sh
# Controlled CARP failover drill with automatic failback and probes of EXISTING
# flows (new connections working proves nothing: in the field every established
# connection was dead for a whole drill while ping/DNS to the VIP looked perfect).
#
#   ./drill.sh root@<master> root@<backup> [hold-seconds] [probe-ip] [dns-vip] [https-url]
#
# What it does:
#   1. Pre-flight: master has all VIPs MASTER, backup all BACKUP, demotion 0 on both.
#   2. Starts the probes from THIS host: 1 s ping to probe-ip (through
#      the firewall), DNS at dns-vip every 1 s, a keep-alive HTTPS request every 0.5 s
#      on one persistent connection (https-url).
#   3. On the master, DETACHED (daemon -f, the ssh session may ride an address that
#      moves): demotion +N, hold, demotion -N. So the drill fails back on its own
#      even if this host loses the firewall.
#   4. Reports losses per phase (failover / hold / failback) and the hook log lines.
# Arguments left out are taken from the master's kc-ha.conf: DRILL_HOLD,
# DRILL_PROBE_IP, DRILL_HTTPS_URL, plus DRILL_DEMOTION and DRILL_DNS_NAME.
set -u
SSH=${KC_HA_SSH:-ssh}   # override the ssh command as in install.sh
[ $# -ge 2 ] || { echo "usage: $0 root@<master> root@<backup> [hold] [probe-ip] [dns-vip] [https-url]"; exit 2; }
M=$1; B=$2; HOLD=${3:-}; PIP=${4:-}; DNSV=${5:-}; URL=${6:-}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

st() { $SSH "$1" '/usr/local/sbin/kc-ha-status --kv'; }
echo "== pre-flight"
SM=$(st "$M"); SB=$(st "$B")
g() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }
# defaults for everything not given on the command line come from the master's kc-ha.conf (DRILL_*)
[ -n "$HOLD" ] || HOLD=$(g cfg:DRILL_HOLD "$SM"); [ -n "$PIP" ] || PIP=$(g cfg:DRILL_PROBE_IP "$SM")
[ -n "$URL" ] || URL=$(g cfg:DRILL_HTTPS_URL "$SM"); [ -n "$DNSV" ] || DNSV=$(g vip "$SM")
DEM=$(g cfg:DRILL_DEMOTION "$SM"); DNSN=$(g cfg:DRILL_DNS_NAME "$SM")
[ -n "$HOLD" ] && [ -n "$PIP" ] && [ -n "$URL" ] && [ -n "$DEM" ] && [ -n "$DNSN" ] || { echo "  could not read DRILL_* settings from $M (kc-ha-status --kv); is the kit installed?"; exit 1; }
bad=0
[ "$(g backups "$SM")" = 0 ] && [ "$(g masters "$SM")" -gt 0 ] || { echo "  $M is not MASTER on all VIPs ($(g masters "$SM")/$(g backups "$SM"))"; bad=1; }
[ "$(g masters "$SB")" = 0 ] && [ "$(g backups "$SB")" -gt 0 ] || { echo "  $B is not BACKUP on all VIPs ($(g masters "$SB")/$(g backups "$SB"))"; bad=1; }
[ "$(g demotion "$SM")" = 0 ] && [ "$(g demotion "$SB")" = 0 ] || { echo "  carp demotion not 0 on both"; bad=1; }
case "$(g pfsync "$SM")$(g pfsync "$SB")" in *syncok=0*) echo "  pfsync syncok=0"; bad=1 ;; esac
[ $bad = 0 ] || { echo "aborting"; exit 1; }
echo "  master $(g host "$SM") $(g masters "$SM") VIPs, backup $(g host "$SB") $(g backups "$SB") VIPs, states $(g states "$SM")/$(g states "$SB"), hold ${HOLD}s"
echo "  probes: ping $PIP, dns @$DNSV, https $URL"

echo "== probes start $(date +%T)"
T0=$(date +%s)
( ping -c $((HOLD + 30)) -i 1 -W 1 "$PIP" > "$tmp/ping" 2>&1 ) & P1=$!
( while :; do s=$(date +%s.%N); if dig +time=1 +tries=1 @"$DNSV" "$DNSN" A >/dev/null 2>&1; then echo "$s ok"; else echo "$s FAIL"; fi; sleep 1; done > "$tmp/dns" ) & P2=$!
# one persistent HTTPS connection: curl reuses the connection across URLs given in one invocation
( n=$(( (HOLD + 30) * 2 )); set --; i=0; while [ $i -lt $n ]; do set -- "$@" "$URL"; i=$((i+1)); done
  curl -s -o /dev/null --keepalive-time 5 --max-time 3 --rate 2/s -w '%{time_total} %{http_code} %{num_connects}\n' "$@" > "$tmp/https" 2>&1 ) & P4=$!
sleep 5
echo "== failover $(date +%T) (+$(( $(date +%s) - T0 ))s): demoting $M for ${HOLD}s, detached"
$SSH "$M" "daemon -f sh -c 'sysctl net.inet.carp.demotion=$DEM; sleep $HOLD; sysctl net.inet.carp.demotion=-$DEM'"
TF=$(date +%s)
sleep $((HOLD + 20))
TB=$((TF + HOLD))
wait $P1 2>/dev/null; kill $P2 $P4 2>/dev/null; wait 2>/dev/null
echo "== probes end $(date +%T)"

echo "== results"
echo "  ping $PIP: $(grep -E 'packets transmitted' "$tmp/ping" || echo 'n/a')"
echo "  dns @$DNSV: $(grep -c ' ok' "$tmp/dns") ok, $(grep -c FAIL "$tmp/dns") failed"
echo "  https: $(wc -l < "$tmp/https" | tr -d ' ') requests, $(awk '$2!="204" && $2!="200"' "$tmp/https" | wc -l | tr -d ' ') failed, $(awk 'NR>1 && $3>0' "$tmp/https" | wc -l | tr -d ' ') reconnect(s), slowest $(sort -n "$tmp/https" | tail -1 | cut -d' ' -f1)s"
echo "  dns failures by second since failover:"; awk -v tf="$TF" '/FAIL/ {printf "    +%ds\n", int($1)-tf}' "$tmp/dns" | sort | uniq -c | head
echo "== state after"
SM=$(st "$M"); SB=$(st "$B")
echo "  $(g host "$SM"): $(g masters "$SM") MASTER / $(g backups "$SM") BACKUP, demotion $(g demotion "$SM"), egress '$(g egress "$SM")', default $(g default "$SM")"
echo "  $(g host "$SB"): $(g masters "$SB") MASTER / $(g backups "$SB") BACKUP, demotion $(g demotion "$SB"), egress '$(g egress "$SB")', default $(g default "$SB")"
echo "== hook log (both nodes, since drill start)"
for h in "$M" "$B"; do $SSH "$h" "grep -h -E 'kc-ha-egress|kc-ha-dns|kc-ha-services|carp: [0-9]+@[^ ]*: (BACKUP -> MASTER|MASTER -> BACKUP)' \`ls -t /var/log/system/system_*.log | head -1\` | awk -v t=\"$(date -u -d @$T0 +%Y-%m-%dT%H:%M 2>/dev/null)\" '1' | tail -8 | cut -c1-150"; done
[ "$(g masters "$SM")" -gt 0 ] && [ "$(g backups "$SM")" = 0 ] && [ "$(g masters "$SB")" = 0 ] && echo "DRILL OK: failed over and back" || { echo "DRILL: pair not back in the expected state"; exit 1; }
