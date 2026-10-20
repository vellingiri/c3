# Finance database: automatic failover with Patroni (runbook)

Built and drilled on live prod on 2026-10-20. Before this, a lost primary meant a human running `pg_promote` (see `db-replication.md`, now the
background document). Now **Patroni** on `db1` and `db2` decides who is primary, and promotes the replica by itself when the primary stops answering.

## What you have

| Piece | Where | Job |
|---|---|---|
| PostgreSQL 16 | `db1` (10.0.1.191), `db2` (10.0.1.69) | one primary (read-write), one streaming replica. **Run by Patroni**; `postgresql@16-main` is masked on both |
| Patroni 3.2.2 | `db1`, `db2` | keeps a leader key in etcd, promotes / demotes / re-attaches PostgreSQL. Config `/etc/patroni/config.yml` (root/postgres only, holds passwords) |
| etcd 3.4 (3 members) | `db1`, `db2`, **`db-witness`** (10.0.1.120, m1.tiny) | the shared notebook that says who is leader. Three voters means any single machine can be lost and the other two still agree |
| `db-witness` | prod VM, Terraform role `witness` | does nothing except run etcd (tie-breaker). Holds no data |
| App connection | `DATABASE_URL` lists both DB hosts with `target_session_attrs=read-write` | the app finds the writable one itself; no DNS change needed |
| `db.rdulinux.com` | still a DNS alias for the *original* primary | **not used by the app any more and not updated on failover**; do not rely on it |

Settings that matter: leader key TTL 30 s, loop 10 s, `maximum_lag_on_failover` 1 MB (a replica further behind is never promoted),
`failsafe_mode` on, `use_pg_rewind` on (an old primary rejoins as a replica by itself), replication **asynchronous**.

Security: etcd has no TLS or login, so an nftables table `etcd_guard` on each of the three hosts allows ports 2379/2380 only from the three members
and localhost, and Patroni's REST port 8008 only from 10.0.1.0/24 (writes need the `patroni` user/password from `config.yml`).

## Look at it (everyday)

On `db1` or `db2` (as root; the config file is found through `PATRONICTL_CONFIG_FILE` in `/etc/environment`):

```bash
ssh db1 patronictl list          # who is Leader, who is Replica, state, timeline (TL), lag
ssh db1 patronictl history       # every past failover / switchover
scripts/db-ha-etcd.sh status     # from the Mac: etcd members and health
scripts/db-ha-patroni.sh status  # from the Mac: Patroni on both nodes
```

Healthy is: one `Leader running`, one `Replica streaming`, `Lag in MB` 0, both on the same `TL`.
The runner's monitor (`db-replication-monitor`, every few minutes, alerts go to ntfy) checks all of that plus `db-witness` reachable and the
etcd view not stale. Patroni also sends an ntfy message on every role change (`/usr/local/bin/patroni-notify`).

## What happens by itself

| Event | Result |
|---|---|
| Primary VM crashes / powered off | after the 30 s lease runs out, the replica is promoted. Measured: **~40 s** to a new primary; the app has errors for ~36 s and then recovers **without a restart** |
| PostgreSQL process killed | Patroni restarts it, about 5 s |
| Old primary comes back | it sees it lost the lease, `pg_rewind`s and follows the new primary as a replica. Nobody has to do anything |
| `db-witness` lost | nothing visible (2 of 3 etcd voters remain). The monitor alerts |
| Network partition of the primary from the others | the primary demotes itself, the other side promotes. Measured: no split brain (85 samples), ~12 s of failed writes |

## Planned work

```bash
ssh db1 patronictl switchover --candidate db2 --force      # clean hand-over, ~15 s, about 1 s of failed writes
ssh db1 patronictl restart finance-db db1                  # restart PostgreSQL on one node (e.g. after a parameter change)
ssh db1 patronictl reload finance-db                       # re-read settings
ssh db1 patronictl pause                                   # no automatic failover while you work; ALWAYS follow with `resume`
ssh db1 patronictl resume
```

