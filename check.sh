#!/bin/sh
# Verify the HA pair end to end. Run after every OPNsense update or config change:
#   ./check.sh root@10.10.12.2 root@10.10.12.3
# Exit 0 = everything as expected. Any FAIL line: fix it, usually ./install.sh <node>.
set -u
[ $# -eq 2 ] || { echo "usage: $0 root@<node-a> root@<node-b>"; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
pkgver=$(basename "$(ls "$here"/plugins/os-carp-vip-dhcp/os-carp-vip-dhcp-*.pkg | head -1)" .pkg | sed 's/^os-carp-vip-dhcp-//')
fails=0
ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }

# One ssh per node; the remote side runs sh (login shell is csh). Prints KEY=VALUE lines.
collect() {
    ssh "$1" 'sh -s' <<'REMOTE'
echo "hostname=$(hostname)"
echo "version=$(opnsense-version -v)"
echo "pkg=$(pkg query %v os-carp-vip-dhcp)"
for f in /usr/local/sbin/kc-ha-egress /usr/local/sbin/kc-unbound-master \
         /usr/local/etc/rc.syshook.d/carp/10-kc-ha-egress /usr/local/etc/rc.syshook.d/carp/20-kc-unbound-master \
         /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd /usr/local/etc/rc.syshook.d/start/96-kc-ha-egress \
         /usr/local/etc/rc.syshook.d/start/97-kc-jumbo-mtu; do
    if [ -x "$f" ]; then echo "md5:$f=$(md5 -q "$f")"; else echo "md5:$f=MISSING"; fi
done
echo "keeper=$(service carpvipdhcp status)"
echo "keeper_hb_age=$(( $(date +%s) - $(stat -f %m /var/run/carpvipdhcp-*.hb 2>/dev/null || echo 0) ))"
echo "keeper_last=$(grep -h 'INFO' /var/log/carpvipdhcp-*.log | tail -1 | cut -c1-120)"
echo "carp=$(ifconfig | awk '/carp:/ {printf "%s:%s ", $4, $2}')"
echo "pfsync=$(ifconfig pfsync0 | awk '/syncok/ {s=$2} /maxupd/ {for(i=1;i<=NF;i++) if($i=="maxupd:") m=$(i+1)} END {printf "syncok=%s maxupd=%s", s, m}')"
echo "demotion=$(sysctl -n net.inet.carp.demotion)"
echo "default=$(netstat -rn -f inet | awk '$1=="default"{print $2; exit}')"
echo "egress=$(netstat -rn -f inet | awk '$1=="0.0.0.0/1"||$1=="128.0.0.0/1"{printf "%s>%s ", $1, $2}')"
echo "mtu=$(ifconfig vtnet1_vlan12 | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')"
echo "kea=$(curl -s -m 3 -X POST -H 'Content-Type: application/json' -d '{"command":"status-get","service":["dhcp4"]}' http://127.0.0.1:8000/ | /usr/local/bin/python3 -c 'import sys,json; h=json.load(sys.stdin)[0]["arguments"]["high-availability"][0]["ha-servers"]; print(h["local"]["role"], h["local"]["state"], "remote", h["remote"]["last-state"], "in-touch", h["remote"]["in-touch"])' 2>/dev/null)"
echo "gateways=$(/usr/local/bin/python3 -c '
import xml.etree.ElementTree as ET
r=ET.parse("/conf/config.xml").getroot()
print(";".join("%s/%s/prio%s/up%s/ks%s/fd%s" % (g.findtext("name"),g.findtext("gateway"),g.findtext("priority"),g.findtext("defaultgw") or 0,g.findtext("monitor_killstates") or 0,g.findtext("force_down") or 0) for g in r.find("OPNsense/Gateways").iter("gateway_item")), end="")
s=r.find("system"); print(" gw_switch_default=%s skip_rules_gw_down=%s" % (s.findtext("gw_switch_default"), s.findtext("skip_rules_gw_down")), end="")
print(" wan_gw=%s" % r.findtext("interfaces/wan/gateway"), end="")
print(" keepers=%d" % len(list(r.find("OPNsense/CarpVipDhcp/keepers").iter("keeper"))), end="")
')"
echo "hooks_unexpected=$(ls /usr/local/etc/rc.syshook.d/carp /usr/local/etc/rc.syshook.d/start | grep -E 'kc|pfsync' | sort | tr '\n' ' ')"
REMOTE
}
get() { printf '%s\n' "$2" | sed -n "s|^$1=||p" | head -1; }

