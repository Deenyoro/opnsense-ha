# opnsense-ha

The pieces that make an OPNsense HA pair fail over cleanly when a WAN has **one
ISP-assigned (DHCP) public address** and the backup node needs internet of its own.
Everything here is what runs on the KC pair (fw-a / fw-b, OPNsense 26.7) and was
verified by live drills (2026-09-23, 2026-10-08: takeover under a second, no packet,
DNS or Plex loss, clean failback).

Stock OPNsense HA gives you CARP VIPs, pfsync and config sync. Three things it does
**not** solve, and what this repo adds for each:

| Problem | Fix | Files |
|---|---|---|
| A DHCP WAN leases its address to the node's own MAC, so the address cannot float to the other node | `os-carp-vip-dhcp` plugin: a lease keeper on **both** nodes requests the lease with the CARP VIP's virtual MAC (`00:00:5e:00:01:<vhid>`); the ISP sees one client, the address lives on the VIP and moves with CARP. Follow mode rewrites VIP + gateway if the ISP ever hands out a new address | `plugins/os-carp-vip-dhcp/`, `examples/carpvipdhcp-settings.xml` |
| On the BACKUP node every WAN gateway monitor reads *down* (dpinger can only probe through the VIPs), so OPNsense installs no / a wrong default route. A fresh master forwards nothing until monitors recover; the backup node itself has no internet | `kc-ha-egress`: pins the kernel default route to an upstream gateway whenever OPNsense left none or a LAN one. Candidates come from the config (upstream gateways by priority); on MASTER the first one that answers a ping wins, so a dead primary WAN is not pinned during a takeover. On BACKUP it adds `0/1` + `128/1` via the master's LAN VIP (found by vhid in the config) so the backup gets updates, NTP, CrowdSec etc. Runs on every CARP event and at boot, serialised with `lockf`; `--show` prints what it sees, `--dry-run` what it would do | `files/usr/local/sbin/kc-ha-egress`, hooks `carp/10-kc-ha-egress`, `start/96-kc-ha-egress` |
| Unbound on the new master cached SERVFAILs while it was backup | `kc-unbound-master`: on the LAN VIP's MASTER event, restart Unbound and verify resolution | `files/usr/local/sbin/kc-unbound-master`, hook `carp/20-kc-unbound-master` |

Two smaller boot hooks, use if they apply:

- `start/95-pfsync-maxupd` – `pfsync0 maxupd 8` so standby TCP state windows are fresh
  enough for connections to survive a planned failover (default 128 was too stale).
- `start/97-kc-jumbo-mtu` – re-applies MTU 9000 on a VLAN whose (disabled) parent
  interface OPNsense never sizes. Site specific; drop it if you have no jumbo VLAN.

## Interface layout for a DHCP WAN

- Node addresses on the WAN interface: a private /29 (169.254.255.1 / .2), **not** DHCP.
  The interface still needs `<gateway>` set to the WAN gateway or OPNsense adds no
  `reply-to` to that WAN's rules and replies leave via the other WAN.
- Public address: a CARP VIP (own vhid, skew 0 on the master / 100 on the backup).
  Alias `wan1_carp_vip` is kept equal to the current address by the keeper.
- Gateway for that WAN: static, the ISP router, Upstream = yes, a unique priority,
  monitoring on, **kill states on failure off** (on the backup node every WAN is "down";
  it would purge the synced state table).
- Second WAN with a static address: plain CARP VIP, no keeper.
- Outbound NAT: translate to the VIP, plus one rule for the node /29 itself.

## What HA config sync does not carry (edit on every node)

Gateways and gateway groups, system tunables, `rc.syshook.d` hooks, Suricata,
CrowdSec, Tailscale, interface settings. `install.sh` covers the hook/script part.

## Install / re-apply / verify

```sh
./install.sh root@<backup-node>     # backup node first
./install.sh root@<master-node>
./check.sh   root@<node-a> root@<node-b>
```

`install.sh` is idempotent: it installs the plugin only when the version differs, copies
the scripts/hooks, and applies the hooks live. The one live step that can disturb a node
is `pfsync0 maxupd` when it is still at the default (changing it restarts the pfsync bulk
sync, which demotes CARP for ~1 s and makes a MASTER hand over and preempt back), so the
script refuses to change it live on a MASTER and leaves it for the next reboot. That is
why the backup node goes first.

`check.sh` is the acceptance test: plugin version, every file byte-identical to the repo,
keeper running with a fresh heartbeat, pfsync `syncok` + `maxupd 8`, CARP demotion 0,
one MASTER per VIP, backup-egress routes present only on the BACKUP, a real default route,
VLAN 12 MTU 9000, Kea HA in touch, gateway flags (upstream / priority / kill-states off)
identical on both nodes. Exit 0 = good.

### After an OPNsense update

Files under `/usr/local/sbin` and `rc.syshook.d` are not owned by any package, so minor
updates keep them. A major upgrade (new ABI, e.g. 26.7 → 27.1) may drop or break the
vendored `os-carp-vip-dhcp` package (it is not in the OPNsense repos and will not be
re-installed by the firmware health check). Procedure, one node at a time, backup first:

1. Update the backup node, reboot it, `./check.sh` → fix anything with `./install.sh`.
2. Hand over (`sysctl net.inet.carp.demotion=240` on the master), confirm services on the
   new master, update the old master, reboot, `./install.sh` if needed, fail back
   (`=-240`), `./check.sh`.

Then in the GUI (synced by HA): Services > CARP VIP DHCP > add a keeper for the WAN
VIP as in `examples/carpvipdhcp-settings.xml`; `examples/keeper.conf.rendered` is what
the plugin renders from it.

Edit before use on another site: `VHID` (default 12, the LAN-side CARP VIP the backup
reaches the master through) in `kc-ha-egress` (or set `KC_HA_VHID`) and `VIP_IF`/`VHID` in
`kc-unbound-master`; `97-kc-jumbo-mtu` names the jumbo interfaces.

## Failover test

```sh
sysctl net.inet.carp.demotion=240     # on the master: hand over
# ... probe ping / DNS / a WAN-bound service from the LAN ...
sysctl net.inet.carp.demotion=-240    # relative counter: undo with the negative, not 0
```

## Adding a WAN

1. Add the NIC to both VMs, assign on both nodes, node IPs from a private /29.
2. CARP VIP for the public address (new vhid); DHCP WAN → add a keeper on both nodes.
3. Gateway on both nodes: Upstream, unique priority, kill-states off. `kc-ha-egress`
   picks the primary by priority on its own, no edit needed.
4. Outbound NAT rules for the new VIP; decide which policy routes / gateway groups may
   use it.

## Plugin package

`plugins/os-carp-vip-dhcp/` holds the exact package installed on the pair
(`os-carp-vip-dhcp-1.13.8`, sha256 in `SHA256SUMS`, signature + `release.pub`
alongside). It is not in the OPNsense repos; `install.sh` installs it from here.
