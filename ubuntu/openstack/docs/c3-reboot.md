# Rebooting `c3` (the cloud host)

Rehearsed **2026-10-20** on the live system. `c3` runs every VM, so a reboot takes the whole lab down: the finance app (QA deployment), Argo CD, both databases, the CI runner and the QA cluster.
This page is the procedure that worked, what went wrong and how it was repaired, and what to do differently next time.

## Facts that decide how to reboot (all checked on 2026-10-20)
- OpenStack on `c3` is installed from **Debian 13 packages as systemd services** (Nova 31, Neutron 26, Octavia, Designate); there is **no Kolla and no Docker** (podman exists but is unused). All control-plane services are enabled at boot (MariaDB, RabbitMQ, OVS/OVN, Nova, Neutron, Octavia, Designate, Apache), so the cloud comes back by itself.
- **Until 2026-10-20 Nova did not restart VMs after a host boot** (`resume_guests_state_on_host_boot` was unset, so false): after the first reboot test every VM stayed `SHUTOFF` until started by hand. **That is now configured, see "Automatic VM start" below** (the manual start steps are kept as the fallback).
- No Cinder: there are no volumes. VM disks are local files, so nothing needs re-attaching.
- `libvirt-guests` is enabled; this procedure does not depend on it because the guests are shut down through Nova first.
- The host bridge `br0` and the route `10.0.1.0/24 via 192.168.2.174` come from `/etc/network/interfaces`. **Boot-tested: the route was there by itself after the reboot** (`c3-host-route.md`).
- `nmbd` (Samba NetBIOS) used to fail on every boot; fixed the same day (see "Other fixes"), so `systemctl --failed` should now be empty.
- The CI runner is a VM: do not reboot while a GitHub Actions job is running on it.

## Automatic VM start (configured 2026-10-20)
Goal: after `c3` boots, the VMs that were running come back by themselves. Four changes on `c3`; each file was backed up as `<file>.bak-20261020`.
| # | File | Change | Why |
|---|---|---|---|
| 1 | `/etc/nova/nova.conf`, `[DEFAULT]` | `resume_guests_state_on_host_boot = true` | when `nova-compute` starts it restarts every instance that Nova thinks should be running (state `ACTIVE`) but whose guest is off. Instances an operator stopped through Nova (`SHUTOFF`) are left alone |
| 2 | `/etc/default/libvirt-guests` | `ON_BOOT=ignore`, `ON_SHUTDOWN=shutdown`, `SHUTDOWN_TIMEOUT=300`, `PARALLEL_SHUTDOWN=20` | at host shutdown the guests get a clean ACPI shutdown, all in parallel (the default saves their memory to disk one by one); at boot libvirt starts nothing and leaves it to Nova, so the two never fight |
| 3 | `/etc/systemd/system/nova-compute.service.d/10-order-after-libvirt-guests.conf` | `After=libvirt-guests.service` | systemd stops units in the reverse of start order, so `nova-compute` now stops **before** `libvirt-guests` shuts the guests down. Otherwise Nova could see a shut-down guest, record it as `SHUTOFF`, and never restart it |
| 4 | `/etc/octavia/octavia.conf`, `[health_manager]` | `failover_threshold = 2` | after a reboot every amphora looks dead for a moment, and the health manager used to rebuild them (what broke the load balancers in the first test). With this setting, if 2 or more amphorae are stale at the same time they are marked `FAILOVER_STOPPED` and **no failover happens**; they go back to normal when heartbeats resume. A single dead amphora is still replaced automatically |
| 5 | same section | `heartbeat_timeout = 900` | **the setting that finally made reboots safe**: an amphora must be silent for 15 minutes (longer than a host reboot) before Octavia considers it dead. The threshold alone is not enough: if one amphora wakes a little after the others only one is stale and it would still be rebuilt |
| 6 | Glance image tagged `Amphora` | the patched image `Amphora-netns-fix-v2-20261020` | fixes the amphora's VIP network after a clean stop/start (`amphora-reboot-fix.md`) |
| 7 | `ovn-vip-binding.timer` on `c3` | a 30-second watcher | makes OVN's router follow the amphora that really answers the VIP (`amphora-reboot-fix.md`) |

