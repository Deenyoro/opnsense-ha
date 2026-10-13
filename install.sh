#!/bin/sh
# Install (or refresh) the kc-ha kit on ONE OPNsense node. Run from a
# workstation; repeat for every node of the pair, BACKUP NODE FIRST. Nothing
# here is carried by HA config sync, so each node must get it.
#
#   ./install.sh root@<backup-node>
#   ./install.sh root@<master-node>
#
# Idempotent. Site settings live in /usr/local/etc/kc-ha.conf on the node
# (created from kc-ha.conf.sample on first install, never overwritten). No
# script or hook carries a site value; this installer carries none either.
#
# Environment:
#   KC_HA_NO_PLUGIN=1   skip the carp-vip-dhcp plugin (sites without a DHCP WAN)
#   KC_HA_SSH="..."     ssh command to use (default "ssh"), e.g. a jump host or
#                       password login: "sshpass -f /root/.fwpw ssh -o ProxyJump=bastion"
#   KC_HA_PLUGIN_DIR    directory holding the plugin .pkg (default plugins/os-carp-vip-dhcp)
set -eu
host="${1:?usage: $0 root@<node>}"
SSH=${KC_HA_SSH:-ssh}
here=$(cd "$(dirname "$0")" && pwd)
version=$(cd "$here" && git describe --always --dirty 2>/dev/null || cat "$here/VERSION" 2>/dev/null || echo unknown)
plugdir=${KC_HA_PLUGIN_DIR:-$here/plugins/os-carp-vip-dhcp}

