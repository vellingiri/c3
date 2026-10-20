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
| deal with the database: failover, switchover, rebuild the replica, replication alerts | [db-replication.md](db-replication.md) |
| restore data from a backup | [finance-db-restore.md](finance-db-restore.md) |
| rebuild a whole Kubernetes cluster | [prod-k8s-rebuild.md](prod-k8s-rebuild.md), [etcd-restore-rehearsal.md](etcd-restore-rehearsal.md) |
| understand why Terraform looks the way it does, or adopt a VM | [terraform-v2-migration.md](terraform-v2-migration.md), [../README.md](../README.md) |
| understand or undo the route that lets `c3` reach private VM addresses | [c3-host-route.md](c3-host-route.md) |
| decide about automatic database failover | [db-auto-failover-plan.md](db-auto-failover-plan.md) (proposal, nothing built) |

## By document
| Document | Type | Status |
|---|---|---|
| ARCHITECTURE.md | reference | current (2026-10-20) |
| operations-cheatsheet.md | reference | current |
| k8s-operations.md | runbook | current; node add/retire procedures follow the 2026-10-20 `w4`/`w5`/`w1` changes (rehearsed live) |
| octavia-finance-lb.md | build record + runbook | current; load balancers created by hand |
| db-replication.md | build record + runbook | current; switchover and crash failover rehearsed on live prod |
| db-auto-failover-plan.md | proposal | nothing built; waiting for decisions |
| finance-db-restore.md | runbook + proof | current; `pg_dump` mismatch fixed 2026-10-20 |
| prod-k8s-rebuild.md | runbook + execution log | procedure executed 2026-10-19 with haproxy; the Octavia adaptation at the top is **not rehearsed** |
| etcd-restore-rehearsal.md | runbook + proof | rehearsed 2026-10-19 on QA |
| terraform-v2-migration.md | design record | complete |
| c3-host-route.md | change record + undo | current; the permanent version is not yet boot-tested |

## Keeping this true
- A change that touches addresses, names, load balancer members, the database layout or a procedure updates the matching doc **and** `../CHANGELOG.md` in the same commit.
- Anything done by hand goes in ARCHITECTURE.md under "What Terraform does not manage".
- When you prove a procedure (a rehearsal, a real incident), add the date and the measured result to its document. Unrehearsed steps say so.
- Finance application documentation (features, CI/CD, security, user guides) is in the finance repo: `README.md`, `docs/`, `k8s/README.md`, and user-facing release notes in `docs/RELEASE_NOTES.md`.