Apply (what was done), on `c3` as root:
```bash
cp -p /etc/nova/nova.conf /etc/nova/nova.conf.bak-$(date +%Y%m%d)       # same for the other three files
sed -i '0,/^\[DEFAULT\]/s//[DEFAULT]\nresume_guests_state_on_host_boot = true/' /etc/nova/nova.conf
printf 'ON_BOOT=ignore\nON_SHUTDOWN=shutdown\nSHUTDOWN_TIMEOUT=300\nPARALLEL_SHUTDOWN=20\n' >> /etc/default/libvirt-guests
mkdir -p /etc/systemd/system/nova-compute.service.d
printf '[Unit]\nAfter=libvirt-guests.service\n' > /etc/systemd/system/nova-compute.service.d/10-order-after-libvirt-guests.conf
systemctl daemon-reload
sed -i '0,/^\[health_manager\]/s//[health_manager]\nfailover_threshold = 2/' /etc/octavia/octavia.conf
systemctl restart nova-compute octavia-worker octavia-health-manager    # restart BOTH octavia services after any octavia.conf change
```
Check it is in effect:
```bash
grep -h resume_guests /etc/nova/nova.conf; grep -h failover_threshold /etc/octavia/octavia.conf
systemctl show nova-compute -p After | tr ' ' '\n' | grep libvirt-guests
```
Undo: restore the `.bak-20261020` files, delete the drop-in, `systemctl daemon-reload`, restart the three services.

**Proven:** (a) on the spare VM `learn` without rebooting the host: `nova-compute` stopped, the guest shut down behind Nova's back, `nova-compute` started: the guest was running again after **24 s**; a VM stopped on purpose through Nova stayed `SHUTOFF`; (b) **two plain reboots of `c3` with everything running**: 17 of 17 VMs back by themselves in about 2 minutes (details below and in `amphora-reboot-fix.md`).

Limits to know:
- All VMs start at once, with no database-first ordering. The apps and Postgres replication retry and caught up in the first test, but check after a reboot.
- A really dead amphora is replaced automatically only after **15 minutes** (`heartbeat_timeout`), and if **two** die at the same time Octavia will not repair them by itself: look at `openstack loadbalancer amphora list` and run `openstack loadbalancer failover <lb>` by hand (retry on a 409; see `amphora-reboot-fix.md` for the flaky two-amphora rebuild).

## Other fixes made on `c3` the same day
- **`nmbd` failed on every boot.** `/etc/samba/smb.conf` had `interfaces = 127.0.0.0/8 enp3s0`, but `enp3s0` has no IP address (it is a port inside the bridge `br0`, which carries `192.168.2.2`), so nmbd logged "No local IPv4 non-loopback interfaces available, waiting for interface", never reported ready, and systemd timed it out.
  Fixed with `interfaces = 127.0.0.0/8 br0` (backup `smb.conf.bak-20261020`); `systemctl --failed` is now empty. Proof at boot comes with the next reboot.
- **`nslookup w1.prod` said NXDOMAIN on `c3`** while `ssh w1.prod` worked. The DNS server was right: BIND's tools (`nslookup`, `host`) treat a name with one dot as complete and skip the search list, while `ssh` (glibc) falls back to it.
  Fixed with `options ndots:2` in `/etc/resolv.conf` (after the search line `rdulinux.com prod.rdulinux.com qa.rdulinux.com`), so `w1.prod`, `c1.qa`, `w2` and `finance` resolve in every tool.
  What it means: a name with fewer than 2 dots is tried with the search suffixes first; names with 2 or more dots (`repo.rdulinux.com`) are tried as typed. Side effect: a one-dot external name such as `github.com` first tries the three suffixes (a few milliseconds, then resolves normally).
  Backup `resolv.conf.bak-20261020`. `/etc/resolv.conf` is a plain file here (no resolvconf, no systemd-resolved), so the edit persists.

