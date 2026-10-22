# The OpenWrt router (192.168.2.1)

ASUS RT-AX53U, OpenWrt 25.12.5. It is the lab's gateway: LAN `192.168.2.0/24` (`br-lan`, ports lan1 to lan3), WAN `192.168.1.5` on the Airtel network (gateway `192.168.1.10`), masquerade LAN to WAN. Checked read-only and adjusted on 2026-10-22.

## What is configured (and why)
| Item | Setting |
|---|---|
| DNS | dnsmasq forwards `*.rdulinux.com` to c3's BIND (`192.168.2.2`); `rebind_domain 'rdulinux.com'` lets those answers (private addresses) through the DNS-rebind filter (before 2026-10-22 the router refused them: "possible DNS-rebind attack"). DHCP tells clients to use `192.168.2.2` directly, with search domain `rdulinux.com` |
| DHCP | pool **`192.168.2.25` to `.59`** (start 25, limit 35), 12 h leases. Before 2026-10-22 it was `.25` to `.123`, which contained lab addresses (prod API `.61`, cka API `.75`, argo `.113`, the OpenStack floating IPs from `.101`): the router even held a lease on `.75` for the s3 host's MAC and had it in its ARP table. **Lab addresses (static, outside the pool): c3 `.2`, s3 `.4`, finance `.5`, prod-api `.61`, cka-api `.75`, argo `.113`, OpenStack floating IPs `.100` and up** |
| Firewall | lan: accept; wan: input reject, forward drop, masquerade. **wan to lan forwarding is on, deliberately**: the lab (`192.168.2.x`) must be reachable from the upstream `192.168.1.x` network too. LuCI (80/443) and mDNS are allowed from wan |
| Time | `Asia/Kolkata` (`IST-5:30`), NTP `*.openwrt.pool.ntp.org` |
| Known noise | `odhcpd: no public prefix on lan ... ra_lifetime 0` every few minutes: IPv6 router advertisement without a public prefix, harmless here |
| Accepted | DHCP gives only `192.168.2.2` as DNS: with c3 down, LAN clients lose DNS. Single host, accepted |

## Backup and restore
- **Backup:** `scripts/openwrt-backup.sh [label]` (from the Mac). Builds `sysupgrade -b` on the router (read-only), copies it to **`s3:/backup/openwrt/openwrt-<date>[-label].tar.gz`** plus a readable `uci export` (`.uci.txt`), checks the checksum after the copy, points `latest.*` at it, keeps the newest 30 (files are mode 600: the archive holds the Wi-Fi keys and the ssh keys). Run it after every router change. First copies: `20261022-115514-before-changes`, `20261022-115606-after-changes`.
- **Daily, automatic:** `openwrt-backup.timer` on **s3** (installed by `scripts/install-s3-openwrt-backup.sh`, script `scripts/s3-openwrt-backup.sh` = `/usr/local/sbin/openwrt-backup`) runs at 03:15 (+ up to 5 min, `Persistent` so a missed run happens at boot). It pulls from the router with its own key (`/root/.ssh/openwrt_backup` on s3, listed in the router's `/etc/dropbear/authorized_keys`) and stores `openwrt-<date>-daily.*` only when a saved file changed (content fingerprint). `/backup/openwrt/last-ok` is touched on every good run: **older than 2 days = the job is broken** (`journalctl -u openwrt-backup`). Nothing runs on c3 or the Mac. Same 30-copy retention.
- **Restore:** `scripts/openwrt-restore.sh [archive on s3 | local file] [--yes]`. Shows what is inside, asks, takes a safety backup of the current state (`before-restore`), copies the archive to the router, `sysupgrade -r`, reboots, waits and prints the DHCP pool and LAN address to confirm. About one minute without the LAN gateway. Default archive: `latest.tar.gz`.
- **Replaced or factory-reset router:** flash OpenWrt, give it `192.168.2.1/24` on the LAN and ssh access (LuCI, or failsafe mode), put your ssh key on it, then `scripts/openwrt-restore.sh`. If `s3` is not reachable, use a local copy: `scp`/`ssh s3 cat` the archive to the Mac and pass its path.
- **Verified 2026-10-22:** backup and checksum work; the stored archive's `/etc/config/*` equal the live files (12 of 12). The restore script itself has **not been run** (it reboots the gateway); rehearse it on a quiet moment with `scripts/openwrt-restore.sh latest.tar.gz`.
- Router backups also appear in c3's `root.tgz` (`openwrt-*.tar.gz`, `c3-rebuild.md`); the s3 copies are independent of c3.
