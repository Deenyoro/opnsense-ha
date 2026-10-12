#!/bin/sh
# Install (or refresh) the HA helper scripts on ONE OPNsense node. Run from a
# workstation; repeat for every node of the pair. Nothing here is carried by
# HA config sync, so each node must get it.
#
#   ./install.sh root@10.10.12.2
#   ./install.sh root@10.10.12.3
#
# Before running on a new site, edit files/usr/local/sbin/kc-ha-egress and
# kc-unbound-master (VIP / interface / vhid of the LAN-side CARP VIP) and
# 97-kc-jumbo-mtu (only needed if a VLAN must stay at MTU 9000; otherwise skip it).
set -eu
host="${1:?usage: $0 root@<node>}"
here=$(cd "$(dirname "$0")" && pwd)

# Plugin: only installed if missing or a different version.
pkgfile=$(ls "$here"/plugins/os-carp-vip-dhcp/os-carp-vip-dhcp-*.pkg | head -1)
pkgver=$(basename "$pkgfile" .pkg | sed 's/^os-carp-vip-dhcp-//')
# (no shell redirects in the remote command: the OPNsense root shell is csh)
if [ "$(ssh "$host" "pkg query %v os-carp-vip-dhcp")" != "$pkgver" ]; then
    echo "installing os-carp-vip-dhcp $pkgver on $host"
    scp -q "$pkgfile" "$host:/tmp/"
    ssh "$host" "pkg install -y /tmp/$(basename "$pkgfile") && rm -f /tmp/$(basename "$pkgfile")"
fi

# Scripts and hooks (tar over ssh; the firewall's login shell is csh, so keep it to one command).
( cd "$here/files" && tar -cf - usr ) | ssh "$host" "tar -xf - -C / && chmod 755 /usr/local/sbin/kc-ha-egress /usr/local/sbin/kc-unbound-master /usr/local/etc/rc.syshook.d/carp/*-kc-* /usr/local/etc/rc.syshook.d/start/9*-kc-* /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd"

# Apply immediately. Every hook is idempotent; the only one that can disturb a
# running node is 95-pfsync-maxupd when maxupd is still at the default: changing
# it restarts the pfsync bulk sync, which demotes CARP for ~1 s (a MASTER hands
# over and preempts back). So: install on the BACKUP node first, and on a MASTER
# whose maxupd is not yet 8 the script warns and leaves it for the next reboot.
ssh "$host" "sh -s" <<'REMOTE'
/usr/local/sbin/kc-ha-egress
/usr/local/etc/rc.syshook.d/start/97-kc-jumbo-mtu
cur=$(ifconfig pfsync0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="maxupd:") print $(i+1)}')
if [ "$cur" != 8 ]; then
    if ifconfig | grep -q "carp: MASTER"; then
        echo "WARNING: pfsync maxupd is $cur and this node is CARP MASTER; not changing it live (would cause a ~1 s CARP flip). It applies at the next reboot, or run /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd during a maintenance window."
    else
        /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd
    fi
fi
netstat -rn -f inet | egrep '^(default|0.0.0.0/1|128.0.0.0/1) '
ifconfig pfsync0 | grep maxupd
REMOTE
echo "done: $host"
