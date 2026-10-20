# Architecture: what runs where

Verified against the live system on **2026-10-20**. If you change something big, update this file in the same commit
(and add a line to `../CHANGELOG.md`).

## The one-paragraph version
A single physical host, **`c3`**, runs OpenStack (Debian 13 packages as systemd services; no Kolla, no Docker). On it live two Kubernetes clusters (**prod** and **qa**), two PostgreSQL VMs
(a primary and a streaming replica), a GitHub Actions runner, and two Octavia load balancers. The finance app runs in the **prod** cluster, is deployed by
Argo CD from the `develop` branch of the finance repo, and is reached through the load balancer `finance-lb`. VMs are created from `nodes.yaml` files with Terraform;
load balancers, Kubernetes objects and the monitor are not (see "What Terraform does not manage").

## Glossary (the names are confusing, read this once)
| Term | Means |
|---|---|
| **prod / qa** (this repo) | The two Terraform environments: `environments/prod` and `environments/qa`. Each has its own Kubernetes cluster and DNS zone. |
| **"QA"** (finance repo) | The finance repo calls its Kubernetes deployment "QA" (branch `develop`, Argo application `finance-qa`, CI job "Restart QA Pods"). **That deployment runs in the infra "prod" cluster.** The real production of the finance app is a separate Docker Compose host (`yourassets.in`), not in this repo. |
| **infra "qa" cluster** | Currently runs nothing of the finance app (only ingress-nginx). It is a spare cluster and was the parking place while prod was rebuilt on 2026-10-19. |
| **primary / replica** | one DB host is writable, the other follows it. **Patroni swaps the roles by itself on failure**; the host names do not move. The app lists both hosts in `DATABASE_URL` and finds the writable one (`db-ha-patroni.md`). |
| **`db.rdulinux.com`** | A DNS alias for whichever database is primary right now. |

## Addresses and names
Networks: **external** `192.168.2.0/24` (gateway `.1`, floating IP pool `.51` to `.150`; `.2` to `.5` are static) and **private** `10.0.1.0/24` (gateway `10.0.1.1`).
Nodes talk over the private network; people and the load balancers use floating IPs. DNS server: `192.168.2.2` (Designate on `c3`).

### Shared services (zone `rdulinux.com`)
| Name | Floating IP | Private IP | What |
|---|---|---|---|
| `c3` | 192.168.2.2 | n/a | the cloud host: OpenStack (Debian packages) and the DNS server (Designate). **Rebooting it takes everything down; the VMs restart by themselves and both front doors return about 3 minutes after `c3` is reachable (proven with two plain reboots on 2026-10-20): `c3-reboot.md`, `amphora-reboot-fix.md`** |
| `repo` | 192.168.2.3 | n/a | NFS server: VM images, finance logs, uploads and backups (`/exports/finance-qa/...`); VMs mount a share at `/nfsshare` (join files, etcd snapshots) |
| `backup` | 192.168.2.4 | n/a | backup host (off-host copies, e.g. `/backup/finance-qa/pre-rebuild-20261019/`) |
| `finance` | 192.168.2.5 | VIP 10.0.1.89 | the finance app, served by Octavia `finance-lb` |
| `argo` | 192.168.2.113 | VIP 10.0.1.56 | Argo CD, served by Octavia `argo-lb` |
| `db1` | 192.168.2.124 | 10.0.1.191 | PostgreSQL 16 under Patroni + etcd; primary or replica (currently **primary**) (m1.small) |
| `db2` | 192.168.2.135 | 10.0.1.69 | PostgreSQL 16 under Patroni + etcd; primary or replica (currently **replica**) (m1.small) |
| `dbw1` `dbw2` `dbw3` | floating IPs per VM | 10.0.1.120, .121, .122 | the three witnesses: etcd voters only, no data (m1.tiny); five voters with db1 and db2 |
| `db` | 192.168.2.124 (TTL 60) | n/a | alias of the current primary; edit `infra.yaml` to fail over |
| `runner` | 192.168.2.144 | 10.0.1.47 | GitHub Actions self-hosted runner + the replication monitor (m1.large) |
| `@`, `www`, `rdu` | 13.140.58.46 | n/a | public address (not a lab VM) |