## Reboot test results (2026-10-20): where it ended
Four reboot tests of `c3` were done in one day. The last two were **plain `reboot`s with all 17 VMs running and no manual step**, and passed:
| | Test 1 (VMs shut down by hand first) | Test 2 (plain reboot, autostart on) | Test 3 and 4 (plain reboot, all fixes) |
|---|---|---|---|
| `c3` back (ssh) | 150 s | 570 s (clean guest shutdown now happens first) | 309 s and **172 s** |
| VMs running | started by hand | 17 of 17 by themselves in about 2 min | 17 of 17 by themselves in about 2 min |
| Both front doors | down until repaired by hand (about 45 min) | **down and did not recover** | **200 about 3 minutes after `c3` answered, nothing touched** |
| Octavia | rebuilt amphorae, some failed | mass rebuild prevented by the threshold, but the amphorae had lost their VIP network | **0 failovers, same amphora IDs, all `ALLOCATED`, load balancers `ACTIVE`/`ONLINE`** |
| `nmbd`, route, short names on `c3` | `nmbd` failing | fixed | `nmbd` active, 0 failed units, route present, `w1.prod` resolves |
The cause of tests 1 and 2 failing was **not** the host or Nova but the amphora image (it loses its VIP network after a clean shutdown), an OVN router that keeps a stale MAC for a rebuilt amphora, and the health manager rebuilding amphorae that were merely not yet awake. All three are fixed: see **`amphora-reboot-fix.md`** for the root cause, the fixes (patched image, `heartbeat_timeout`, the `ovn-vip-binding` watcher), the proof and how to re-create the patch.
The databases, both clusters, Argo, the runner and the monitor came back by themselves every time (replication resumed at 0 lag).

## Procedure (manual: the fallback, and the checks that still apply)
With automatic start configured (above) the manual shutdown and start steps can be skipped, but not the checks before and after. Allow about an hour including checks (the test took longer, because of the Octavia repairs below). The finance app is down from the first shutdown until the pods and a load balancer are back, and Argo CD may be down longer (see "What went wrong").

### Before
1. **No CI running:** `gh run list --repo vellingiri/finance --limit 3` (wait until `completed`; the deploy step runs on the runner).
2. **Free memory.** You need roughly 4 GB of allocatable memory free for Octavia to rebuild amphorae (see below): `ssh c3 'openstack hypervisor stats show -c memory_mb_used'` against about 88156 allocatable.
3. **Fresh backups:** a DB dump (`k create job --from=cronjob/db-backup-daily pre-reboot-<hhmm>`, where `k` is the function in `operations-cheatsheet.md`, then delete the job), an etcd snapshot
   (`ssh c1.prod 'sudo systemctl start etcd-snapshot.service'`), and `scripts/db-replication-status.sh db1 db2` showing `streaming, behind: 0 bytes`.
4. **Baseline:** save `openstack server list --all-projects --long` (IDs, names, networks; names repeat across prod and qa, so use the IDs) and the load balancer and node states.

### Shut down (graceful, in dependency order)
5. **Stop Octavia's health manager so it cannot "repair" amphorae that it will think died:** `ssh c3 'systemctl disable --now octavia-health-manager'`.
6. Stop the VMs through Nova, waiting for `SHUTOFF` after each group (`openstack server stop <ids>`; Nova gives each guest an ACPI shutdown, then forces it after about 60 s):
   1. the runner and the five prod workers;
   2. the prod controller `c1`, the whole QA cluster (`c1`, `w1` to `w3`) and `learn`;
   3. the replica `db2`, then the primary `db1` (so Postgres stops cleanly);
   4. the three load balancer amphorae (they are visible only with `--all-projects`).
7. Check `openstack server list --all-projects` shows only `SHUTOFF` and `pgrep -c qemu-system` is `0`.

### Reboot
8. `ssh c3 systemctl reboot`. `c3` answered ssh again after **150 seconds**.
9. Check: `ip route | grep 10.0.1` (the route), `openstack compute service list` (`nova-compute` and `nova-conductor` show `down` for about a minute after boot, then `up`; the Nova and Neutron APIs return 500s for a minute too),
   `openstack router show main_router -c status`, `systemctl --failed` (only `nmbd`).

### Start (also in order)
10. `db1`, the prod controller `c1` and the three amphorae first (they take about 30 s; `db1` answers ssh and Postgres immediately).
11. Then `db2`, the five prod workers and the runner. The prod nodes were `Ready` within about 2 minutes; the pods show `Unknown` for a short while, then 12 of 12 are `Running`. Replication resumed by itself (`streaming, behind: 0 bytes`).
12. Then the QA cluster and `learn` (nothing depends on them).
13. **Re-enable the health manager, only once the amphorae are up: `systemctl enable --now octavia-health-manager`. Do not forget the `enable`: step 5 disabled it, and without it nothing repairs a failed load balancer.** Read the next section before doing this.