Never start/stop `postgresql@16-main` or run `pg_promote`/`db-replica-setup.sh` by hand on a Patroni node: Patroni would fight you.
Change PostgreSQL settings with `patronictl edit-config` (cluster-wide, stored in etcd), not by editing files.

## Problems and what to do

| Symptom | Do |
|---|---|
| Replica `stopped` / lagging after a long outage | `ssh db1 patronictl reinit finance-db <replica>` rebuilds it from the leader (data copy; the app is not affected) |
| No leader, both nodes say "demoted" / "failsafe" | etcd lost quorum (two of three voters down, usually `db-witness` **and** one DB). Bring the missing VM back first (`openstack server start`); Patroni recovers on its own. Do not promote by hand |
| Need to force a failover while the leader is alive | `patronictl failover finance-db --candidate db2 --force` |
| App returns 503 "service busy" for more than ~1 minute after a failover | check `patronictl list` first. If a leader exists, restart the backend pods: `kubectl -n finance rollout restart deploy/backend` (prod kubeconfig) |
| Monitor says "Patroni on dbX is not answering" | `ssh dbX systemctl status patroni`, `journalctl -u patroni -n 50` |
| Replace a failed DB node | create the VM from Terraform, install etcd/Patroni with `scripts/db-ha-patroni.sh prepare`, remove the dead member (`etcdctl member remove`), add the new one, then `patronictl reinit` |
| Replace the witness | create a new `witness` VM, `etcdctl member remove <old id>` / `member add`, start etcd with `ETCD_INITIAL_CLUSTER_STATE=existing` (scripts/db-ha-etcd.sh is for first install only and refuses to run over an existing cluster) |
| Go back to plain PostgreSQL | `scripts/db-ha-patroni.sh rollback` (read it first; it stops Patroni, unmasks `postgresql@16-main`, restores the Debian config copies in `/root/db-ha-backup-20261020`) |

## The limits you accepted

- **Replication is asynchronous.** In a hard failure the last moments of writes (up to the 1 MB lag guard; in a partition up to ~20 s) can be lost.
  Synchronous mode (`synchronous_mode: true`) would remove that at the price of writes stalling whenever the replica is unreachable; not chosen.
- **Two machines lost at once** (witness plus one DB) means no majority: no automatic failover, and the surviving DB demotes. Fix by bringing a VM back.
- **Memory:** after the witness VM, Nova has only ~1.1 GB headroom. A two-amphora rebuild of `finance-lb` needs ~4 GB. Raising `ram_allocation_ratio`
  from 1.1 to 1.2 is possible but not done (your decision).
- The monitor cannot ask etcd directly (firewall); it uses Patroni's `dcs_last_seen` and a TCP check of the witness.

## Application side (why the app survives a failover)

Found in the first crash drill: asyncpg gives all hosts of a multi-host URL **one** shared timeout, so a powered-off first host used it up and the
promoted replica was never tried (every request returned 503 until the old primary was started again). Fixed in the finance repo (deployed `sha-aa0101f`):

- `db_connect.py`: tries hosts one at a time, 3 s each (`DB_CONNECT_TIMEOUT`), starting with the host that worked last; `FailoverPool` routes every new pool connection through it. `pg_dump` gets `connect_timeout=5` (`DB_LIBPQ_CONNECT_TIMEOUT`).
- `DB_COMMAND_TIMEOUT` (30 s): a query on a dead socket fails instead of hanging.
- `leader_watchdog.py`: the pod that holds the scheduler's advisory lock probes it every 10 s and exits if the connection is lost, so another pod takes over and two schedulers never run.
- Tests: `tests/test_db_connect.py`, `tests/test_leader_watchdog.py`. Probe used in drills: `scripts/db-pool-probe.py` (in the finance repo; `kubectl exec -i deploy/backend -- python - < scripts/db-pool-probe.py`).