# Plugin: only installed if missing or a different version. Name and version
# come from the package file name (<name>-<version>.pkg).
# (no 2> redirects in the remote command: the OPNsense root shell is csh)
if [ -z "${KC_HA_NO_PLUGIN:-}" ]; then
    pkgfile=$(ls "$plugdir"/*.pkg | head -1)
    pkgbase=$(basename "$pkgfile" .pkg); pkgver=${pkgbase##*-}; pkgname=${pkgbase%-*}
    if [ "$($SSH "$host" "pkg query %v $pkgname")" != "$pkgver" ]; then
        echo "installing $pkgname $pkgver on $host"
        $SSH "$host" "cat > /tmp/$(basename "$pkgfile")" < "$pkgfile"
        $SSH "$host" "pkg install -y /tmp/$(basename "$pkgfile") && rm -f /tmp/$(basename "$pkgfile")"
    fi
fi

# Releases before kc-ha.conf existed kept site values inside the scripts. Read
# them from the files that are about to be replaced, so the node keeps behaving
# as it did: the reference vhid, and the interface list of the jumbo-MTU hook.
$SSH "$host" "sh -s" <<'REMOTE'
m=/usr/local/etc/kc-ha.migrate; : > $m
v=$(grep -hoE '(^|[; ])VHID=[0-9]+' /usr/local/sbin/kc-ha-lib /usr/local/sbin/kc-ha-egress /usr/local/sbin/kc-unbound-master 2>/dev/null | grep -oE '[0-9]+' | head -1)
[ -n "$v" ] && echo "OLD_VHID=$v" >> $m
j=$(sed -n 's/^for i in \(.*\); do$/\1/p' /usr/local/etc/rc.syshook.d/start/97-kc-jumbo-mtu 2>/dev/null | head -1)
case "$j" in ""|*'$'*) ;; *) echo "OLD_JUMBO=\"$j\"" >> $m ;; esac
exit 0
REMOTE

# Scripts, hooks, cron (tar over ssh). The sample config is shipped next to the
# live one; the live one is created only if missing.
( cd "$here/files" && tar -cf - usr etc ) | $SSH "$host" "tar -xf - -C /"
$SSH "$host" "sh -s" <<'REMOTE'
chmod 755 /usr/local/sbin/kc-* /usr/local/etc/rc.syshook.d/carp/*-kc-* /usr/local/etc/rc.syshook.d/start/9*-kc-* /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd
chmod 644 /etc/cron.d/kc-ha-master-services /usr/local/etc/kc-ha.conf.sample
conf=/usr/local/etc/kc-ha.conf; m=/usr/local/etc/kc-ha.migrate
OLD_VHID=""; OLD_JUMBO=""; [ -r $m ] && . $m
if [ ! -f $conf ]; then
    cp /usr/local/etc/kc-ha.conf.sample $conf
    if [ -n "$OLD_VHID" ]; then
        sed -i '' "s/^VHID=.*/VHID=$OLD_VHID/" $conf
        echo "kc-ha.conf created; VHID=$OLD_VHID carried over from the scripts that were installed"
    else
        echo "kc-ha.conf created from the sample"
    fi
fi
# A setting introduced after a node's kc-ha.conf was created is appended once,
# with the value the node was using.
if ! grep -q '^JUMBO_MTU_IFS=' $conf; then
    printf '\n# added by install.sh (see kc-ha.conf.sample); value carried over from the hook that was installed\nJUMBO_MTU_IFS="%s"\n' "$OLD_JUMBO" >> $conf
    [ -n "$OLD_JUMBO" ] && echo "kc-ha.conf: added JUMBO_MTU_IFS=\"$OLD_JUMBO\" (was written in the hook before)"
fi
rm -f $m
# Names used by the second-site prototype before kc-ha-master-services existed:
# two managers for the same services would fight, so the old one is retired.
for f in /usr/local/sbin/ha-master-services /usr/local/etc/rc.syshook.d/carp/30-ha-master-services \
         /usr/local/etc/rc.syshook.d/start/98-ha-master-services /etc/cron.d/ha-master-services; do
    [ -e "$f" ] && rm -f "$f" && echo "retired $f"
done
. /usr/local/sbin/kc-ha-lib
if [ -z "$VHID" ]; then
    echo "WARNING: VHID is not set in $conf: the kit does nothing on this node until it is."
    echo "         Set it (and whatever else applies) on BOTH nodes, then re-run install.sh."
elif ! /sbin/ifconfig | grep -q "vhid $VHID "; then
    echo "WARNING: $conf has VHID=$VHID but this node has no CARP VIP with that vhid."
fi
exit 0
REMOTE
$SSH "$host" "sh -c 'echo $version > /usr/local/etc/kc-ha.version'"

# Apply immediately. Every hook is idempotent; the only one that can disturb a
# running node is 95-pfsync-maxupd when maxupd differs from PFSYNC_MAXUPD:
# changing it restarts the pfsync bulk sync, which demotes CARP for ~1 s (a
# MASTER hands over and preempts back). So on a MASTER the script warns and
# leaves it for the next reboot. 97-kc-jumbo-mtu only touches the interfaces
# named in kc-ha.conf (none by default) and never a WAN device.
$SSH "$host" "sh -s" <<'REMOTE'
. /usr/local/sbin/kc-ha-lib
echo "-- dry run of kc-ha-egress (what it would change now):"
/usr/local/sbin/kc-ha-egress --dry-run
/usr/local/sbin/kc-ha-egress
echo "-- jumbo MTU hook (what it would change now; nothing listed = nothing to do):"
KC_HA_DRY=1 /usr/local/etc/rc.syshook.d/start/97-kc-jumbo-mtu
/usr/local/etc/rc.syshook.d/start/97-kc-jumbo-mtu
/usr/local/sbin/kc-ha-master-services
cur=$(ifconfig pfsync0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="maxupd:") print $(i+1)}')
if [ -n "$PFSYNC_MAXUPD" ] && [ "$cur" != "$PFSYNC_MAXUPD" ]; then
    if ifconfig | grep -q "carp: MASTER"; then
        echo "WARNING: pfsync maxupd is $cur (PFSYNC_MAXUPD=$PFSYNC_MAXUPD) and this node is CARP MASTER; not changing it live (would cause a ~1 s CARP flip). It applies at the next reboot, or run /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd in a maintenance window."
    else
        /usr/local/etc/rc.syshook.d/start/95-pfsync-maxupd
    fi
fi
echo "-- status after install:"
/usr/local/sbin/kc-ha-status
REMOTE
echo "done: $host (kc-ha $version)"