### Verify (the sweep used)
`finance.rdulinux.com/health` and `argo.rdulinux.com` return 200; DNS names resolve; 6 of 6 prod and 4 of 4 QA nodes `Ready`; each app has three pods on three different nodes; Argo `Synced Healthy`; the app's own database check
(`select inet_server_addr(), pg_is_in_recovery()` as the app user) returns `10.0.1.191 | f`; replication streaming; runner and `db-monitor.timer` active; both pools 5 of 5 `ONLINE`; load balancers `ACTIVE`/`ONLINE`.

## History: what went wrong in test 1, and the manual repair (superseded, kept as the fallback)
This is how the first test went and how it was repaired by hand. The root causes were found later and are fixed: `amphora-reboot-fix.md`.
**Octavia rebuilt amphorae when its health manager started (step 13), and some of the rebuilds failed.**
- The health manager judges an amphora dead when its last heartbeat is older than 60 s. The heartbeats are received by the health manager itself, so while it was off the stored timestamps went stale. When it started (11:15) it saw every amphora as dead
  before the first new heartbeat could arrive, and started failovers.
- The first rebuild (the MASTER of `finance-lb`) worked, and the finance front door answered 200 again once that new amphora was up. The next ones failed: one with `No valid host` (probably memory: the replaced amphora VM was still running, so the host was briefly short; not proven),
  one with `ComputeWaitTimeoutException` (cause not found). That left `finance-lb` in `ERROR` with both amphorae `ERROR` (still serving, but with no redundancy) and `argo-lb`'s only amphora not reporting, so **Argo was down until it was rebuilt**.
- Repair, which worked: `openstack loadbalancer failover argo-lb`, then `openstack loadbalancer failover finance-lb`. A `409 immutable` means the health manager is busy with it: retry every 15 s. Each took about 100 seconds and ended `ACTIVE`/`ONLINE` with fresh amphorae
  (two for `finance-lb`, one for `argo-lb`). A targeted `openstack loadbalancer amphora failover <id>` was refused (409) on an `ERROR` load balancer; fail over the load balancer instead.
  Octavia deleted the replaced amphora VMs itself; check `openstack server list --all-projects | grep amphora` shows exactly three, and `openstack loadbalancer amphora list` shows `ALLOCATED` for all.
- **Capacity matters:** an amphora is a 2 GB VM and a rebuild creates the new one before deleting the old. With little memory free two simultaneous rebuilds can fail with `No valid host`.

### Ideas listed after test 1: what became of them
- Raise the health manager's tolerance: **done**, as `heartbeat_timeout = 900` (plus `failover_threshold = 2`); this is what finally made reboots safe.
- `resume_guests_state_on_host_boot = true`: **done** (see "Automatic VM start").
- Free at least 4 GB of memory before rebuilding load balancers: still a good idea (see `amphora-reboot-fix.md`, limits).

## Measured in test 1 (VMs shut down by hand first)
| | |
|---|---|
| Graceful stop of all 17 VMs | not timed (a few minutes; every VM reached `SHUTOFF` before the reboot) |
| `c3` reboot until ssh | 150 s |
| OpenStack APIs usable and `nova-compute` up | roughly 4 to 5 minutes after the reboot command |
| Prod nodes `Ready` after starting the workers | about 2 minutes |
| Finance front door back (rebuilt MASTER) | not timestamped; roughly 10 to 20 minutes after the reboot command |
| `finance-lb` fully `ACTIVE` with two healthy amphorae | roughly 45 minutes after the reboot command (two failed rebuild attempts, then one clean failover of 102 s) |
| Data | nothing lost: databases were shut down cleanly after a fresh backup; replication caught up at once; the app's database check passed |
| Persistent route | present after boot without help |
| Terraform | untouched; nothing needed to be re-applied |

## Related
`amphora-reboot-fix.md` (why load balancers broke after a reboot and the fix), `ARCHITECTURE.md` (what runs where), `octavia-finance-lb.md` (load balancer pitfalls), `c3-host-route.md`, `db-replication.md`, `k8s-operations.md`.
