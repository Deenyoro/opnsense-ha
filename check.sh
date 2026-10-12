#!/bin/sh
# Verify the HA pair end to end. Run after every OPNsense update or config change:
#   ./check.sh root@<node-a> root@<node-b>
# Exit 0 = everything as expected. Any FAIL line: fix it, usually ./install.sh <node>.
# KC_HA_NO_PLUGIN=1 skips the carp-vip-dhcp checks (sites without a DHCP WAN).
set -u
[ $# -eq 2 ] || { echo "usage: $0 root@<node-a> root@<node-b>"; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
version=$(cd "$here" && git describe --always --dirty 2>/dev/null || echo unknown)
pkgver=$(basename "$(ls "$here"/plugins/os-carp-vip-dhcp/os-carp-vip-dhcp-*.pkg | head -1)" .pkg | sed 's/^os-carp-vip-dhcp-//')
fails=0
ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
warn() { echo "  warn $*"; }

# One ssh per node; the remote side runs sh (login shell is csh). Prints KEY=VALUE lines.
collect() {
    ssh "$1" 'sh -s' <<'REMOTE'
echo "hostname=$(hostname)"
echo "version=$(opnsense-version -v)"
echo "pkg=$(pkg query %v os-carp-vip-dhcp)"
for f in /usr/local/sbin/kc-ha-lib /usr/local/sbin/kc-ha-egress /usr/local/sbin/kc-unbound-master /usr/local/sbin/kc-ha-master-services /usr/local/sbin/kc-ha-status \
         /usr/local/etc/rc.syshook.d/carp/10-kc-ha-egress /usr/local/etc/rc.syshook.d/carp/20-kc-unbound-master /usr/local/etc/rc.syshook.d/carp/30-kc-ha-master-services \
         /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd /usr/local/etc/rc.syshook.d/start/96-kc-ha-egress /usr/local/etc/rc.syshook.d/start/97-kc-jumbo-mtu /usr/local/etc/rc.syshook.d/start/98-kc-ha-master-services \
         /etc/cron.d/kc-ha-master-services /usr/local/etc/kc-ha.conf.sample; do
    if [ -f "$f" ]; then echo "md5:$f=$(md5 -q "$f")"; else echo "md5:$f=MISSING"; fi
done
echo "conf=$(grep -v '^#' /usr/local/etc/kc-ha.conf 2>/dev/null | grep . | tr '\n' ' ')"
/usr/local/sbin/kc-ha-status --kv 2>/dev/null | sed 's/^/st:/'
echo "keeper_hb_age=$(( $(date +%s) - $(stat -f %m /var/run/carpvipdhcp-*.hb 2>/dev/null || echo 0) ))"
echo "keeper_last=$(grep -h 'INFO' /var/log/carpvipdhcp-*.log 2>/dev/null | tail -1 | cut -c1-120)"
echo "mtu=$(ifconfig vtnet1_vlan12 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')"
echo "kea=$(curl -s -m 3 -X POST -H 'Content-Type: application/json' -d '{"command":"status-get","service":["dhcp4"]}' http://127.0.0.1:8000/ | /usr/local/bin/python3 -c 'import sys,json; h=json.load(sys.stdin)[0]["arguments"]["high-availability"][0]["ha-servers"]; print(h["local"]["role"], h["local"]["state"], "remote", h["remote"]["last-state"], "in-touch", h["remote"]["in-touch"])' 2>/dev/null)"
echo "carprules=$(pfctl -sr 2>/dev/null | grep -c 'proto carp')"
# anchors of master-only services (e.g. miniupnpd) legitimately exist on the master only
echo "rules=$(pfctl -sr 2>/dev/null | grep -v -E '^(nat-|rdr-)?anchor "(miniupnpd)"' | wc -l | tr -d ' ') nat=$(pfctl -sn 2>/dev/null | grep -v -E '^(nat-|rdr-)?anchor "(miniupnpd)"' | wc -l | tr -d ' ')"
echo "hooks=$(ls /usr/local/etc/rc.syshook.d/carp /usr/local/etc/rc.syshook.d/start | sort | tr '\n' ' ')"
echo "timedout=$(grep -h -c 'master timed out' /var/log/system/latest.log 2>/dev/null)"
/usr/local/bin/python3 - <<'PY'
import xml.etree.ElementTree as ET
r=ET.parse("/conf/config.xml").getroot()
ifs=r.find("interfaces")
print("devices=" + ";".join("%s=%s" % (i.tag, i.findtext("if")) for i in ifs if i.findtext("if")))
print("ifgw=" + ";".join("%s=%s" % (i.tag, i.findtext("gateway")) for i in ifs if i.findtext("gateway")))
print("gateways=" + ";".join("%s/%s/%s/prio%s/up%s/ks%s/fd%s/far%s/dis%s" % (g.findtext("name"),g.findtext("interface"),g.findtext("gateway"),g.findtext("priority"),g.findtext("defaultgw") or 0,g.findtext("monitor_killstates") or 0,g.findtext("force_down") or 0,g.findtext("fargw") or 0,g.findtext("disabled") or 0) for g in r.find("OPNsense/Gateways").iter("gateway_item")), end="")
s=r.find("system"); print(" gw_switch_default=%s skip_rules_gw_down=%s" % (s.findtext("gw_switch_default"), s.findtext("skip_rules_gw_down")))
print("vips=" + ";".join("%s/%s/%s/skew%s" % (v.findtext("interface"),v.findtext("subnet"),v.findtext("vhid"),v.findtext("advskew")) for v in r.find("virtualip").iter("vip") if v.findtext("mode")=="carp"))
print("sysctl=" + ";".join("%s=%s" % (i.findtext("tunable"), i.findtext("value")) for i in r.find("sysctl").iter("item") if (i.findtext("value") or "") not in ("", "default")))
h=r.find("hasync"); print("hasync=pfsyncif=%s pfsyncversion=%s preempt_disabled=%s" % (h.findtext("pfsyncinterface"), h.findtext("pfsyncversion"), h.findtext("disablepreempt")))
print("keepers=%d" % len(list(r.find("OPNsense/CarpVipDhcp/keepers").iter("keeper"))) if r.find("OPNsense/CarpVipDhcp/keepers") is not None else "keepers=0")
PY
REMOTE
}
get() { printf '%s\n' "$2" | sed -n "s|^$1=||p" | head -1; }

A=$(collect "$1"); B=$(collect "$2")
for n in A B; do
    eval "D=\$$n"
    host=$(get hostname "$D"); echo "== $host ($(get version "$D")) kc-ha $(get st:version "$D")"
    [ "$(get st:version "$D")" = "$version" ] && ok "kc-ha version $version" || warn "node has kc-ha '$(get st:version "$D")', repo is $version"
    if [ -z "${KC_HA_NO_PLUGIN:-}" ]; then
        [ "$(get pkg "$D")" = "$pkgver" ] && ok "os-carp-vip-dhcp $pkgver" || fail "os-carp-vip-dhcp is '$(get pkg "$D")', repo has $pkgver"
        case "$(get st:keeper "$D")" in *"is running"*) ok "keeper: $(get st:keeper "$D")" ;; *) fail "keeper not running" ;; esac
        [ "$(get keeper_hb_age "$D")" -lt 600 ] 2>/dev/null && ok "keeper heartbeat $(get keeper_hb_age "$D")s old; last: $(get keeper_last "$D")" || fail "keeper heartbeat stale ($(get keeper_hb_age "$D")s): $(get keeper_last "$D")"
        [ "$(get keepers "$D")" -ge 1 ] 2>/dev/null && ok "$(get keepers "$D") keeper(s) configured" || fail "no keeper configured"
    fi
    for f in $(cd "$here/files" && find usr etc -type f | sort); do
        want=$(md5sum "$here/files/$f" | cut -d' ' -f1); have=$(get "md5:/$f" "$D")
        [ "$want" = "$have" ] && ok "/$f" || fail "/$f differs from repo ($have)"
    done
    [ -n "$(get conf "$D")" ] && ok "kc-ha.conf: $(get conf "$D")" || fail "no /usr/local/etc/kc-ha.conf"
    [ "$(get st:pfsync "$D")" = "syncok=1 maxupd=8 version=1500" ] && ok "pfsync $(get st:pfsync "$D")" || fail "pfsync: $(get st:pfsync "$D")"
    [ "$(get st:demotion "$D")" = 0 ] && ok "carp demotion 0" || fail "carp demotion is $(get st:demotion "$D") (a drill left it set, or pfsync bulk stuck: check 'syncok')"
    [ "$(get st:preempt "$D")" = 1 ] && ok "carp preempt on" || fail "carp preempt off"
    [ "$(get st:maintenance "$D")" = 0 ] && ok "not in persistent CARP maintenance mode" || fail "persistent CARP maintenance mode is on"
    [ "$(get st:peer "$D")" = alive ] && ok "pfsync peer answers on SYNC" || fail "pfsync peer does not answer on SYNC"
    [ "$(get carprules "$D")" -ge 2 ] 2>/dev/null && ok "$(get carprules "$D") 'proto carp' rules loaded" || fail "no 'proto carp' pass rules loaded (run: configctl filter reload)"
    [ "$(get timedout "$D")" = 0 ] && ok "no 'master timed out' events in today's log" || warn "$(get timedout "$D") 'master timed out' event(s) in today's log (boot-time dual master?)"
    [ "$(get mtu "$D")" = 9000 ] && ok "vtnet1_vlan12 mtu 9000" || warn "vtnet1_vlan12 mtu '$(get mtu "$D")' (only matters on the KC pair)"
    case "$(get kea "$D")" in *"in-touch True"*) ok "kea HA: $(get kea "$D")" ;; "") warn "kea HA status not available (not using Kea HA?)" ;; *) fail "kea HA: $(get kea "$D")" ;; esac
    nm=$(get st:masters "$D"); nb=$(get st:backups "$D"); eg=$(get st:egress "$D"); def=$(get st:default "$D")
    if [ "$nm" -gt 0 ] && [ "$nb" -gt 0 ]; then fail "mixed CARP roles: $nm MASTER / $nb BACKUP"
    elif [ "$nm" -gt 0 ]; then [ -z "$eg" ] && ok "MASTER ($nm VIPs), no backup-egress routes" || fail "MASTER still has egress routes: $eg"
    elif [ "$nb" -gt 0 ]; then [ "$(printf '%s' "$eg" | wc -w)" -eq 2 ] && ok "BACKUP ($nb VIPs), egress via master: $eg" || fail "BACKUP missing egress routes: '$eg'"
    else fail "no CARP VIPs"; fi
    case "$def" in ""|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*) fail "default route is '${def:-none}'" ;;
        *) dev=${def#*@}; gw=${def%@*}; want=$(printf '%s\n' "$(get devices "$D")" | tr ';' '\n' | sed -n "s/^$(printf '%s' "$(get gateways "$D")" | tr ';' '\n' | grep "/$gw/" | cut -d/ -f2)=//p")
           if [ -n "$want" ] && [ "$want" != "$dev" ]; then fail "default route $gw is on $dev, its WAN device is $want"; else ok "default route $def"; fi ;;
    esac
    case "$(get gateways "$D")" in *"/ks1/"*) fail "a gateway has kill-states on" ;; esac
    case "$(get gateways "$D")" in *"gw_switch_default=1"*) ok "gw_switch_default on" ;; *) warn "gw_switch_default off (no automatic WAN failover of the default route)" ;; esac
    case "$(get ifgw "$D")" in *wan=*) ok "wan interface has its gateway set (reply-to)" ;; *) fail "wan interface has no gateway (no reply-to on WAN1 rules)" ;; esac
