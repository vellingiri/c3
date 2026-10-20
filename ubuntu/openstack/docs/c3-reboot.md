# Rebooting `c3` (the cloud host)

Rehearsed **2026-10-20** on the live system. `c3` runs every VM, so a reboot takes the whole lab down: the finance app (QA deployment), Argo CD, both databases, the CI runner and the QA cluster.
This page is the procedure that worked, what went wrong and how it was repaired, and what to do differently next time.

## Facts that decide how to reboot (all checked on 2026-10-20)
- OpenStack on `c3` is installed from **Debian 13 packages as systemd services** (Nova 31, Neutron 26, Octavia, Designate); there is **no Kolla and no Docker** (podman exists but is unused). All control-plane services are enabled at boot (MariaDB, RabbitMQ, OVS/OVN, Nova, Neutron, Octavia, Designate, Apache), so the cloud comes back by itself.
- **Nova does not restart VMs after a host boot** (`resume_guests_state_on_host_boot` is not set, so it is false). After the reboot every VM is `SHUTOFF` until you start it.
- No Cinder: there are no volumes. VM disks are local files, so nothing needs re-attaching.
- `libvirt-guests` is enabled; this procedure does not depend on it because the guests are shut down through Nova first.
- The host bridge `br0` and the route `10.0.1.0/24 via 192.168.2.174` come from `/etc/network/interfaces`. **Boot-tested: the route was there by itself after the reboot** (`c3-host-route.md`).
- `nmbd` (Samba NetBIOS) fails to start on **every** boot, including before this test. It is unrelated; ignore it (`systemctl --failed` will list it).
- The CI runner is a VM: do not reboot while a GitHub Actions job is running on it.

## Procedure
Allow about an hour including checks (the test took longer, because of the Octavia repairs below). The finance app is down from the first shutdown until the pods and a load balancer are back, and Argo CD may be down longer (see "What went wrong").

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

## What went wrong, and the repair
**Octavia rebuilt amphorae when its health manager started (step 13), and some of the rebuilds failed.**
- The health manager judges an amphora dead when its last heartbeat is older than 60 s. The heartbeats are received by the health manager itself, so while it was off the stored timestamps went stale. When it started (11:15) it saw every amphora as dead
  before the first new heartbeat could arrive, and started failovers.
- The first rebuild (the MASTER of `finance-lb`) worked, and the finance front door answered 200 again once that new amphora was up. The next ones failed: one with `No valid host` (probably memory: the replaced amphora VM was still running, so the host was briefly short; not proven),
  one with `ComputeWaitTimeoutException` (cause not found). That left `finance-lb` in `ERROR` with both amphorae `ERROR` (still serving, but with no redundancy) and `argo-lb`'s only amphora not reporting, so **Argo was down until it was rebuilt**.
- Repair, which worked: `openstack loadbalancer failover argo-lb`, then `openstack loadbalancer failover finance-lb`. A `409 immutable` means the health manager is busy with it: retry every 15 s. Each took about 100 seconds and ended `ACTIVE`/`ONLINE` with fresh amphorae
  (two for `finance-lb`, one for `argo-lb`). A targeted `openstack loadbalancer amphora failover <id>` was refused (409) on an `ERROR` load balancer; fail over the load balancer instead.
  Octavia deleted the replaced amphora VMs itself; check `openstack server list --all-projects | grep amphora` shows exactly three, and `openstack loadbalancer amphora list` shows `ALLOCATED` for all.
- **Capacity matters:** an amphora is a 2 GB VM and a rebuild creates the new one before deleting the old. With little memory free two simultaneous rebuilds can fail with `No valid host`.

### Ideas to avoid it next time (not tried yet)
- Before step 13 temporarily raise `[health_manager] heartbeat_timeout` (for example to 300) in `/etc/octavia/octavia.conf`, start the health manager, wait a couple of minutes for heartbeats to refresh the timestamps, then put the value back and restart it
  (remember: after any `octavia.conf` change restart **both** `octavia-worker` and `octavia-health-manager`).
- Set `resume_guests_state_on_host_boot = true` in `/etc/nova/nova.conf` so Nova starts the VMs that were running; the ordering above (databases and control planes first) would then no longer be under your control, so test it before relying on it.
- Free at least 4 GB of memory first (retire an unused VM) so Octavia's rebuilds cannot hit `No valid host`.

## Measured in the test
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
`ARCHITECTURE.md` (what runs where), `octavia-finance-lb.md` (load balancer pitfalls), `c3-host-route.md`, `db-replication.md`, `k8s-operations.md`.