## Drill results (2026-10-20, live prod)

| # | Drill | Result |
|---|---|---|
| 1 | Planned switchover | 14–16 s, 1 failed second for the app |
| 2 | Kill the PostgreSQL process on the primary | Patroni restarted it in ~5 s |
| 3 | Primary VM powered off (sysrq) | new primary after ~40 s; app errors ~36 s then self-recovered; no data loss; old primary rejoined as replica after `openstack server start` (first attempt failed the app side, fixed as above, then repeated and passed) |
| 4 | Network partition of the primary (nft `drill_partition`) | no split brain in 85 samples; ~12 s of failed writes. (The first run was invalid, the rule had a syntax error; it was redone and the block verified before measuring.) |
| 5 | `db-witness` powered off | no effect on the app; switchover still worked with 2 of 3 etcd members; the monitor alerted |

Final state after the drills: `db1` Leader, `db2` Replica, TL 14, 3 of 3 etcd healthy.

## How it was adopted (for the record)

The existing data was not rebuilt. Per node: set the `postgres` superuser password (Patroni connects over TCP), stop plain PostgreSQL, mask `postgresql@16-main`,
start Patroni, which starts the existing data directory (as standby first, then promotes with a timeline bump). `db1` first (about 2 s of failed writes), then `db2`
(Patroni then creates its own replication slot; it drops slots it does not manage, which is why `db2` could not stream between the two steps).
Rehearsed on a scratch cluster first; lessons are in the header of `scripts/db-ha-patroni.sh`:
`custom_conf` must point at a copy of the original Debian config (`postgresql.base.conf`, otherwise Patroni overwrites `postgresql.conf` and PostgreSQL recurses), and the `postgres` password must exist before the first start.

Scripts: `scripts/db-ha-etcd.sh` (install/status), `scripts/db-ha-patroni.sh` (prepare, adopt-primary, adopt-replica, status, notify, rollback), `scripts/db-replication-monitor.sh`.
Terraform: role `witness` (`modules/node`, `cloud-init/witness.yaml.tftpl`), VM `db-witness` in `environments/prod/nodes.yaml`.

## Built by Terraform (no manual work for a new or replaced node)

Everything on the VMs is now produced by cloud-init from Terraform: `cloud-init/db-ha.yaml.tftpl` + `cloud-init/files/db-ha-node.sh` (etcd, nftables guard,
`/etc/patroni/config.yml` with pg_hba, patroni-notify, `PATRONICTL_CONFIG_FILE` and the root `patronictl` config link, Patroni service).
The script decides by what answers: a running etcd cluster is **joined** (a stale entry for the same name/address is removed first), otherwise a new one is formed;
Patroni with an empty data directory **copies the leader** (or, if no cluster exists, one node initialises an empty database and the other copies it).
`ip:` in `environments/prod/nodes.yaml` pins the three addresses. The passwords are Terraform variables from `environments/prod/secrets.auto.tfvars`
(git-ignored; create it once with `scripts/db-ha-secrets.sh`, which reuses the live cluster's values).

Replace a lost or broken database VM: `terraform apply -replace='module.node["db2"].openstack_compute_instance_v2.this'` (in `environments/prod`). Nothing else.
Watch with `patronictl list`; the new member shows `creating replica`, then `streaming`. After a from-scratch rebuild of **both** database VMs the cluster is empty:
restore the data (`finance-db-restore.md`, roles `financeapp` and `monitor` included).

Existing VMs are untouched (user data is ignored after first boot); `scripts/db-ha-etcd.sh` and `db-ha-patroni.sh` are the record of how they were adopted.
Status: written 2026-10-20, **not yet proven on a real replacement**; the first test is replacing `db-witness`, then `db2`.
Still outside Terraform: the monitor copy on the runner (`scripts/install-db-monitor.sh`).
