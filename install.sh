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
if [ "$(ssh "$host" "pkg query %v os-carp-vip-dhcp 2>/dev/null || true")" != "$pkgver" ]; then
    echo "installing os-carp-vip-dhcp $pkgver on $host"
    scp -q "$pkgfile" "$host:/tmp/"
    ssh "$host" "pkg install -y /tmp/$(basename "$pkgfile") && rm -f /tmp/$(basename "$pkgfile")"
fi

# Scripts and hooks (tar over ssh; the firewall's login shell is csh, so keep it to one command).
( cd "$here/files" && tar -cf - usr ) | ssh "$host" "tar -xf - -C / && chmod 755 /usr/local/sbin/kc-ha-egress /usr/local/sbin/kc-unbound-master /usr/local/etc/rc.syshook.d/carp/*-kc-* /usr/local/etc/rc.syshook.d/start/9*-kc-* /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd"

# Apply immediately (idempotent) and show the result.
ssh "$host" "/usr/local/sbin/kc-ha-egress; /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd; netstat -rn -f inet | egrep '^(default|0.0.0.0/1|128.0.0.0/1) '; ifconfig pfsync0 | grep maxupd"
echo "done: $host"
