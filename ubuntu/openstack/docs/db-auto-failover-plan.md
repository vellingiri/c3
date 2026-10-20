# Plan: automatic failover for the finance database

**Status: implemented 2026-10-20** (Phase 0 plus Patroni with a 3-member etcd and a new `m1.tiny` witness VM, all five drills passed).
What exists and how to run it: **[db-ha-patroni.md](db-ha-patroni.md)**. The text below is the original proposal, kept for the reasoning.

## Why, and what "good" means
Today `db1` is the primary and `db2` a streaming replica (`db-replication.md`). If `db1` dies, a person has to notice (the monitor alerts within
2 minutes), fence it, promote `db2`, edit the app's secret and restart the backend. Rehearsed on prod: about 30 s of commands, so realistically
**5 to 10 minutes** of failed writes depending on when someone reacts, plus a manual rebuild of the old primary.

Target: **a dead primary is replaced by the replica in about 30 to 45 seconds with nobody awake, never two writable primaries, the app needs no secret
edit or restart, and the old primary rejoins by itself.** Planned switchover becomes one command.

## The root problem with two nodes
Two database VMs cannot tell "the other one is dead" from "I cannot reach the other one". Promoting on a guess causes split brain (two writers,
diverging data). Every automatic scheme therefore needs a **third voter**: a small witness that decides who may be primary.

