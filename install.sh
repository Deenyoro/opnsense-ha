#!/bin/sh
# Install (or refresh) the kc-ha kit on ONE OPNsense node. Run from a
# workstation; repeat for every node of the pair, BACKUP NODE FIRST. Nothing
# here is carried by HA config sync, so each node must get it.
#
#   ./install.sh root@10.10.12.3     # backup
#   ./install.sh root@10.10.12.2     # master
#
# Idempotent. Site settings live in /usr/local/etc/kc-ha.conf on the node
# (created from kc-ha.conf.sample on first install, never overwritten).
# Skip the carp-vip-dhcp plugin with KC_HA_NO_PLUGIN=1 (sites without a DHCP WAN).
# KC_HA_SSH overrides the ssh command (default "ssh"), e.g. for a jump host or
# password login:  KC_HA_SSH="sshpass -f /root/.fwpw ssh -o ProxyJump=bastion"
set -eu
host="${1:?usage: $0 root@<node>}"
SSH=${KC_HA_SSH:-ssh}
here=$(cd "$(dirname "$0")" && pwd)
version=$(cd "$here" && git describe --always --dirty 2>/dev/null || cat "$here/VERSION" 2>/dev/null || echo unknown)

# Plugin: only installed if missing or a different version.
# (no shell redirects in the remote command: the OPNsense root shell is csh)
if [ -z "${KC_HA_NO_PLUGIN:-}" ]; then
    pkgfile=$(ls "$here"/plugins/os-carp-vip-dhcp/os-carp-vip-dhcp-*.pkg | head -1)
    pkgver=$(basename "$pkgfile" .pkg | sed 's/^os-carp-vip-dhcp-//')
    if [ "$($SSH "$host" "pkg query %v os-carp-vip-dhcp")" != "$pkgver" ]; then
        echo "installing os-carp-vip-dhcp $pkgver on $host"
        $SSH "$host" "cat > /tmp/$(basename "$pkgfile")" < "$pkgfile"
        $SSH "$host" "pkg install -y /tmp/$(basename "$pkgfile") && rm -f /tmp/$(basename "$pkgfile")"
    fi
fi

# Scripts, hooks, cron (tar over ssh). The sample config is shipped next to the
# live one; the live one is created only if missing.
( cd "$here/files" && tar -cf - usr etc ) | $SSH "$host" "tar -xf - -C /"
$SSH "$host" "sh -s" <<'REMOTE'
chmod 755 /usr/local/sbin/kc-* /usr/local/etc/rc.syshook.d/carp/*-kc-* /usr/local/etc/rc.syshook.d/start/9*-kc-* /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd
chmod 644 /etc/cron.d/kc-ha-master-services /usr/local/etc/kc-ha.conf.sample
conf=/usr/local/etc/kc-ha.conf
[ -f $conf ] || cp /usr/local/etc/kc-ha.conf.sample $conf
# Settings added after a node's kc-ha.conf was created are appended once, with
# the value that keeps the node behaving as before.
if ! grep -q '^JUMBO_MTU_IFS=' $conf; then
    if /sbin/ifconfig vtnet1_vlan12 >/dev/null 2>&1; then
        # the KC pair: 97-kc-jumbo-mtu used to name these two in the script itself
        printf '\n# added by install.sh: formerly hardcoded in start/97-kc-jumbo-mtu\nJUMBO_MTU_IFS="vtnet1 vtnet1_vlan12"\n' >> $conf
        echo "kc-ha.conf: added JUMBO_MTU_IFS=\"vtnet1 vtnet1_vlan12\" (was hardcoded in the hook)"
    else
        printf '\n# added by install.sh: no jumbo interfaces on this node (see kc-ha.conf.sample)\nJUMBO_MTU_IFS=""\n' >> $conf
    fi
fi
# Names used by the second-site prototype before kc-ha-master-services existed:
# two managers for the same services would fight, so the old one is retired.
for f in /usr/local/sbin/ha-master-services /usr/local/etc/rc.syshook.d/carp/30-ha-master-services \
         /usr/local/etc/rc.syshook.d/start/98-ha-master-services /etc/cron.d/ha-master-services; do
    [ -e "$f" ] && rm -f "$f" && echo "retired $f"
done
if grep -q '^VHID=12$' $conf && ! /sbin/ifconfig | grep -q 'vhid 12 '; then
    echo "WARNING: kc-ha.conf still has the sample VHID=12 but this node has no CARP VIP with vhid 12."
    echo "         Set VHID (and MASTER_ONLY_SERVICES) in $conf on BOTH nodes; until then the kit does nothing."
fi
REMOTE
$SSH "$host" "sh -c 'echo $version > /usr/local/etc/kc-ha.version'"

# Apply immediately. Every hook is idempotent; the only one that can disturb a
# running node is 95-pfsync-maxupd when maxupd is still at the default: changing
# it restarts the pfsync bulk sync, which demotes CARP for ~1 s (a MASTER hands
# over and preempts back). So on a MASTER whose maxupd is not yet 8 the script
# warns and leaves it for the next reboot. 97-kc-jumbo-mtu only touches the
# interfaces named in kc-ha.conf (none by default) and never a WAN device.
$SSH "$host" "sh -s" <<'REMOTE'
echo "-- dry run of kc-ha-egress (what it would change now):"
/usr/local/sbin/kc-ha-egress --dry-run
/usr/local/sbin/kc-ha-egress
echo "-- jumbo MTU hook (what it would change now; nothing listed = nothing to do):"
KC_HA_DRY=1 /usr/local/etc/rc.syshook.d/start/97-kc-jumbo-mtu
/usr/local/etc/rc.syshook.d/start/97-kc-jumbo-mtu
/usr/local/sbin/kc-ha-master-services
cur=$(ifconfig pfsync0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="maxupd:") print $(i+1)}')
if [ "$cur" != 8 ]; then
    if ifconfig | grep -q "carp: MASTER"; then
        echo "WARNING: pfsync maxupd is $cur and this node is CARP MASTER; not changing it live (would cause a ~1 s CARP flip). It applies at the next reboot, or run /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd in a maintenance window."
    else
        /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd
    fi
fi
echo "-- status after install:"
/usr/local/sbin/kc-ha-status
REMOTE
echo "done: $host (kc-ha $version)"
