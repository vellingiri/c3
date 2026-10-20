# Finance database: primary `db1` and streaming replica `db2`

> **Since 2026-10-20 the pair is run by Patroni** (automatic failover, etcd witness `dbw`). Day-to-day operation, failover, switchover and recovery are in
> **[db-ha-patroni.md](db-ha-patroni.md)**. This page is the build record and background. **Do not use the manual `pg_promote` / `db-replica-setup.sh` steps below on a
> Patroni node** (Patroni would fight them); use `patronictl switchover` / `failover` / `reinit` instead. Replication monitoring (below) still applies.

Built and rehearsed 2026-10-20. PostgreSQL 16.15 (Ubuntu packages) on both VMs.

## What this gives you, and what it does not
- **Gives you:** a second, continuously updated copy of the database on another VM. If `db1` is lost, `db2` can be promoted in
  seconds and the app pointed at it (about 5 minutes of work, steps below). It also gives you a place to run heavy read queries.
- **Does not give you:**
  - **Automatic failover** (when this page was written; added later with Patroni, see `db-ha-patroni.md`).
  - **Zero data loss.** Replication is asynchronous, so a transaction acknowledged just before a crash may be missing on the replica.
    Normally the lag is 0 bytes (see Monitoring).
  - **A backup.** A `DROP TABLE` or a bad `UPDATE` replicates immediately. Hourly/daily `pg_dump` backups (`finance-db-restore.md`) stay the
    way back from human error.

## Layout
| | db1 | db2 |
|---|---|---|
| Role today | **primary** (read/write) | **replica** (read only, hot standby) |
| Private IP | `10.0.1.191` | `10.0.1.69` |
| Floating IP | `192.168.2.124` | `192.168.2.135` |
| DNS | `db1.rdulinux.com` | `db2.rdulinux.com` |
| Flavor / disk | m1.small, 10 GB | m1.small, 10 GB |
| Terraform | `environments/prod/nodes.yaml` | same |

- **`db.rdulinux.com` is a service alias for the current primary** (A record in `infra/infra.yaml`, TTL 60 s). After a failover, change
  its `ip` to the new primary's floating IP and apply the `infra` stack. `db1` and `db2` are host names and never change meaning,
  even if the roles swap.
- **The finance app and the backup CronJobs connect by private IP**, not by name: the `DATABASE_URL` key of the Kubernetes secret
  `finance/db-secret` holds `10.0.1.191`. A failover therefore also edits that secret (below).
- **Replication details:** physical streaming replication, role `replicator` (replication privilege only), physical slot `slot_db2` on the
  primary, `hot_standby_feedback = on`, `max_slot_wal_keep_size = 2GB` (so a dead replica can never fill the primary's disk).
  Access rule on both: `host replication replicator 10.0.1.0/24 scram-sha-256`. The replicator password is in `/var/lib/postgresql/.pgpass`
  on the replica and as the role's password on the primary; it is never in git or on screen, and a new one is generated every time the setup
  script runs. The `financeapp` role and its password replicate automatically with the data.
- **`db2` has the same client rules as `db1`** (`financedb`/`financeapp` from `192.168.0.0/16` and `10.0.1.0/16`), so the app can connect
  to it the moment it is promoted. Tested: the app's user connects to `db2` from a backend pod.

## How it was built (2026-10-20)
1. Terraform: the VM `db` was **renamed `db1`** with a `moved` block (`environments/prod/moved.tf`): same VM, port and floating IP. Only the Nova
   name, the port name and the DNS name changed; its Postgres was not touched or restarted. `db2` was added as a normal `database` node.
2. Inside the old VM the hostname was set by hand (`hostnamectl set-hostname db1`) because cloud-init only runs on first boot.
3. `infra` stack: new record `db.rdulinux.com` -> `192.168.2.124`, TTL 60 (the old per-VM `db` record disappeared with the rename).
4. `scripts/db-replica-setup.sh db1 db2` (see below).
5. `~/.ssh/config`: `Host c3 db db1 db2 runner repo backup qa` (user root, c3 key). `ssh db` goes to whoever `db.rdulinux.com` points at.

### `scripts/db-replica-setup.sh [primary] [replica]` (default `db1 db2`)
Run from your Mac. Idempotent: it can be re-run any time and always ends with a fresh copy. It refuses to run if the replica already holds a
user database (set `REBUILD=1` to replace it) and never modifies the primary's data. Steps: sanity checks (hosts differ, primary is not a
standby) -> create role/slot on the primary, write `conf.d/20-replication.conf` and the `replication` rule, reload -> **stop the replica instance
and empty its data directory** -> `pg_basebackup -R -X stream -S slot_db2` -> same conf and client rules on the replica -> start -> wait for
`streaming` on the primary. Run three times from scratch (the first run exposed two bugs, both fixed).

