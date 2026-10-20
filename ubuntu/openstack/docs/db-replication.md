# Finance database: primary `db1` and streaming replica `db2`

Built and rehearsed 2026-10-20. PostgreSQL 16.15 (Ubuntu packages) on both VMs.

## What this gives you, and what it does not
- **Gives you:** a second, continuously updated copy of the database on another VM. If `db1` is lost, `db2` can be promoted in
  seconds and the app pointed at it (about 5 minutes of work, steps below). It also gives you a place to run heavy read queries.
- **Does not give you:**
  - **Automatic failover.** Promotion and repointing are manual on purpose; there is no Patroni/repmgr.
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
```bash
scripts/db-replication-status.sh db1 db2        # read-only; exit code 0 = streaming and under 1 MB behind
```
Healthy output: `streaming | async | 0` in the walsender line, the slot `active` with a few bytes retained, `in recovery: t` on the replica.
Nothing alerts on this yet; run it after any change to either VM, and consider a timer that pages on a non-zero exit code.
Things that break it: the replica VM is down (the slot then keeps WAL on the primary, capped at 2 GB; beyond that the replica must be rebuilt),
a changed `pg_hba.conf`, a different Postgres major version on the two hosts (never mix them), a full disk.

## Failover: the primary (db1) is lost
The goal is one writable primary. **Never leave both writable** (split brain).
1. **Confirm and fence.** Make sure `db1` is really gone, then stop it so it cannot come back writing:
   `ssh c3 'openstack server stop db1'` (or leave it if it is already off). If it is just unreachable, stop it anyway.
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

Not tested: a real, unplanned loss of `db1` (VM off or unreachable) with `db2` promoted without a read-only step. The promotion and repointing
commands are the same ones proven above; what differs is that the last few transactions may be missing (step 2 of the failover shows how many).

## Troubleshooting
- **Replica not streaming:** `ssh db2 'journalctl -u postgresql@16-main -n 50 --no-pager'`. Typical causes: wrong or rotated password
  (re-run the setup script), the `replication` rule missing on the primary, the slot dropped, or WAL already removed (rebuild).
- **`pg_basebackup` fails with `directory ... exists but is not empty`:** the server was still running; the script stops
  `postgresql@16-main` itself. (`systemctl stop postgresql` alone returns before the instance has stopped.)
- **Disk filling on the primary:** `select slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) from pg_replication_slots`.
  A dead replica's slot is capped at 2 GB; drop it with `select pg_drop_replication_slot('slot_db2')` if the replica is gone.
- **`ssh db1` works but `ssh db` does not (or the reverse):** `db` follows DNS; check `dig +short db.rdulinux.com @192.168.2.2`.
- **cloud-init shows `error` on `db2`:** the known harmless `update-locale` message, not a failure.

## Removing the replica
`ssh db1 "sudo -u postgres psql -c \"select pg_drop_replication_slot('slot_db2')\""`, delete `db2` from `environments/prod/nodes.yaml`, apply, and
(optional) remove `/etc/postgresql/16/main/conf.d/20-replication.conf` and the `replicator` rule on `db1`.

## Not done (decisions for later)
- Automatic failover (Patroni or repmgr with a witness) and a virtual IP so the app never needs its secret edited.
- Synchronous replication (no data loss, but writes stop if the replica is down).
- Alerting on replication lag or a stopped replica.
- Reading from the replica (reports, the nightly backup) to take load off the primary. The backup jobs still dump from the primary.
