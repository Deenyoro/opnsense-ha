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
set -eu
host="${1:?usage: $0 root@<node>}"
here=$(cd "$(dirname "$0")" && pwd)
version=$(cd "$here" && git describe --always --dirty 2>/dev/null || echo unknown)

# Plugin: only installed if missing or a different version.
# (no shell redirects in the remote command: the OPNsense root shell is csh)
if [ -z "${KC_HA_NO_PLUGIN:-}" ]; then
    pkgfile=$(ls "$here"/plugins/os-carp-vip-dhcp/os-carp-vip-dhcp-*.pkg | head -1)
    pkgver=$(basename "$pkgfile" .pkg | sed 's/^os-carp-vip-dhcp-//')
    if [ "$(ssh "$host" "pkg query %v os-carp-vip-dhcp")" != "$pkgver" ]; then
        echo "installing os-carp-vip-dhcp $pkgver on $host"
        scp -q "$pkgfile" "$host:/tmp/"
        ssh "$host" "pkg install -y /tmp/$(basename "$pkgfile") && rm -f /tmp/$(basename "$pkgfile")"
    fi
fi

# Scripts, hooks, cron (tar over ssh). The sample config is shipped next to the
# live one; the live one is created only if missing.
( cd "$here/files" && tar -cf - usr etc ) | ssh "$host" "tar -xf - -C /"
ssh "$host" "sh -s" <<'REMOTE'
chmod 755 /usr/local/sbin/kc-* /usr/local/etc/rc.syshook.d/carp/*-kc-* /usr/local/etc/rc.syshook.d/start/9*-kc-* /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd
chmod 644 /etc/cron.d/kc-ha-master-services /usr/local/etc/kc-ha.conf.sample
[ -f /usr/local/etc/kc-ha.conf ] || cp /usr/local/etc/kc-ha.conf.sample /usr/local/etc/kc-ha.conf
REMOTE
ssh "$host" "sh -c 'echo $version > /usr/local/etc/kc-ha.version'"

# Apply immediately. Every hook is idempotent; the only one that can disturb a
# running node is 95-pfsync-maxupd when maxupd is still at the default: changing
# it restarts the pfsync bulk sync, which demotes CARP for ~1 s (a MASTER hands
# over and preempts back). So on a MASTER whose maxupd is not yet 8 the script
# warns and leaves it for the next reboot.
ssh "$host" "sh -s" <<'REMOTE'
echo "-- dry run of kc-ha-egress (what it would change now):"
/usr/local/sbin/kc-ha-egress --dry-run
/usr/local/sbin/kc-ha-egress
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