### Kubernetes
| Cluster | Zone | Nodes (floating / private IP) |
|---|---|---|
| **prod** | `prod.rdulinux.com` | `c1` .103 / 10.0.1.254 (control plane), `w1` .52 / .67, `w2` .193 / .197, `w3` .139 / .45 (`w4` and `w5` were retired 2026-10-20; the cluster is now c1 + 3 workers) |
| **qa** | `qa.rdulinux.com` | `c1` .120 / 10.0.1.66, `w1` .59 / .118, `w2` .98 / .10, `w3` .136 / .96 (the spare `learn` VM was removed 2026-10-20) |
Kubernetes 1.30, Calico, pod CIDR `192.168.0.0/16`. Names have no environment prefix: `ssh c1.prod`, `ssh w2.qa`. Server names repeat across environments by design.
(Floating IPs here are the last octet of `192.168.2.x`.)

## How a request travels
```
browser / curl
   |  http://finance.rdulinux.com  ->  192.168.2.5
   v
Octavia finance-lb (2 amphora VMs, active/standby, VRRP)          http://argo.rdulinux.com -> 192.168.2.113 -> argo-lb (1 amphora)
   |  health check GET /health on each worker, round robin                |  health check GET /healthz
   v                                                                      v
worker NodePort 30080 (w1..w3)                                    worker NodePort 30443 (w1..w3) -> argocd-server
   |  kube-proxy
   v
nginx pods (3, one per node)  ->  /api -> backend (3)   /docs -> docs (3)   / -> frontend (3)
                                        |
                                        v
                    PostgreSQL primary 10.0.1.191 (db1)  <-- streams WAL -->  replica 10.0.1.69 (db2)
```
- The backend reaches the database **by private IP** from the `DATABASE_URL` key of the secret `finance/db-secret`. A failover edits that secret (`db-replication.md`).
- Files (uploads, logs, backups) are on NFS shares from `repo`, mounted as PersistentVolumes.
- Backups: CronJobs `db-backup-hourly` / `db-backup-daily` run `pg_dump` (client 16, matching the server) and write to NFS (`finance-db-restore.md`).

## Deployments and who changes what
| Thing | Source of truth | Applied by |
|---|---|---|
| Network, security group, keypair, images, DNS zones and records | `infra/infra.yaml` | `terraform apply` in `infra/` (run first) |
| VMs, their ports, floating IPs and per-VM DNS | `environments/<env>/nodes.yaml` | `terraform apply` in `environments/<env>/` |
| Finance app manifests (replicas, probes, PDBs, NetworkPolicies, CronJobs, PVs) | finance repo `k8s/` on `develop` | **Argo CD** (auto-sync + selfHeal + prune) |
| App images | finance repo CI builds `ghcr.io/vellingiri/finance/{backend,frontend,docs}:sha-<commit>` | CI pins the Argo application to the commit's images |
| Terraform state | S3 (MinIO) bucket `terraform-state`: `openstack/infra/...`, `openstack/<env>/nodes/...` | needs `OS_*` and the MinIO keys in your shell |

