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
  interface OPNsense never sizes. Opt-in: it only touches the interfaces listed in
  `JUMBO_MTU_IFS` in `kc-ha.conf` (none by default) and refuses any device that carries
  an upstream gateway, so it is safe to install on every site.

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

## Contents

| Path | Purpose |
|---|---|
| `files/usr/local/sbin/kc-ha-lib` | shared helpers: reads `kc-ha.conf` + `config.xml` (reference VIP by vhid, its device, pfsync peer, upstream gateways with devices), role, uptime, peer-alive, boot-grace gate |
| `kc-ha-egress` | default route / backup egress (above) |
| `kc-unbound-master` | Unbound restart on a trusted MASTER event |
| `kc-ha-master-services` | start/stop `MASTER_ONLY_SERVICES` by role (carp hook, boot, cron every 2 min) |
| `kc-ha-status` | one-screen status of a node (`--kv` for scripts) |
| `files/usr/local/etc/kc-ha.conf.sample` | site settings: `VHID`, `BOOT_GRACE`, `MASTER_ONLY_SERVICES`, `JUMBO_MTU_IFS`; copied to `kc-ha.conf` once |
| `install.sh` | idempotent install of plugin + files + version stamp, then live apply and status |
| `check.sh` | acceptance test of the pair (below) |
| `drill.sh` | controlled failover/failback with probes of existing flows |

Nothing is hardcoded per node or per site: the same files are installed unchanged on
every node of every site; only `kc-ha.conf` (identical on both nodes) carries site
choices. No script or hook names a vhid, a VIP or a device.

### First install on a new site

1. Create `/usr/local/etc/kc-ha.conf` on **both** nodes before (or right after) the first
   `install.sh`: `VHID` = the LAN-side CARP VIP the backup reaches the master through,
   `MASTER_ONLY_SERVICES` if any, `JUMBO_MTU_IFS` only if you have such a VLAN. With the
   sample `VHID=12` on a site that has no vhid 12 the kit does nothing and `install.sh`
   says so.
2. `KC_HA_NO_PLUGIN=1` if no WAN is DHCP.
3. `KC_HA_SSH="..."` if the workstation reaches the nodes through a jump host or with a
   password (`install.sh`, `check.sh` and `drill.sh` all honour it). Without git on the
   workstation the version stamp is read from a `VERSION` file next to `install.sh`.

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

`check.sh` is the acceptance test. Per node: kc-ha version stamp, plugin version, every
file byte-identical to the repo, keeper running with a fresh heartbeat, pfsync `syncok` +
`maxupd 8`, CARP demotion 0 / preempt on / not in maintenance mode, peer answering on the
SYNC link, `proto carp` pass rules loaded, no "master timed out" in today's log, every
`JUMBO_MTU_IFS` interface at its MTU and none of them a WAN device, no retired prototype
files left, one role
per node, backup-egress routes only on the BACKUP, default route on a real gateway **and
on that gateway's WAN device**, no kill-states on gateways, wan interface gateway set, Kea
HA in touch. Pair: interface **device names**, interface gateways, gateways, VIPs (minus
skew), tunables, hasync items, hook directories and `kc-ha.conf` identical; same OPNsense
version and pfsync protocol version (1400 on 26.1, 1500 on 26.7; not judged per node);
same loaded rule/NAT counts; state tables within 20%; exactly one MASTER.
Exit 0 = good. `KC_HA_NO_PLUGIN=1` for a site without the DHCP-WAN plugin.

`drill.sh root@<master> root@<backup> [hold]` pre-flights both nodes, probes an existing
ping flow, DNS at the VIP and one persistent HTTPS connection from the workstation, demotes
the master **detached on the node** (so it fails back by itself even if you lose it), and
reports losses per phase plus the hook log lines. Expect 0-1 lost pings and 0 DNS/HTTPS
failures.

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

On another site nothing in the scripts is edited: set `VHID` (default 12, the LAN-side
CARP VIP the backup reaches the master through) and, if needed, `MASTER_ONLY_SERVICES`
and `JUMBO_MTU_IFS` in `kc-ha.conf`.

## Boot-time false MASTER (known, partly mitigated)

A node that boots while the peer is healthy can time out to MASTER on its VLAN VIPs for
~30 s before it is able to hear the real master (seen in the field on 26.1: the pf
ruleset is not fully loaded yet; demotion does not prevent a timeout). During that window
both nodes are MASTER and clients that learn the booting node's MAC lose connectivity.

