# Changelog

Versions are git tags (`vX.Y.Z`); `install.sh` stamps the node with `git describe`.

## [0.0.1] - 2026-10-28

### Fixed
- `kc-ha-lib`: the CARP role lookup matched the reference vhid as a prefix, so
  with `VHID=1` a VIP with vhid 10-19 on the same device listed first was read
  as the role (for example BACKUP while vhid 1 was MASTER). It now matches the
  exact vhid. The KC pair has one VIP per device, so it was not affected.
  Re-run `install.sh` on both nodes to pick it up (`check.sh` reports
  `kc-ha-lib differs from repo` until then).
