# Documentation index

Start with **ARCHITECTURE.md** to see what runs where, then jump to the runbook you need. Release notes: `../CHANGELOG.md`. How the Terraform is used day to day: `../README.md`.
All documents were checked against the live system on 2026-10-20; each says what it covers and what it does not.

## By situation
| I need to... | Read |
|---|---|
| understand the whole setup, names, IPs, who changes what | [ARCHITECTURE.md](ARCHITECTURE.md) |
| find a command, check health, know where a secret lives | [operations-cheatsheet.md](operations-cheatsheet.md) |
| see what changed and when (and what broke compatibility) | [../CHANGELOG.md](../CHANGELOG.md) |
| add or retire a Kubernetes worker, drain a node, roll back a deploy | [k8s-operations.md](k8s-operations.md) |
| work on the finance front door or Argo's address, change load balancer members | [octavia-finance-lb.md](octavia-finance-lb.md) |
| deal with the database: failover, switchover, rebuild a replica, Patroni/etcd problems | [db-ha-patroni.md](db-ha-patroni.md) |
| how the replica was built, replication alerts (background) | [db-replication.md](db-replication.md) |
| restore data from a backup | [finance-db-restore.md](finance-db-restore.md) |
| rebuild a whole Kubernetes cluster | [prod-k8s-rebuild.md](prod-k8s-rebuild.md), [etcd-restore-rehearsal.md](etcd-restore-rehearsal.md) |
| understand why Terraform looks the way it does, or adopt a VM | [terraform-v2-migration.md](terraform-v2-migration.md), [../README.md](../README.md) |
| reboot `c3` (or recover after it rebooted); how VMs restart by themselves, the nmbd and name-lookup fixes | [c3-reboot.md](c3-reboot.md) |
| understand why load balancers broke after a host reboot and how it was fixed (patched amphora image, health-manager setting, OVN watcher) | [amphora-reboot-fix.md](amphora-reboot-fix.md) |
| build, use or throw away the CKA practice cluster (1 control plane + 3 workers) | [cka-cluster.md](cka-cluster.md) |
| understand or undo the route that lets `c3` reach private VM addresses | [c3-host-route.md](c3-host-route.md) |
| understand or operate the three-node Kubernetes control plane and its API load balancer | [k8s-ha-control-plane.md](k8s-ha-control-plane.md) |
| the `s3` host: RustFS, where Terraform keeps every state, its backups and how to restore | [s3-state-store.md](s3-state-store.md) |
| rebuild `c3` and everything on it from nothing (disaster recovery) | [c3-rebuild.md](c3-rebuild.md) |
| see what is still open, waiting for a decision, or an accepted limit | [pending.md](pending.md) |
| a VM replace failed with "Port ... is still in use" (Neutron policy fix on `c3`) | [port-unbind-fix.md](port-unbind-fix.md) |
| why automatic database failover was designed this way | [db-auto-failover-plan.md](db-auto-failover-plan.md) (implemented) |

## By document
| Document | Type | Status |
|---|---|---|
| ARCHITECTURE.md | reference | current (2026-10-20) |
| operations-cheatsheet.md | reference | current |
| k8s-operations.md | runbook | current; node add/retire procedures follow the 2026-10-20 `w4`/`w5`/`w1` changes (rehearsed live) |
| octavia-finance-lb.md | build record + runbook | current; load balancers created by hand |
| k8s-ha-control-plane.md | design + proof | prod built and drilled 2026-10-20 (cka rehearsed, now one control plane) |
| s3-state-store.md | reference + runbook | state backups installed 2026-10-20 |
| c3-rebuild.md | runbook + scripts | written 2026-10-21; capture verified read-only, installer NOT yet rehearsed |
| pending.md | status page | keep current; last updated 2026-10-20 |
| cka-cluster.md | runbook | built and verified 2026-10-20 |
| port-unbind-fix.md | incident + fix | fixed and proven 2026-10-20 |
| db-ha-patroni.md | runbook + proof | current; five failure drills passed on live prod 2026-10-20 |
| db-replication.md | build record (background) | replication build and monitoring current; its manual failover steps are superseded by Patroni |
| db-auto-failover-plan.md | design record | implemented 2026-10-20 |
| finance-db-restore.md | runbook + proof | current; `pg_dump` mismatch fixed 2026-10-20 |
| prod-k8s-rebuild.md | runbook + execution log | procedure executed 2026-10-19 with haproxy; the Octavia adaptation at the top is **not rehearsed** |
| etcd-restore-rehearsal.md | runbook + proof | rehearsed 2026-10-19 on QA |
| terraform-v2-migration.md | design record | complete |
| c3-host-route.md | change record + undo | current; boot-tested 2026-10-20 |
| c3-reboot.md | runbook + test record | four reboot tests on 2026-10-20; the last two hands-off and passing |
| amphora-reboot-fix.md | root cause + fix + proof | current; the image patch must be redone if the amphora image is replaced |

## Keeping this true
- A change that touches addresses, names, load balancer members, the database layout or a procedure updates the matching doc **and** `../CHANGELOG.md` in the same commit.
- Anything done by hand goes in ARCHITECTURE.md under "What Terraform does not manage".
- When you prove a procedure (a rehearsal, a real incident), add the date and the measured result to its document. Unrehearsed steps say so.
- Finance application documentation (features, CI/CD, security, user guides) is in the finance repo: `README.md`, `docs/`, `k8s/README.md`, and user-facing release notes in `docs/RELEASE_NOTES.md`.