### What Terraform does **not** manage (change these by hand, and note it in `CHANGELOG.md`)
- **Octavia:** the flavor `ha`, `finance-lb`, `argo-lb`, their listeners, pools, members (**static**: edit them when a worker is added or retired) and floating IPs (`octavia-finance-lb.md`).
- **Host networking on `c3`:** a static route `10.0.1.0/24 via 192.168.2.174` (the router's external address) in `/etc/network/interfaces` so the host can reach private VM addresses (`c3-host-route.md`).
- **VM autostart and other host settings on `c3`:** `resume_guests_state_on_host_boot` in `nova.conf`, `/etc/default/libvirt-guests`, a systemd ordering drop-in for `nova-compute`, `failover_threshold` in `octavia.conf`, `interfaces = ... br0` in `smb.conf`, and `options ndots:2` in `/etc/resolv.conf` (`c3-reboot.md`).
- **Octavia hardening against host reboots:** the patched Glance image `Amphora-netns-fix-v2-20261020` (the only one tagged `Amphora`), `heartbeat_timeout = 300` and `failover_threshold = 2` in `octavia.conf`, and the `ovn-vip-binding.timer` watcher (`amphora-reboot-fix.md`).
- **Cloud tuning on `c3`:** Placement allocation ratios (disk 1.5, memory 1.1), project core quota 64, and `/etc/octavia/octavia.conf` (restart BOTH `octavia-worker` and `octavia-health-manager` after any change).
- **Kubernetes secrets** (`app-secret`, `db-secret`, `ghcr-secret`, Argo CD's repo credential and `argocd-secret`): not in git, not in Terraform. They are copied between clusters with `scripts/k8s-copy-between.sh` without touching disk.
- **PostgreSQL itself:** roles (`financeapp`, `replicator`, `monitor`), `pg_hba.conf`, `conf.d/20-replication.conf`, replication slot `slot_db2`; built by `scripts/db-replica-setup.sh`, not by cloud-init.
- **The replication monitor** on the runner (`/usr/local/sbin/db-replication-monitor`, `/etc/default/db-monitor`, systemd timer `db-monitor.timer`), installed by `scripts/install-db-monitor.sh`. Its ntfy topic is only in that file.
- **ssh aliases and kubeconfigs** on your Mac: `~/.ssh/config`, `~/.kube/prod`, `~/.kube/qa` (see `operations-cheatsheet.md`).

## Capacity (as of 2026-10-20)
The cloud is one host with 32 vCPUs and about 80 GB of memory. Nova allocates memory with a ratio of 1.1 (about 88 GB allocatable): **about 7.8 GB of allocatable memory was left**
after `db2` and `argo-lb`. A new `m1.small` is 4 GB, an `m1.tiny` 2 GB, an amphora 2 GB. If a build fails with `NoValidHost`, check Placement before anything else
(`octavia-finance-lb.md`, "Pitfalls"). Retiring unused VMs (like the old `web1`/`web2` test VMs) is how room was made before.

## Data protection map
| What | Protection | Proof / doc |
|---|---|---|
| Finance database | hourly and daily `pg_dump` to NFS; streaming replica with **automatic failover** (Patroni, 3-member etcd; losing any one of db1/db2/dbw1 is survived, losing two is not); alerts on replica, Patroni and witness health | `finance-db-restore.md`, `db-ha-patroni.md` |
| Kubernetes state | etcd snapshot timer on each controller (`/var/backups/etcd`, copied to NFS) | `etcd-restore-rehearsal.md` |
| Files (uploads, logs) | NFS on `repo`; a tarball copy on `backup` before risky work | `prod-k8s-rebuild.md` |
| Terraform state | S3 (MinIO) bucket with locking | `../README.md` |
| The cluster itself | rebuildable from `nodes.yaml` + cloud-init; workloads come back from Argo CD + the three secrets | `prod-k8s-rebuild.md` |

## Known single points of failure
- `c1` is the only control plane in each cluster (workloads keep running if it dies; deploys and changes stop). Plan: three controllers behind Octavia on 6443 (not started).
- NFS on `repo` (uploads, logs, backups) has no replica.
- Database failover is manual (`db-replication.md`); automatic failover is only a proposal (`db-auto-failover-plan.md`).
- The monitor runs on the runner: if the runner is down, nobody is alerted.
- Both load balancers are ACTIVE_STANDBY (two amphorae each; `argo-lb` since 2026-10-20); a dead amphora is replaced automatically after 5 minutes (`heartbeat_timeout = 300`), or at once with `openstack loadbalancer failover <lb>`.
- Rebuilding two amphorae at once (`openstack loadbalancer failover finance-lb`) fails about half the time and needs a retry (`amphora-reboot-fix.md`).
