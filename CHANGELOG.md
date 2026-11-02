# Changelog

Versions are git tags (`vX.Y.Z`); `install.sh` stamps the node with `git describe`.

## [0.0.2] - 2026-11-02

### Added
- `kc-ha-tailscale-primary` (carp hook `60-kc-ha-tailscale`, cron every 2 min):
  with both nodes advertising the same Tailscale subnets, Tailscale keeps the
  routes on whichever node had them first, so after a failover or failback the
  BACKUP could stay the active subnet router and Tailscale dropped what the
  MASTER forwarded. On the BACKUP, when it holds the routes and the other node
  is online in the tailnet, tailscaled is stopped for `TAILSCALE_HANDOVER_HOLD`
  seconds so the routes move to the MASTER. Off unless `TAILSCALE_NODES` is set
  in `kc-ha.conf`.
- README: how to send LAN traffic to a single tailnet host through a 1:1 NAT
  (assign `tailscale0`, allow it, outbound NAT to the host on it).

## [0.0.1] - 2026-10-28

### Fixed
- `kc-ha-lib`: the CARP role lookup matched the reference vhid as a prefix, so
  with `VHID=1` a VIP with vhid 10-19 on the same device listed first was read
  as the role (for example BACKUP while vhid 1 was MASTER). It now matches the
  exact vhid. The KC pair has one VIP per device, so it was not affected.
  Re-run `install.sh` on both nodes to pick it up (`check.sh` reports
  `kc-ha-lib differs from repo` until then).