done
echo "== pair"
for k in devices ifgw gateways vips sysctl hasync hooks conf; do
    va=$(get $k "$A"); vb=$(get $k "$B")
    case $k in
        vips) va=$(printf '%s' "$va" | sed 's/skew[0-9]*//g'); vb=$(printf '%s' "$vb" | sed 's/skew[0-9]*//g') ;;   # skew differs by design
    esac
    [ "$va" = "$vb" ] && ok "$k identical on both nodes" || { fail "$k differ (not HA-synced; edit both):"; echo "    A: $va"; echo "    B: $vb"; }
done
[ "$(get version "$A")" = "$(get version "$B")" ] && ok "same OPNsense version" || fail "versions differ: $(get version "$A") vs $(get version "$B")"
[ "$(get rules "$A")" = "$(get rules "$B")" ] && ok "same loaded rule/NAT counts ($(get rules "$A"))" || fail "rule/NAT counts differ: $(get rules "$A") vs $(get rules "$B")"
sa=$(get st:states "$A"); sb=$(get st:states "$B"); d=$((sa - sb)); [ $d -lt 0 ] && d=$((-d))
[ $d -le $(( (sa + 1) / 5 )) ] && ok "state tables within 20% ($sa / $sb)" || fail "state tables differ a lot ($sa / $sb): pfsync not replicating?"
ma=$(get st:masters "$A"); mb=$(get st:masters "$B")
[ "$ma" -gt 0 ] && [ "$mb" -gt 0 ] && fail "both nodes MASTER (split brain)"
[ "$ma" -eq 0 ] && [ "$mb" -eq 0 ] && fail "no node is MASTER"
[ "$((ma + $(get st:backups "$A")))" -eq "$((mb + $(get st:backups "$B")))" ] && ok "same number of CARP VIPs ($((ma + $(get st:backups "$A"))))" || fail "VIP count differs"
echo; [ $fails -eq 0 ] && echo "ALL OK" || echo "$fails FAIL(s)"
exit $((fails > 0))
