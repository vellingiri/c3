# Pending and open items

What is deliberately not done yet, who decides, and what finishes it. Update this page whenever something is added, decided or finished
(and say so in `../CHANGELOG.md`). Last updated 2026-10-20.

## Waiting for a decision or a moment
| Item | Why it is open | What finishes it |
|---|---|---|
| **Install the nightly `c3` capture** | the disaster-recovery bundle (`c3-rebuild.md`) is only as fresh as the last capture; installing the timer adds a service on `c3`, so it waits for your OK (2026-10-22: decided NOT to touch the real c3 for now) | `scripts/install-c3-dr-capture.sh`, then check `ssh s3 ls -l /backup/c3-dr/bundles/latest` |
| **Bigger root disks: cka and the witness** | cka VMs (4, stopped) and `dbw1-prod` are still 10 GB: c3's Placement disk capacity is 340 GB (136 x 2.5), about 300 used after the prod resizes | only if space is freed (retire something) or `disk_allocation_ratio` is raised, which is a risk on a 71 %-full host disk (39 GB free); then flavors `m1.small-20g` (cka) / `m1.tiny` + 20 GB (witness) |
| **Grow the cka VMs and the witness to 20 GB; disk ratio** | c3 now has Placement room (540 GB x 2.5); `/` is 21 % used after `nova.old` was deleted 2026-10-22 | flavors `m1.small-20g` (cka x4, when started) and a 20 GB tiny flavor for `dbw1-prod`; consider `disk_allocation_ratio` 1.0; one clean `systemctl reboot` of c3 to prove the new `/var/lib/nova` mount (`docs/c3-disk-expansion.md`) |
| **c3 hardware: suspected bad CPU core (core 4, CPU 8/9) or RAM** | 2026-10-22: oopses and segfaults on CPU 8 after a reboot; BIOS A.C0 flashed, all cores online again since the evening, 0 events for 14+ min; the unit `c3-offline-cpus.service` is disabled but ready | memtest86+ 2 passes; BIOS update + Intel default settings; Intel RMA if confirmed; check `journalctl -k -b | grep -E "Oops|segfault|BUG:"` daily for a week; on the first hit `systemctl enable --now c3-offline-cpus` and file the Intel RMA (`docs/c3-hardware-instability.md`) |
| **VMs stay SHUTOFF after a clean reboot of c3** | Nova treats the clean guest shutdown as stopped | after a reboot run `c3-vms-start.sh`; or add a boot-time unit that runs it (not installed) |
| **Rehearse the `c3` installer** | `scripts/c3-dr/c3-dr-install.sh` has never run on a blank machine (the capture side and the helpers are verified read-only) | run it on a spare machine or a large VM from a bundle copy, fix what the first run finds, record the result in `c3-rebuild.md` |

## Accepted limits (no action planned)
- The host `c3` is close to its real memory: 67 of 80 GB in use on 2026-10-20 with 118 GB allocated (ratio 1.7). Check `free -m` ("available") before adding VMs; the allocation ratio is not a safety margin (`amphora-reboot-fix.md`).
- Database replication is synchronous but not strict: a standby outage means about 35 s of paused writes, then asynchronous until it returns (`db-ha-patroni.md`).
- Losing two of the three etcd machines (`dbw1` plus a database, or both databases) stops automatic database failover until one is back; emergency steps in `db-ha-patroni.md`. Everything runs on one host (`c3`), so a host loss still takes everything. (Five voters would survive two; they were given up for memory on 2026-10-22.)
- A really dead amphora is replaced automatically after 5 minutes (`heartbeat_timeout = 300`) or at once with `openstack loadbalancer failover <lb>`; both load balancers have a standby (`amphora-reboot-fix.md`).
- Three control-plane nodes tolerate one failure (prod; `qa` and `cka` have one each), and everything runs on one host (`k8s-ha-control-plane.md`).

## Done recently (so nobody redoes it)
Cinder removed from the catalog (2026-10-20; backups in `/root/backups/cinder-removal-20261020` on `c3` and `/root/backups/c3-cinder-removal-20261020.tgz` on `s3` (the host formerly called `backup`), restore steps inside);
`ram_allocation_ratio` 1.2; `w4`/`w5` retired; `learn` removed; database HA built by Terraform; reboot tests 1 to 8: automatic VM start and a plain `systemctl reboot` that completes by itself in under 2 minutes (`c3-reboot.md`); the slow worker power-off (kubelet graceful shutdown) and the OVN stop order are fixed.
