# Changelog (infrastructure release notes)

What changed in the lab infrastructure, newest first. One entry per day that mattered, with **breaking changes** called out because they are
what bites later. The matching app-side changes are in the finance repo (`docs/RELEASE_NOTES.md`, [PR 309](https://github.com/vellingiri/finance/pull/309)). Design background: `docs/`.
Update this file in the same commit as any change, and list anything done **by hand** (not in Terraform) under "Not in Terraform".

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
No automatic database failover (proposal in `docs/db-auto-failover-plan.md`); single control plane per cluster; NFS on `repo` has no replica; the monitor runs on the runner (no alert if the runner is down); `argo-lb` has one amphora; `/health` does not test the database.

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
