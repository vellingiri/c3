# Changelog (infrastructure release notes)

What changed in the lab infrastructure, newest first. One entry per day that mattered, with **breaking changes** called out because they are
what bites later. The matching app-side changes are in the finance repo (`docs/RELEASE_NOTES.md`, [PR 309](https://github.com/vellingiri/finance/pull/309)). Design background: `docs/`.
Update this file in the same commit as any change, and list anything done **by hand** (not in Terraform) under "Not in Terraform".

---

## 2026-10-20 (later): automatic database failover (Patroni)

### Breaking changes
| Gone / changed | Now |
|---|---|
| Manual database failover (`pg_promote`, `db-replica-setup.sh` by hand) | **do not use on db1/db2**; Patroni owns PostgreSQL. Use `patronictl switchover` / `failover` / `reinit` (`docs/db-ha-patroni.md`). `postgresql@16-main` is masked on both |
| `DATABASE_URL` with one host | two hosts, `target_session_attrs=read-write`; the app finds the writable one |
| `db.rdulinux.com` followed the primary | still points at the original primary, **not updated on failover**; nothing uses it |
| 17 VMs | **18**: new `db-witness` (m1.tiny, 10.0.1.120 / 192.168.2.104). Memory headroom on `c3` is now ~1.1 GB |

### What was built
- Patroni 3.2.2 on `db1`/`db2` (adopted the existing data, about 2 s of failed writes), etcd 3.4 with three members (`db1`, `db2`, `db-witness`), nftables guard for etcd/Patroni ports, ntfy message on every role change.
- App (finance repo, `sha-aa0101f`): per-host connect timeout and `FailoverPool`, query timeout, scheduler leader watchdog, `pg_dump` connect timeout.
- Monitor (`db-replication-monitor`) also checks Patroni on each node, the cluster view and the witness.
- **Drills, all passed on live prod:** planned switchover 14-16 s; process kill ~5 s; primary VM power-off ~40 s (app self-recovered, no data loss); network partition (no split brain, ~12 s failed writes); witness loss (no effect). The first VM-crash drill found the asyncpg shared-timeout problem, fixed and repeated.

### Everything on the database VMs now comes from Terraform (cloud-init); a replaced node needs nothing by hand
- New `cloud-init/db-ha.yaml.tftpl` + `files/db-ha-node.sh`: etcd (joins a running cluster or forms one), nftables guard, Patroni config incl. `pg_hba`, patronictl config, ntfy callback. `ip:` is now required in `nodes.yaml` for database/witness nodes (same addresses as today). Passwords are Terraform variables from the git-ignored `environments/prod/secrets.auto.tfvars` (`scripts/db-ha-secrets.sh`). Existing VMs untouched (plan: no changes).
- **Found while testing a `db-witness` replace and fixed on `c3` (by hand, in OpenStack, not Terraform):** Nova could not release a Terraform-owned port when deleting a server, because Neutron refused the update for the user `neutron`. Granted it the `service` role (`openstack role add --user neutron --project service service`) and restarted `nova-compute`. Details and proof: `docs/port-unbind-fix.md`.
- **Proven:** `db-witness` and then `db2` were each replaced with one `terraform apply -replace` and joined/streamed by themselves in about 2 minutes (details in `docs/db-ha-patroni.md`).
- **Proven on the primary too:** switchover to `db2` (`patronictl switchover`), then `db1` was replaced; it needed one plain `terraform apply` because its old Nova-made port had been deleted with the VM (`docs/port-unbind-fix.md`), then rebuilt itself and streams from `db2`. **`db2` is now the primary and `db1` the replica**; roles can stay that way (names do not matter, the app finds the writable host).
- **OpenStack actions taken during this work (all reverted):** QA VMs `learn`, `w2` and `w3` were stopped for a scratch rehearsal and started again; the three scratch VMs `dbt1`, `dbt2`, `dbt-witness` (and their ports) failed with NoValidHost (stopped VMs keep their memory reserved) and were deleted; a test VM `porttest` and its port were created and deleted to prove the port fix; the stale port of the replaced witness had its `device_id` cleared by hand once; the VMs `db-witness` and `db2` were replaced through Terraform (new VMs, same addresses, same names).

### Capacity and cleanup done the same day (OpenStack, by hand)
- `ram_allocation_ratio` 1.1 -> 1.2 on `c3` (nova.conf + nova-compute restart); see `docs/port-unbind-fix.md`.
- `w4` and `w5` retired: VMs removed through Terraform, then their load balancer pool members and Kubernetes nodes deleted. **Prod now has 3 workers, no spare node**: draining one blocks until it is back (`docs/k8s-operations.md`). VM count 16.
- The whole database group was rebuilt from nothing on three scratch VMs (deleted afterwards); it found and fixed a startup race in `db-ha-node.sh`.

### CKA practice cluster (built and verified)
- New `environments/cka` (1 controller + 3 workers, m1.small, `cka.rdulinux.com`) and the zone `cka.rdulinux.com.` in `infra/infra.yaml`. Build, use and teardown: `docs/cka-cluster.md`. Apply `infra` first (DNS zone), then `environments/cka`.

### Host reboot test 5: all VMs stopped, force reboot, manual start (`docs/c3-reboot.md`)
- `c3` back in 31 s after `systemctl reboot --force --force`; everything recovered (front doors 200, 12/12 pods, Patroni 1 Leader + 1 Replica, etcd 3/3, same amphorae). Found: VMs started right after boot can stick in `powering-on` (new `scripts/c3-restart-stuck-vms.py`; wait a minute after `nova-compute` is up); `openstack server reboot --hard` fails because Cinder is disabled (use stop/start); the `runner` guest hit a kernel oops once (cause unknown, did not recur).
- Capacity/Cinder note: Cinder has been disabled since August 2026; nothing here uses volumes.

### Host reboot test 6: automatic VM start after a hard reset with every VM running, passed; why a plain reboot hangs
- All 19 VMs started by themselves after the reset, both front doors 200 about 4 minutes after `c3` answered ssh, no load balancer failovers, no stuck VM (`docs/c3-reboot.md` Test 6; an earlier wording that called it a clean plain reboot was wrong, the shutdown had hung and the host was reset by hand).
- **Why `systemctl reboot` hangs:** `ovn-controller` and the other network services stopped before `libvirt-guests` shut the guests down, so the prod workers (`w1` to `w3`) lost their network and sat for the full 300 s shutdown timeout. Added the drop-in `/etc/systemd/system/libvirt-guests.service.d/20-order-after-ovn.conf` on `c3` (by hand, untested). **Standing rule: restart `c3` with a force reboot** until a plain reboot has been seen to complete.

### Frontend handles SIGTERM (finance repo)
- `app/frontend/server.js` now exits cleanly on SIGTERM/SIGINT (it is PID 1 in its container and ignored them); test added. Effect: frontend pods stop in about a second instead of the full grace period. Deployed with the next frontend image build.

### Host reboot test 8: plain reboot with both fixes, passed
- `systemctl reboot` at 19:32:40: all 19 guests shut down within 32 s, host down after 75 s, back (ssh) 109 s after the command, all VMs auto-started, front doors 200 about 4.5 minutes after the command; no failovers, no stuck VM (`docs/c3-reboot.md` Test 8). The force reboot is now only the fallback.

### Why prod workers took 4.5 minutes to power off: fixed (kubelet graceful shutdown)
- Cause: kubelet's `shutdownGracePeriod` was 0, so at power-off the network and the pods' NFS mounts went away while a `node` container was still running; it hung and systemd waited 3 x 90 s. Reproduced (271 s) and fixed: `shutdownGracePeriod: 30s`, `shutdownGracePeriodCriticalPods: 10s` on every node (by hand) and in the k8s cloud-init templates; the same worker now powers off in 33 s. Details and evidence: `docs/c3-reboot.md`.
- The host route `10.0.1.0/24 via 192.168.2.174` on `c3` is persistent and documented (`docs/c3-host-route.md`; `up`/`down` lines in `/etc/network/interfaces`), present after every reboot test.

### Host reboot test 7: plain reboot with the ordering fix; the reboot is slow, not stuck
- Plain `systemctl reboot` completed by itself: `c3` back 327 s after the command, all VMs auto-started, everything healthy (`docs/c3-reboot.md` Test 7). The shutdown waits about 4.5 min for the prod workers `w1` to `w3` (cause still open; `docs/pending.md`); the hand reset in test 6 came just before they finished. OVN now stops after the guests (drop-in works). Prod workers' journals made persistent (by hand) and added to `cloud-init/base.yaml.tftpl` for new VMs.

### Cinder removed from the catalog
- Cinder (block storage) had been disabled since 2026-08-17 and nothing used volumes (0 volumes, snapshots, backups, 0 volume attachments in Nova). Its catalog service `cinderv3` and its 3 endpoints were deleted; the packages and the `cinder` database stay installed but unused. **Backups** (before deleting): `/root/backups/cinder-removal-20261020/` on `c3` (database dump, `/etc/cinder`, service and endpoint JSON, `RESTORE.txt`, checksums) and a copy on the `backup` host at `/root/backups/c3-cinder-removal-20261020.tgz`. Effect: `openstack server reboot --hard` works again (tested on a CKA worker).
- New `docs/pending.md`: the list of open items and accepted limits.

### `db-witness` renamed `dbw`
- Short name like the other VMs (`db1`, `c1`, `w1`). In `nodes.yaml` the key changed, so Terraform replaces the VM (new VM, same address 10.0.1.120): run `terraform apply` in `environments/prod`; if the first apply stops with an IP-in-use error on the new port (old and new are created at the same time), run it a second time. The new VM joins etcd by itself and replaces the old member (same address). The monitor on the runner (`WITNESS` default) and `~/.ssh/config` (`Host dbw`) were updated. Older entries of this file still say `db-witness`.

### Spare VM removed
- `learn` (QA, m1.small) removed from `environments/qa/nodes.yaml`; the VM, its port, floating IP and DNS records go away with `terraform apply` in `environments/qa`. VM count 15 after that.

### Limits
Asynchronous replication (a hard failure can lose the last seconds of writes); losing two of the three etcd machines stops automatic failover.

### Not in Terraform
Patroni and etcd configs, nftables guard, patroni-notify, `pg_hba` lines, monitor on the runner (all listed in `docs/db-ha-patroni.md`). In Terraform: role `witness` and VM `db-witness`.

---

## 2026-10-20: load balancers, 3-replica HA, database replica

### Breaking changes (names and addresses that no longer work)
| Gone / changed | Now |
|---|---|
| VM `haproxy` and name `haproxy.rdulinux.com` (192.168.2.5, then `.119`) | destroyed; **192.168.2.5 is the Octavia load balancer `finance-lb`**. ssh alias `haproxy` removed |
| `qa.rdulinux.com` (apex record, finance app) | removed. The zone `qa.rdulinux.com.` stays for the QA VMs (`c1.qa`, ...). The app is `finance.rdulinux.com` |
| `lb.rdulinux.com` | existed for a few minutes as the renamed `haproxy`, then retired |
| `argo.rdulinux.com` → 192.168.2.5 | now → **192.168.2.113**, its own load balancer `argo-lb` |
| VM `db` | renamed **`db1`** (same VM, IP and data). `db.rdulinux.com` is now an alias for the current primary (TTL 60 s) |
| the *original* prod worker `w1` (10.0.1.118) and the test VMs `web1`, `web2` | deleted; prod `w1` was re-created as a new VM |
| ssh alias `qa` | removed; `ssh w1.prod` and `ssh w1.qa` both work |

### Verified: client addresses behind the load balancer
- nginx logs the real visitor address (`192.168.1.13`, `192.168.2.2`) as `client_ip` behind `finance-lb`, so per-address limits count per person (still per nginx pod). Noted in the finance repo's `docs/CICD_SETUP.md`.
- The finance backend's `/health` now ends with a newline (finance repo, deployed in `sha-94290d1`).

### Host `c3`: a plain reboot now brings everything back, including both front doors (see `docs/amphora-reboot-fix.md`)
- **Result:** two plain reboots of `c3` with all 17 VMs running and no manual step: VMs back by themselves in about 2 minutes, both front doors 200 about 3 minutes after `c3` answered ssh, the same three amphorae (no rebuilds), load balancers `ACTIVE`/`ONLINE`.
- **Root causes found and fixed:** (1) the amphora image (Octavia 16.1.1) lost its VIP network after any clean shutdown: its boot script paired lines of `ip link` (breaks on `altname` lines) and raced udev's NIC rename; **patched image `Amphora-netns-fix-v2-20261020`** (the only one tagged `Amphora`; all three amphorae rebuilt from it); (2) OVN's router (`always_learn_from_arp_request=false`, no aging) kept a stale MAC for a rebuilt amphora: new **`ovn-vip-binding.timer`** watcher on `c3` (`scripts/ovn-vip-binding-reconciler.py`, every 30 s, no credentials needed); (3) Octavia's health manager rebuilt amphorae that were just waking up: **`heartbeat_timeout = 900`** (and `failover_threshold = 2`).
- **Behaviour change:** a really dead amphora is now replaced automatically only after 15 minutes. **Known flaw left:** `openstack loadbalancer failover finance-lb` (two amphorae at once) fails about half the time with a Nova/Placement "no allocation candidates" error and needs a retry; cause not found.
- Old images `90ce7754…` (original) and `c537e966…` (first, insufficient patch) are kept untagged as backups. The patch must be redone if the amphora image is ever replaced.
- Also: the earlier autostart settings, `nmbd` fix and `ndots:2` (next entry) are unchanged.

### Host `c3`: VMs restart by themselves after a boot, plus two small fixes
- **Autostart configured** (`docs/c3-reboot.md`): `resume_guests_state_on_host_boot = true` (Nova), clean parallel guest shutdown and no libvirt autostart (`/etc/default/libvirt-guests`), a systemd drop-in so `nova-compute` stops before the guests are shut down, and Octavia `failover_threshold = 2` so a reboot does not trigger a mass rebuild of amphorae. Proven on the spare VM `learn` (restarted in 24 s; a VM stopped on purpose stays off); proven through two plain reboots (see the entry above).
- **`nmbd` fixed:** Samba listened on `enp3s0`, which has no IP (it is a port of the bridge `br0`); now `br0`. **Name lookups on `c3` fixed:** `options ndots:2` so `nslookup w1.prod` works. Backups of every changed file: `*.bak-20261020`.

### Rehearsed: rebooting the cloud host `c3` (see `docs/c3-reboot.md`)
- All 17 VMs were shut down gracefully, `c3` was rebooted (back in 150 s), the persistent route came up by itself, and everything was started again in order. The prod and QA clusters, both databases (replication resumed on its own) and the app came back with no data loss.
- **Findings:** Nova does not restart VMs after a host boot; Octavia's health manager rebuilt amphorae right after it started and some rebuilds failed, so both load balancers needed a manual `openstack loadbalancer failover` (about 100 s each); `nmbd` fails on every boot (unrelated). OpenStack on `c3` is Debian packages, not Kolla (docs corrected).

### Added
- **Octavia load balancers** (built by hand, doc: `docs/octavia-finance-lb.md`): `finance-lb` (active/standby, two amphorae, flavor `ha`) at 192.168.2.5 for the finance app, `argo-lb` (one amphora) at 192.168.2.113 for Argo CD. Health-checked, round robin over the prod workers. Failover tested: 485 requests, 0 failed while the active amphora was powered off.
- **Workers `w4` and `w5`** in prod; the original `w1` was drained and retired with 0 failed requests, then **a fresh `w1` was added the same day** (private 10.0.1.67, floating 192.168.2.52), so prod is `c1` plus **`w1` to `w5`**. All five are members of both load balancer pools. The four apps were then rolled one at a time so `w1` runs a pod of each (186 requests during the rollouts, 0 failed).
- **Finance app on 3 replicas**, one per node, with required anti-affinity, `PodDisruptionBudget`s, one-at-a-time rollouts and `preStop` drains (finance repo, `k8s/`; doc: `docs/k8s-operations.md`).
- **PostgreSQL replica `db2`** streaming from `db1`; scripts `db-replica-setup.sh` and `db-replication-status.sh`; **replication monitor with ntfy alerts** on the runner (`install-db-monitor.sh`). Doc and runbook: `docs/db-replication.md`.
- **Rehearsed on live prod:** planned switchover both ways (26 s and 23 s of failed writes) and an unplanned crash of `db1` (failover with 0 rows lost; the monitor alerted in about 80 s and again on split brain).
- `docs/ARCHITECTURE.md`, `docs/k8s-operations.md`, `docs/operations-cheatsheet.md`, `docs/terraform-v2-migration.md`, `docs/db-auto-failover-plan.md` (proposal), this changelog and a docs index.
- DNS: `finance.rdulinux.com` (192.168.2.5), `db.rdulinux.com` (alias, TTL 60 s); per-record `ttl` support in the DNS module.

### Changed
- Backups: the backend image now carries the **PostgreSQL 16 client**, matching the 16 server, so dumps restore with plain `psql` (they used to carry a PostgreSQL 17 `SET transaction_timeout` line). Verified: 85/85 tables, row counts identical. Doc: `docs/finance-db-restore.md`.
- Security-group lookups by name instead of hard-coded IDs; `security_group_ids` output reduced to `k8s`.
- `db-replica-setup.sh` no longer appends duplicate `pg_hba` rules (the duplicates were cleaned from both hosts; backups kept as `pg_hba.conf.bak-20261020`).

### Removed
- The `loadbalancer` Terraform role, `cloud-init/haproxy.*`, the temporary `web` role and its security group.

### Not in Terraform (done by hand; see `docs/ARCHITECTURE.md`)
- **`c3` host route** `10.0.1.0/24 via 192.168.2.174` (runtime and in `/etc/network/interfaces`, backup `.bak-20261020`): `c3` can now reach VMs on their private IPs, not only floating IPs. Explained in `docs/c3-host-route.md`.
- All Octavia objects and their floating IPs; Octavia needed `[health_manager] controller_ip_port_list` and `heartbeat_key`, and **both** `octavia-worker` and `octavia-health-manager` must be restarted after any `octavia.conf` change.
- Placement allocation ratios raised (disk 1.5, memory 1.1) and the project core quota set to 64 (two 2 GB amphorae per HA load balancer).
- Kubernetes secret `db-secret` is edited during a database failover; PostgreSQL roles, rules, slot and conf files on `db1`/`db2`; the monitor on the runner.

### Fixed
- `pg_dump` 17 against the 16 server (above). A rollout stuck on a spread constraint that counted the tainted control plane as an empty domain (`nodeTaintsPolicy: Honor`). Argo CD answering with the finance app (a host rule matched only the exact name; now a separate load balancer).
- A load balancer VIP on the amphora management network (members all `ERROR`): the VIP must be on the private subnet.

### Known gaps
No automatic database failover (proposal in `docs/db-auto-failover-plan.md`); single control plane per cluster; NFS on `repo` has no replica; the monitor runs on the runner (no alert if the runner is down); `argo-lb` has one amphora (and a dead amphora is replaced only after 15 minutes); rebuilding two amphorae at once is flaky; `/health` does not test the database.

---

## 2026-10-19: prod Kubernetes cluster rebuilt, names and zones cleaned up

### Breaking changes
- **VM names no longer contain the environment** (`prod-c1` → `c1`). `moved` blocks kept the VMs; the environment is a tag.
- **Per-environment DNS zones:** prod nodes are `<name>.prod.rdulinux.com`, qa nodes `<name>.qa.rdulinux.com`. Shared services stay in `rdulinux.com`.
- The prod cluster was **rebuilt** (nodes `c1`, `w1` to `w3` re-created with proper hostnames and node names). The kubeconfig CA changed; the CI runner's kubeconfig had to be replaced.

### Added
- Rebuild without user-visible outage: workloads **parked on the qa cluster**, haproxy swapped twice (one reload each), data safe on NFS. Procedure and real log: `docs/prod-k8s-rebuild.md`.
- **Backup proof before touching anything:** the finance database backup was restored into a scratch database (85/85 tables, identical row counts), and an **etcd snapshot restore was rehearsed on QA** (`docs/etcd-restore-rehearsal.md`). A safety tarball of NFS uploads and backups went to `backup:/backup/finance-qa/pre-rebuild-20261019/`.
- **etcd snapshot timer** on controllers (cloud-init and `scripts/install-etcd-snapshot.sh`); `scripts/k8s-copy-between.sh` (copy objects between clusters through two kubeconfigs, secrets never on disk); `scripts/install-ingress-nginx.sh`; `scripts/clear-stale-port.sh`; `scripts/openstack-shortcuts.sh` (Env column); a `learn` VM role.

### Changed
- `k8s` security group rules limited to `192.168.2.0/24` and `10.0.1.0/24` (443 and ICMP stay open). Worker join retries 5 times; the join file is per cluster (`/nfsshare/join-<cluster>.sh`); metrics-server patched with `--kubelet-insecure-tls` on new controllers.

---

## 2026-10-17: Terraform v2

### Added / changed
- **Redesigned Terraform** (`infra/` + `environments/{prod,qa}/` + `modules/`): YAML-driven, `for_each` with stable keys so nothing shifts or is recreated, cloud-init composed per role, `ignore_changes` so editing a template never replaces a running VM. Rationale and the migration method: `docs/terraform-v2-migration.md`.
- **State moved from local files to S3 (MinIO)**; keys `openstack/infra/...` and `openstack/<env>/nodes/...`.
- All live VMs **adopted in place** (`scripts/adopt-node.sh`), no recreation; `c2` and the old `w4` to `w6` removed.
- The v1 stacks were retired (`terraform state rm` of 32 and 55 entries) and kept in `../archive/` with a "do not apply" notice. DNS for the `backup` host (192.168.2.4) added.

---

Earlier history (2026-03 to 2026-08: first cluster, GitLab, runner, image paths, timezone) is in `git log`; nothing before the v2 redesign is documented here.