Mitigation in this kit: a MASTER event within `BOOT_GRACE` seconds of boot while the pfsync
peer still answers on the SYNC link is treated as false by `kc-unbound-master` and
`kc-ha-master-services` (no restart, no service start). `kc-ha-egress` still acts (removing
the backup-egress routes on a false master is harmless and they come back on the BACKUP
event). `check.sh` warns on "master timed out" in the log. Prefer rebooting a node while the
*other* one is master and expect a short blip; test it in a window before relying on it.

## Failover test

```sh
sysctl net.inet.carp.demotion=240     # on the master: hand over
# ... probe ping / DNS / a WAN-bound service from the LAN ...
sysctl net.inet.carp.demotion=-240    # relative counter: undo with the negative, not 0
```

## Field notes from a second site (conversion of a live single firewall, 3 static WANs)

- **Device names must match on both nodes** for every WAN: synced states carry
  `route-to <gw>@<device>` (pfsync 1400+). With WAN2 on `vtnet1` on one node and `vtnet2`
  on the other, every established connection stalled for the whole failover while ping/DNS
  to the VIP looked fine. `check.sh` fails on differing device names.
- **Converting a live gateway to a CARP VIP**, per interface on the primary: change the
  interface address `.1` → `.2`, add CARP VIP `.1` (skew 0), `configctl interface
  reconfigure <opt>`, `configctl filter reload`. ~3 s in BACKUP then MASTER; routed traffic
  keeps flowing. Add the secondary's VIP only after the primary is MASTER, or the
  secondary times out to MASTER and duplicates the address.
- **After the first VIP, reload the filter**: `interface reconfigure` alone does not add the
  automatic `pass proto carp` rules; without them the node drops the peer's advertisements
  and both stay MASTER. `check.sh` counts those rules.
- **Reconfiguring an interface or pfsync on the master demotes it** (pfsync bulk start,
  factor 240) until "bulk done": a ~1 s handover and back when both nodes run the same
  version. With mismatched versions the bulk handshake can stall (`syncok: 0`, no "bulk
  done"); the node stays demoted and the peer takes over. Clear with
  `sysctl net.inet.carp.demotion=-240`, or set `net.pfsync.carp_demotion_factor=0` for the
  duration of a conversion. `syncok` alone is not a health signal: compare state counts.
- **Outbound NAT in hybrid/automatic mode** translates to the interface address, which
  becomes the private /29 node address: add a manual rule per WAN to the VIP **before**
  converting the interface. Rules using the `<if>ip` macro change meaning the same way.
- `configctl filter reload` does not trigger config sync; run
  `/usr/local/etc/rc.filter_synchronize` after CLI changes on the primary.
- sshd keeps listening only on the addresses present when it started; restart it after
  the conversion. Keep an out-of-band path (Proxmox guest agent) for `sysctl` on a node
  whose addresses just moved.
- Hot-added Proxmox virtio NICs enumerate in arrival order until a cold boot: verify
  device-to-MAC after a power cycle before relying on names.
- ISC DHCP failover needs tcp 519-520 allowed between the node addresses on each VLAN;
  role follows the VIP skew. Config sync of `dhcpd` and `virtualip` is safe.
- WireGuard: set `carp_depend_on` through the model (VIP UUID); the first sync may deliver
  it empty (VIP UUIDs not yet present), sync twice; run `configctl template reload
  OPNsense/Wireguard` on the secondary or `wg0.conf` stays empty; add a static-port
  outbound NAT rule for the tunnel port.
- Tailscale: with both nodes advertising the same subnets, the control plane may pick the
  backup as the active subnet router.
- **Review of the first shared release against the second site** (3 static WANs, WAN2 on
  `vtnet1`, reference VIP vhid 99, 26.1): `97-kc-jumbo-mtu` named `vtnet1` in the script
  and `install.sh` ran it, which there would have re-initialised the active WAN at MTU
  9000; `carp/20-kc-unbound-master` matched `12@*` literally, so Unbound was never
  restarted on takeover; `check.sh` required pfsync `version=1500` (26.1 speaks 1400).
  All three are config-driven now. The cellular backup gateway there is `192.168.4.1`:
  `kc-ha-egress` and `check.sh` used to call any private default gateway unusable and
  re-pin it on the next CARP event, undoing a WAN failover; a default route through a
  *configured* upstream gateway is now accepted whatever its address.
- Services that must run on one node only (UPnP/miniupnpd, mDNS/SSDP relay, ddclient):
  list them in `MASTER_ONLY_SERVICES` in `kc-ha.conf`. The service must be *enabled* in
  the config of **both** nodes (UPnP settings are not HA-synced; on the KC pair fw-b had
  UPnP disabled, so after a failover nothing served UPnP). `check.sh` compares the UPnP
  section. The KC pair uses `MASTER_ONLY_SERVICES="miniupnpd"`.

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