## Options
| | How it works | For | Against |
|---|---|---|---|
| **A. Patroni + etcd (3 voters)** | Patroni runs Postgres on each DB VM. The primary must keep renewing a leader key in etcd; if it cannot, it demotes itself, and the replica takes the key and promotes. Old primary is rewound automatically (`pg_rewind`). | The standard approach; split-brain safe by design; planned switchover and failover are built in; handles the "old primary comes back" problem we hit in the outage test | Replaces how Postgres is started and configured (config moves into Patroni's YAML); one more component to learn; needs etcd on 3 voters |
| B. repmgr + witness | `repmgrd` watches and promotes | Keeps Ubuntu's normal Postgres units; lighter | Weaker split-brain protection; no built-in way to move clients, so we would hand-roll health checks; less common for new builds |
| C. pg_auto_failover | A small "monitor" Postgres decides | Simple 3-node model | The monitor is its own single point of failure; smaller community |
| D. Home-grown script | Our own watchdog promotes | Little to install | We would be writing a consensus protocol; risk of split brain; not recommended |
| E. Do nothing more | Manual failover + alerts (now) | Zero risk | Minutes of outage and a person in the loop |

**Recommendation: A, in two phases.** Phase 0 is a small change that helps even if we never do A.

## Phase 0: multi-host connection string (small, independent)
Both the backend driver (`asyncpg` 0.29) and `libpq` (`psql`, `pg_dump`, so the backup CronJobs) accept
`postgresql://user:pass@10.0.1.191:5432,10.0.1.69:5432/financedb?target_session_attrs=read-write` and connect to whichever host is writable.
**Tested 2026-10-20 from a backend pod, replica listed first: both drivers picked the primary.** Effect: after any promotion (manual or automatic)
the app reconnects on its own; no `db-secret` edit, no restart. It also removes the need for a database load balancer: no extra amphora VMs, and
we are short of memory for those (about 7.8 GB of allocatable memory is left).
Cost and risk: one edit of the production `db-secret`, a backend restart, a backup-job check. Not yet proven through a real failover; do a planned
switchover with it in place before trusting it. Rollback: put the single IP back.

## Phase 1: Patroni + etcd
### Target layout
```
 app / backup jobs (multi-host DSN: db1, db2)           monitor (runner, ntfy)
        |                      |                                    |
      db1:5432  <--stream-->  db2:5432        Patroni REST :8008 on each (role, health)
      Patroni                 Patroni
        \                     /
         etcd (db1)  etcd (db2)  etcd (witness)   <- 3 members = survives the loss of any one
```
- **Witness VM `db-witness`:** new `m1.tiny` (1 vCPU, 2 GB, 10 GB disk; the only small flavour) running **only etcd**. Cheaper and safer than putting an etcd
  member on the CI `runner` (CI jobs can starve etcd of disk and CPU, which makes leader elections flap). The runner is the fallback if capacity is a problem.
- **Same Postgres 16 and data directories** on `db1`/`db2`; Patroni takes over starting Postgres, so the `postgresql@16-main` units are disabled.
- **Settings to decide** (defaults in brackets): leader TTL 30 s, `loop_wait` 10 s, `retry_timeout` 10 s (failover in roughly 30 to 45 s);
  `maximum_lag_on_failover` 1 MB; `use_pg_rewind` on (needs `wal_log_hints = on`, i.e. one restart); `failsafe_mode` on (a primary keeps serving if
  etcd is briefly unreachable but both DB nodes can still see each other); replication slots managed by Patroni; `synchronous_mode` **off**
  (see decisions).
- **Callbacks:** Patroni's `on_role_change` posts to the same ntfy topic ("db2 is now primary"), so a failover is announced, not discovered.
- **The existing monitor** (`db-replication-monitor.sh`) keeps working by role; add checks for etcd health and Patroni's view (`/cluster`).
- **Backups:** unchanged (they follow the primary through the multi-host DSN).

### Migration order (existing data, no rebuild of the database)
1. Take a fresh backup and confirm the restore doc still passes. Do Phase 0 first so the app does not care about restarts.
2. Create `db-witness` (Terraform, `nodes.yaml`) and form a 3-member etcd cluster (`db1`, `db2`, `db-witness`). Test it with `etcdctl endpoint health`
   and by stopping one member.
3. **Primary first:** install Patroni on `db1`, stop `postgresql@16-main`, start Patroni on the same data directory so it claims the leader key.
   This restarts Postgres: **about 10 to 30 s of failed writes.** Never start Patroni on the replica first: with no leader key it would promote itself.
4. Install Patroni on `db2` and let it re-attach as a replica (it sees the leader key and follows; if its data is stale, let Patroni rebuild it).
5. Move the settings that live in `conf.d` today (`max_slot_wal_keep_size`, `hot_standby_feedback`, `listen_addresses`) and the `pg_hba` rules
   (`financeapp`, `replicator`, `monitor`) into Patroni's config, so they are not lost on a rebuild.
6. Update the runbook, the setup script's role (rebuild path becomes `patronictl reinit`) and the monitor.
Rollback at any step before 6: stop Patroni, re-enable `postgresql@16-main` on the same data directory, remove the leader key.

### Proving it before we trust it (drills, each timed and logged here)
1. Planned `patronictl switchover` there and back; app writes uninterrupted except for a few seconds.
2. Stop Postgres on the primary (process dies): promotion happens, old primary restarts as a replica by itself.
3. **Power off the primary** (the outage test we already ran by hand): failover in about 30 to 45 s with a probe writer measuring lost rows;
   power it back on and confirm it comes back as a replica, not as a second primary.
4. **Network partition:** block the primary from etcd and from the replica: it must demote and stop accepting writes (this is the split-brain test).
5. Lose the witness: nothing changes; lose the witness and one DB: expected outage (no quorum), and it must come back when one returns.
6. Backup CronJob and a restore test through the new endpoint during a failover.
Do drills 2 to 5 in a quiet hour on the real pair after step 4 of the migration, with a backup taken first and the monitor watching.

## Costs and risks
- **Time:** about a day including the drills (witness, etcd, two Patroni installs, config move, drills, docs).
- **Capacity:** one more `m1.tiny` (2 GB). Allocatable memory left is about 7.8 GB, so this fits, but another load balancer pair would not.
- **Complexity:** a new moving part. A mis-set TTL can cause needless failovers; mitigated by `failsafe_mode`, a dedicated witness and the drills.
- **Quorum:** losing two of three voters stops writes (Patroni demotes the primary rather than risk split brain). That is the safe failure.
- **Data loss:** asynchronous replication can lose the last fraction of a second on a hard crash (the outage test lost 0 rows at 5 writes/s, a best case).
  `synchronous_mode` closes that gap at the price of blocking writes whenever the replica is down.
- **Not verified yet:** package versions in Ubuntu 24.04 for `patroni` and `etcd` (to be checked when building), and Patroni's behaviour on this
  exact setup (that is what the drills are for).

## Decisions needed from you
1. **Go for Phase 0 (multi-host connection string) now?** Small, useful on its own, needs a production secret edit and a backend restart.
2. **Go for Phase 1 (Patroni)?** Or stay with manual failover plus alerts (option E)?
3. **Witness:** new `m1.tiny` VM (recommended) or an etcd member on the `runner`?
4. **Asynchronous (recommended, as now) or synchronous replication?** Synchronous means no lost writes but writes stop if the replica is down.
5. **A window** for the primary-first restart and the drills (a quiet hour; expect a few seconds to 30 s of failed writes, and short failovers during the drills).