## Monitoring: is it following?
**By hand:** `scripts/db-replication-status.sh db1 db2` (read-only; exit 0 = streaming and under 1 MB behind).
Healthy output: `streaming | async | 0` in the walsender line, the slot `active` with a few bytes retained, `in recovery: t` on the replica.

**Automatic alerts (installed 2026-10-20):** a systemd timer on the **runner** VM runs `/usr/local/sbin/db-replication-monitor` every 2 minutes
and pushes to a private [ntfy.sh](https://ntfy.sh) topic. Subscribe to the topic in the ntfy app or browser; the topic name is the "password" of
the channel, so it is not in git. It lives in `/etc/default/db-monitor` on the runner (mode 0600, together with the monitor login):
`ssh runner "sed -n 's#^NTFY_URL=##p' /etc/default/db-monitor"`.

| It alerts when | Priority |
|---|---|
| a database is unreachable or refuses the monitor login | urgent |
| there is no writable primary, or **two** (split brain) | urgent |
| the primary has no streaming replica | urgent |
| replica more than 16 MB (WAL) behind | urgent |
| a replication slot is inactive, or holds more than 1.5 GB of WAL (the cap is 2 GB) | urgent |
| the replica's receiver is not `streaming` | urgent |
| still broken after 6 hours (reminder) / back to healthy | high / normal |

It notifies on **changes** only, so a long outage does not flood you. It watches both hosts by role (whoever is primary), so it keeps working
after a failover or switchover with no change. The checks run as the login role `monitor` (member of `pg_monitor`: can read statistics, cannot read
data), allowed only to the `postgres` database from `10.0.1.0/24` by the rule `host postgres monitor 10.0.1.0/24 scram-sha-256` on both hosts.

Useful commands:
```bash
ssh runner 'systemctl list-timers db-monitor.timer --no-pager'        # next / last run
ssh runner 'journalctl -u db-monitor.service -n 20 --no-pager'        # what it saw
ssh runner '/usr/local/sbin/db-replication-monitor --dry-run'        # check now, no notification
ssh runner '/usr/local/sbin/db-replication-monitor --test'           # send a test notification
```
(Run these through ssh as above; `--dry-run` exits 1 when there is a problem.) Re-install, rotate the monitor password or move to another runner:
`scripts/install-db-monitor.sh [runner-host]` (keeps the existing topic; `NTFY_TOPIC=...` sets another). Thresholds are variables in
`/etc/default/db-monitor` (`LAG_BYTES`, `SLOT_BYTES`, `REMIND_SECONDS`, `DB_HOSTS` as `name=private-ip` pairs).
**Tested 2026-10-20:** stopped `db2`'s Postgres: one urgent alert (3 problems), no second alert on the next run, one recovery message after the restart.
Limits: it runs on the runner, so if the runner or its internet access is down you get nothing; it does not check disk space.

Things that break replication: the replica VM is down (the slot then keeps WAL on the primary, capped at 2 GB; beyond that the replica must be rebuilt),
a changed `pg_hba.conf`, a different Postgres major version on the two hosts (never mix them), a full disk.

## Failover: the primary (db1) is lost (manual procedure, before Patroni; now automatic, see db-ha-patroni.md)
The goal is one writable primary. **Never leave both writable** (split brain).
1. **Confirm and fence.** Make sure `db1` is really gone, then stop it so it cannot come back writing:
   `ssh c3 'openstack server stop db1'` (a `409 ... vm_state stopped` means it is already off). If it is just unreachable, stop it anyway,
   and keep it stopped until step 7: a crashed primary boots **writable** (tested below).
2. **See how much the replica has** (any rows after this moment are lost):
   `ssh db2 "sudo -u postgres psql -Atc 'select pg_last_xact_replay_timestamp(), now()'"`
3. **Promote:** `ssh db2 "sudo -u postgres psql -Atc 'select pg_promote(wait => true, wait_seconds => 60)'"` -> `t`.
   Check: `ssh db2 "sudo -u postgres psql -Atc 'select pg_is_in_recovery()'"` -> `f`.
4. **Point the app at it** (the password is never printed; the commands only swap the host inside `DATABASE_URL`):
   ```bash
   k() { kubectl --kubeconfig ~/.kube/prod -n finance "$@"; }      # a function, not K="kubectl ...": that breaks in zsh
   NEW=$(k get secret db-secret -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed 's/10\.0\.1\.191/10.0.1.69/' | base64 | tr -d '\n')
   k patch secret db-secret -p "{\"data\":{\"DATABASE_URL\":\"$NEW\"}}"
   k rollout restart deploy/backend && k rollout status deploy/backend
   ```
   The backup CronJobs read the same secret and pick it up on their next run. The secret is not in git or managed by Argo.
5. **DNS:** in `infra/infra.yaml` set `db: { ip: 192.168.2.135, ttl: 60 }`, then `terraform apply` in `infra` and push. In an emergency you can
   change it faster from c3: `openstack recordset set rdulinux.com. db.rdulinux.com. --record 192.168.2.135` (then make `infra.yaml` match, or the next
   apply reverts it). Servers see the change within a minute. **macOS caches the old answer for longer**: if `ssh db` still lands on the old host,
   `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`.
6. **Verify:** `curl http://finance.rdulinux.com/health` -> 200, log in and open a page that reads and writes, and run a backup job:
   `k create job --from=cronjob/db-backup-daily manual-after-failover && k logs -f job/manual-after-failover` (same `k` function).
7. **Get redundancy back** (when `db1` is repaired or replaced): rebuild it as a replica of the new primary. The roles have swapped, so
   `REBUILD=1 scripts/db-replica-setup.sh db2 db1`. Update the layout table above. To make `db1` the primary again later, do a planned switchover.
   If `db1` is gone for good: `terraform apply -replace='module.node["db1"].openstack_compute_instance_v2.this'` (see the README for a stale-port
   409), then the command above.

## Planned switchover (maintenance, no data loss, about 25 seconds of failed writes)
Use when you want the other VM to be primary (patching, resizing, moving). Rehearsed on prod both ways on 2026-10-20 (below). From `db1` to `db2`:
1. `ssh db1 "sudo -u postgres psql -c \"alter system set default_transaction_read_only = on\" -c 'select pg_reload_conf()'"`
   The app now gets errors on writes only (reads still work). Do **not** scale the Deployments down: Argo's `selfHeal` would revert it.
2. `scripts/db-replication-status.sh db1 db2` until `behind: 0 bytes`.
3. Promote `db2` and repoint the secret/DNS exactly as steps 3 to 5 above. Write the `k` function first (zsh-safe, see step 4).
4. Rebuild `db1` as a replica of `db2`: `REBUILD=1 scripts/db-replica-setup.sh db2 db1` (this also clears the read-only setting, because the data
   directory is replaced).

## Rehearsal results (2026-10-20, live prod, app stayed at HTTP 200 throughout)
| Check | Result |
|---|---|
| Replica caught up after build | streaming, 0 bytes behind |
| Data identical | 85 tables, 118,302 rows, per-table counts identical on both |
| Live write on `db1` | appeared on `db2` within 2 s; a `DROP` replicated too |
| Write on the replica | refused (`read-only transaction`) |
| App user reaches `db2` | yes, from a backend pod (SG and `pg_hba` correct) |
| Promote `db2` | out of recovery in under 1 s |
| Writes on promoted `db2` | worked as `postgres` and as the app's user |
| `db1` while `db2` was promoted | untouched, still the only database the app used |
| Rebuild `db2` as a replica | `REBUILD=1` script, back to streaming, 0 bytes behind |
| **Planned switchover db1 -> db2** (read-only, wait for 0 lag, promote, edit `db-secret`, restart backend) | **26 s** from read-only to a restarted backend; app `/health` 200 throughout; app writes failed only in that window |
| App on `db2` as primary | pod connected to `10.0.1.69`, not in recovery, writes worked, 0 backend errors, a backup job dumped from it |
| `db` alias moved to `db2` (CLI) | c3 and the runner saw `192.168.2.135` within a minute; the Mac needed a cache flush |
| `db1` rebuilt as replica of `db2` | `REBUILD=1 scripts/db-replica-setup.sh db2 db1`; the read-only setting vanished with the old data directory |
| **Switch back db2 -> db1** | 23 s window; secret and alias back to `10.0.1.191` / `192.168.2.124`; `db2` rebuilt as replica |
| After both switchovers | 85 tables, 118,314 rows identical on both; backup job succeeded; 3/3 pods for every app; Argo Synced and Healthy |

## Unplanned outage test (2026-10-20, live prod)
`db1` was powered off abruptly (`sync` then `echo o > /proc/sysrq-trigger`: no Postgres shutdown, no read-only step) while a writer on it inserted a
numbered row about 5 times a second. Then the failover steps above were run, `db1` was powered on, rebuilt as a replica of `db2`, and the roles
were switched back with a planned switchover.

| Check | Result |
|---|---|
| Monitor noticed | alert at 10:23:01, about 80 s after the crash (it polls every 2 min, so 2 min is the worst case) |
| Promote `db2` | under 1 s |
| Secret edit + backend rollout + `db` alias | 27 s after the promotion; app on `db2` with 0 backend errors, writes OK, a backup job dumped from it |
| Time from crash to app on `db2` | 106 s in the test, of which about 75 s was my own wait (macOS `nc` needs ~75 s to give up on a dead host). Plan on **detection (up to 2 min) + you reacting + about 30 s of commands** |
| Data lost | **0 rows** (74 of 74 probe rows on `db2`). Best case: the crash was preceded by a `sync` and the write rate was low. A real crash can lose the last fraction of a second |
| `db1` after power-on | back in 18 s **as a second writable primary** (split brain). The monitor sent "TWO writable primaries". The app was unaffected because it connects by IP to `db2` |
| Recovery | `REBUILD=1 scripts/db-replica-setup.sh db2 db1` (wipes `db1`'s data), then a planned switchover back; monitor healthy, app 3/3 pods, Argo Synced |

Lessons that are now in the steps above:
- **`/health` does not check the database.** It returned 200 the whole time `db1` was down, so never use it to verify a failover. Use the
  pod check (`select inet_server_addr(), pg_is_in_recovery()` as the app's user) and a backup job.
- **A crashed primary boots writable.** After a failover keep the old primary **stopped** (`openstack server stop db1`; a `409 ... vm_state stopped`
  means it is already off) until you are ready to wipe it with the rebuild command. Anything that still writes to it creates data `db2` will never see.
- Before wiping the old primary, compare it with the new one if you need the last transactions:
  `select max(...)` on a table you care about, on both. Whatever only the old primary has can be dumped from it and replayed by hand.

## Multi-host connection string (tested, not adopted)
Both `asyncpg` 0.29 (the backend) and `libpq` (`psql`, `pg_dump`, so the backup jobs) accept a list of hosts with `target_session_attrs=read-write`
and pick whichever one is writable. Tested from a backend pod on 2026-10-20 with the replica listed first: both connected to the primary.
With `DATABASE_URL=postgresql://user:pass@10.0.1.191:5432,10.0.1.69:5432/financedb?target_session_attrs=read-write` a failover would need no secret
edit and no backend restart (the pool reconnects). Not adopted yet: it changes the production secret and has not been tested through an actual failover.
See `db-auto-failover-plan.md`.

## Host reboot (2026-10-20)
Both database VMs were stopped cleanly (replica first, then primary) before `c3` was rebooted, and started again primary first. Replication resumed on its own
(`streaming, behind: 0 bytes`), the app's database check passed and the monitor reported healthy. No action was needed on the database side. Procedure: `c3-reboot.md`.

## Troubleshooting
- **Replica not streaming:** `ssh db2 'journalctl -u postgresql@16-main -n 50 --no-pager'`. Typical causes: wrong or rotated password
  (re-run the setup script), the `replication` rule missing on the primary, the slot dropped, or WAL already removed (rebuild).
- **`pg_basebackup` fails with `directory ... exists but is not empty`:** the server was still running; the script stops
  `postgresql@16-main` itself. (`systemctl stop postgresql` alone returns before the instance has stopped.)
- **Disk filling on the primary:** `select slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) from pg_replication_slots`.
  A dead replica's slot is capped at 2 GB; drop it with `select pg_drop_replication_slot('slot_db2')` if the replica is gone.
- **`ssh db1` works but `ssh db` does not (or the reverse):** `db` follows DNS; check `dig +short db.rdulinux.com @192.168.2.2`.
- **`pg_hba.conf` full of repeated rules:** an earlier version of the setup script appended the primary's rules on every rebuild. It now adds only
  missing lines; the duplicates were removed on 2026-10-20 (backups next to the file: `pg_hba.conf.bak-20261020`).
- **cloud-init shows `error` on `db2`:** the known harmless `update-locale` message, not a failure.

## Removing the replica
`ssh db1 "sudo -u postgres psql -c \"select pg_drop_replication_slot('slot_db2')\""`, delete `db2` from `environments/prod/nodes.yaml`, apply, and
(optional) remove `/etc/postgresql/16/main/conf.d/20-replication.conf` and the `replicator` rule on `db1`.

## Not done (decisions for later)
- Automatic failover and an endpoint that follows the primary: a design plan with options, migration order, drills and the decisions needed is in
  `db-auto-failover-plan.md` (nothing built).
- Synchronous replication (no data loss, but writes stop if the replica is down).
- Alerting independent of the runner (a second watcher elsewhere), and disk-space checks on the two DB VMs.
- Reading from the replica (reports, the nightly backup) to take load off the primary. The backup jobs still dump from the primary.