A=$(collect "$1"); B=$(collect "$2")
for n in A B; do
    eval "D=\$$n"
    host=$(get hostname "$D"); echo "== $host ($(get version "$D"))"
    [ "$(get pkg "$D")" = "$pkgver" ] && ok "os-carp-vip-dhcp $pkgver" || fail "os-carp-vip-dhcp is '$(get pkg "$D")', repo has $pkgver"
    for f in $(cd "$here/files" && find usr -type f | sort); do
        want=$(md5sum "$here/files/$f" | cut -d' ' -f1); have=$(get "md5:/$f" "$D")
        [ "$want" = "$have" ] && ok "/$f" || fail "/$f differs from repo ($have)"
    done
    case "$(get keeper "$D")" in *"is running"*) ok "keeper: $(get keeper "$D")" ;; *) fail "keeper not running" ;; esac
    [ "$(get keeper_hb_age "$D")" -lt 600 ] 2>/dev/null && ok "keeper heartbeat $(get keeper_hb_age "$D")s old; last: $(get keeper_last "$D")" || fail "keeper heartbeat stale ($(get keeper_hb_age "$D")s): $(get keeper_last "$D")"
    [ "$(get pfsync "$D")" = "syncok=1 maxupd=8" ] && ok "pfsync syncok maxupd 8" || fail "pfsync: $(get pfsync "$D")"
    [ "$(get demotion "$D")" = 0 ] && ok "carp demotion 0" || fail "carp demotion is $(get demotion "$D") (a drill left it set?)"
    [ "$(get mtu "$D")" = 9000 ] && ok "vtnet1_vlan12 mtu 9000" || fail "vtnet1_vlan12 mtu $(get mtu "$D")"
    case "$(get kea "$D")" in *"in-touch True"*) ok "kea HA: $(get kea "$D")" ;; *) fail "kea HA: $(get kea "$D")" ;; esac
    carp=$(get carp "$D"); def=$(get default "$D"); eg=$(get egress "$D")
    case "$carp" in
        *BACKUP*MASTER*|*MASTER*BACKUP*) fail "mixed CARP roles: $carp" ;;
        *MASTER*)  [ -z "$eg" ] && ok "MASTER, no backup-egress routes" || fail "MASTER still has egress routes: $eg" ;;
        *BACKUP*)  [ "$(printf '%s' "$eg" | wc -w)" -eq 2 ] && ok "BACKUP, egress via master: $eg" || fail "BACKUP missing egress routes: '$eg'" ;;
        *) fail "no CARP state: '$carp'" ;;
    esac
    case "$def" in ""|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*) fail "default route is '${def:-none}'" ;; *) ok "default route $def" ;; esac
    case "$(get gateways "$D")" in *"/ks1"*) fail "a gateway has kill-states on" ;; esac
    case "$(get gateways "$D")" in *"gw_switch_default=1"*"skip_rules_gw_down=1"*"wan_gw=WAN_DHCP"*) ok "gw_switch_default, skip_rules_gw_down, wan gateway set" ;; *) fail "system/gateway flags: $(get gateways "$D")" ;; esac
done
echo "== pair"
[ "$(get gateways "$A")" = "$(get gateways "$B")" ] && ok "gateways + flags identical on both nodes" || { fail "gateways differ (not HA-synced; edit both):"; echo "    A: $(get gateways "$A")"; echo "    B: $(get gateways "$B")"; }
[ "$(get version "$A")" = "$(get version "$B")" ] && ok "same OPNsense version" || fail "versions differ: $(get version "$A") vs $(get version "$B")"
ca=$(get carp "$A"); cb=$(get carp "$B")
if printf '%s' "$ca" | grep -q MASTER && printf '%s' "$cb" | grep -q MASTER; then fail "both nodes MASTER (split brain)"; fi
if ! printf '%s%s' "$ca" "$cb" | grep -q MASTER; then fail "no node is MASTER"; fi
[ "$(printf '%s' "$ca" | wc -w)" -eq "$(printf '%s' "$cb" | wc -w)" ] && ok "same number of CARP VIPs ($(printf '%s' "$ca" | wc -w | tr -d ' '))" || fail "VIP count differs"
echo; [ $fails -eq 0 ] && echo "ALL OK" || echo "$fails FAIL(s)"
exit $((fails > 0))
