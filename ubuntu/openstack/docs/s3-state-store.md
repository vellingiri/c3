# The Terraform state store: RustFS on the `s3` VM (and the `backup` host that keeps its copies)

> **2026-11-19:** the store runs on the VM **`s3`** (`s3.rdulinux.com`, 192.168.2.98, role `objstore`, in `environments/prod/nodes.yaml`), started from `/opt/rustfs/compose.yaml`
> (docker compose; `RUSTFS_BIND_IP` is the VM's own address). It replaced the VM that was called `s3-prod` (192.168.2.99, deleted): the store was restored onto the new VM from the
> newest snapshot, compared object by object (709 entries identical), and all four backends, the backup jobs and the monitor were switched to `s3.rdulinux.com`.
> The compose file, image, keys and a rebuild kit are on the backup box in `/backup/rustfs-vm-config/`. Older sections below were written when the VM was called `s3-prod`;
> that name is now `s3`.
>
> The desktop machine at 192.168.2.4 that was the store before 2026-11-15 is **`backup`** (`backup.rdulinux.com`): it holds the hourly state snapshots, the whole-store pull of the VM,
> the router backups and the DR bundles. Its own old RustFS container is stopped.

## What runs
| Item | Value |
|---|---|
| S3 server | **RustFS 1.0.2** in a Docker container named `rustfs` (`restart: unless-stopped`), listens on `192.168.2.4:9000` (S3 API) and `192.168.2.4:80` (the web console, container port 9001). Plain HTTP, LAN only |
| Data | `/opt/rustfs/data` on the root file system (`/dev/sda2`, 98 GB, 9% used). Single node, single drive: no erasure coding, no replicas inside RustFS |
| Bucket | `terraform-state`, **versioning enabled** (every write keeps the previous state version; the `.tflock` lock objects also pile up versions, harmless). States: `openstack/infra`, `openstack/prod/nodes`, `openstack/qa/nodes`, `openstack/cka/nodes` (older `v2/...`, `nodes/...`, `infra/...` objects are history) |
| Credentials | custom access and secret keys (not the defaults). They live in the container's environment on `s3` and in your shell (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for Terraform); never in git |
| Health | `curl http://192.168.2.4:9000/health` returns 200; an unauthenticated bucket request returns 403 (proof it is up). The runner's `db-replication-monitor` checks the health URL and alerts on ntfy |
| Other roles of the host | NFS export `/backup` (787 GB partition `/dev/sda3`, used for the off-host copies); `/dev/sda4` (30 GB, mounted at `/terraform`) is empty and unused |
Terraform's backends use the address, not the name (`http://192.168.2.4:9000`), so the rename changed nothing for them.

## What was missing and what was done (2026-10-20)
| Finding | Action |
|---|---|
| **No backup of the states at all.** Versioning protects against a bad write, not against losing the disk, and every state of the lab is on that one disk | `scripts/s3-tfstate-backup.sh` (installed as `/usr/local/sbin/tfstate-backup`, hourly `tfstate-backup.timer`): copies every state to `/backup/terraform-state/<timestamp>/` (another partition), checks that each file is valid JSON with a `serial`, keeps a snapshot only when something changed (300 kept), `latest` symlink and `last-ok` marker. An hourly pull to `c3` (`tfstate-pull.timer`, at :35; it was daily until 2026-10-21) puts a copy on a different machine: `c3:/root/backups/terraform-state/`. Installed with `scripts/install-s3-tfstate-backup.sh` |
| Image tag `rustfs/rustfs:latest` (a recreate or pull could silently upgrade the server) | local tag **`rustfs/rustfs:1.0.2-pinned`** of the running image; `/opt/rustfs/recreate-rustfs.sh` (root only, contains the keys) recreates the container exactly as it runs now. Do not `docker pull` over it; upgrade deliberately (snapshot first) |
| No health check, no alert | the runner's monitor now checks `http://192.168.2.4:9000/health` (`S3_HEALTH_URL`) and says "the state store is not answering: Terraform cannot read or write its states" |
| Console on plain HTTP port 80 with CORS `*` | left as it is (LAN only, keys are strong). Option for later: disable it (`RUSTFS_CONSOLE_ENABLE=false` in the recreate script) if nobody uses the web UI |
| `/terraform` partition (30 GB) unused while RustFS data sits on the root file system | not moved (16 MB of data; moving it is risk for no gain). Option for later: bind `/opt/rustfs/data` on that partition to isolate the states from the root file system filling up |
Everything on the host that was changed has a backup next to it (`/root/hosts.bak-20261020`, `/root/hostname.bak-20261020`).

## If a state is damaged or lost
1. A bad write (wrong state): the bucket is versioned. List versions and fetch an older one with any S3 client, for example `aws --endpoint-url http://192.168.2.4:9000 s3api list-object-versions --bucket terraform-state --prefix openstack/prod/nodes/terraform.tfstate` then `get-object --version-id ...`, and put it back (`terraform state push` for a state, or `aws s3 cp`). Take a copy of the current one first.
2. The bucket is gone (disk failure): re-create RustFS (`/opt/rustfs/recreate-rustfs.sh` on a new host with the same keys, or build a new container), create the bucket `terraform-state`, **enable versioning**, and upload the newest snapshots (`/backup/terraform-state/latest/...` on `s3`, or `c3:/root/backups/terraform-state/latest/...`) to the same keys: `aws --endpoint-url http://192.168.2.4:9000 s3 sync /backup/terraform-state/latest/ s3://terraform-state/`. Then `terraform plan` in `infra` and each environment must show no changes.
3. No state at all for an environment: the VMs and networks still exist; `terraform import` each (`scripts/adopt-node.sh` was written for that) - last resort, hours of work.
Check any time: `ssh backup 'ls -l /backup/terraform-state/last-ok /backup/terraform-state/latest'` (should be less than an hour old) and `ssh c3 'ls /root/backups/terraform-state | tail -2'`.

## If the store itself is lost with the cloud
The store is on the `s3` VM, inside the cloud it describes. Recovery uses a temporary RustFS on the backup host, started with `scripts/s3-temp-store.sh` and reached by an `/etc/hosts` line for `s3.rdulinux.com`; the whole procedure is in `docs/c3-rebuild.md`, "When the state store is gone too". `scripts/s3-vm-restore.sh` and `install-s3-openwrt-backup.sh` now default to the host `backup` (the old name `s3` no longer resolves).

## Terraform lock trap
A killed or interrupted `terraform plan` leaves a lock (`terraform.tfstate.tflock`): "Error acquiring the state lock ... PreconditionFailed". If no Terraform is running anywhere, `terraform force-unlock <ID from the message>` (seen 2026-10-20).

## Old key prefixes (2026-11-07)
The bucket's live states are under `openstack/` (`infra`, `cka/nodes`, `prod/nodes`, `qa/nodes`). Before 17 October they were stored under top-level `infra/`, `nodes/` and `v2/`; those objects were deleted when the states moved, but versioning keeps their old versions. All three (`infra/`, `nodes/` and `v2/`, the first 72 prod versions built up on 17 October) were purged on 2026-11-07; the bucket now holds only `openstack/`. Remove such prefixes only through the S3 API with `scripts/s3-purge-state-prefix.py` (it refuses `openstack/...`, saves the state versions first and checks the live infra state afterwards), never by deleting files in `/opt/rustfs/data`. The hourly snapshot job only copies current objects, so it never included them. Copies of the purged states: `/backup/legacy-state-export/` on s3 (`infra-`, `nodes-` and `v2-` tarballs of 2026-11-07, 5 + 78 state versions; delete them when you are sure).

## Moving the state store to the `s3` VM (built 2026-11-15, not yet switched)

The desktop machine `s3` is a single point of failure for every Terraform state. A VM on `c3` now holds an identical copy, and the desktop machine goes back to being what its old name said: the backup box.

**State: SWITCHED on 2026-11-15** (see "Switched" below). Until then: `s3` (`s3.rdulinux.com`, floating IP 192.168.2.99, role `objstore`, flavor `m1.small-20g`, in `environments/prod/nodes.yaml`) runs the same RustFS image (1.0.2, image id `7e948dad4748`) on the same data, a copy taken 2026-11-15 and verified object by object and version by version (4 objects, 438 versions, identical ids and sizes). **Terraform still uses the old host** (`192.168.2.4:9000`): every backend is unchanged. Nothing was cut over, so nothing can be lost by it.

### What protects it (all in place)
| Layer | What | Where |
|---|---|---|
| Versioned bucket | every write keeps the previous version | on the VM |
| Whole-store pull, hourly at :20 | dated, hard-linked snapshots of `/opt/rustfs/data`, 200 kept, read-only key (`rrsync -ro /opt/rustfs`), nothing a mirror could delete | backup box: `/backup/rustfs-vm/<time>/`, `latest`, `last-ok`; `rustfs-vm-pull.timer` (`scripts/rustfs-vm-pull.sh`, `scripts/install-rustfs-vm-pull.sh`) |
| API-level state snapshots | every state as JSON, checked for a `serial` | `/backup/terraform-state/` on the backup box and the hourly pull to `c3:/root/backups/terraform-state/` (unchanged; see "Switching" for the keys) |
| Rebuild kit | the exact image and the settings (root only, they hold the keys) | backup box: `/backup/rustfs-vm-config/` |
| Pre-migration copy | the old store as it was before anything started | backup box `/backup/rustfs-premigration/` and `c3:/root/backups/rustfs-premigration/` (sha256 beside it) |

### Restore (rehearsed on 2026-11-15: a real restore into the VM, health 200, 4 state objects)
```bash
scripts/s3-vm-restore.sh --list                # snapshots on the backup box
scripts/s3-vm-restore.sh --dry-run
scripts/s3-vm-restore.sh                       # newest; or: scripts/s3-vm-restore.sh 20261115-133654
```
The current data is **moved aside** to `/opt/rustfs/data.before-restore-<time>`, never deleted, so a wrong choice is undone by moving it back. On a brand-new VM (a rebuild: `terraform apply -target='module.node["s3"]'`, then this script) the image and keys come from `/backup/rustfs-vm-config`. A restore of the pre-migration tarball into a scratch RustFS was also tried (4 state objects). Afterwards `terraform plan` in `infra` and every environment must show no changes.

### Switching Terraform to the VM (when you decide to)
1. No Terraform running anywhere. Compare: `scripts/s3-vm-migrate.sh --check` (it says `IDENTICAL`); if anything was written to the old store since the copy, re-copy with `ALLOW_OLD_TO_VM=1 scripts/s3-vm-migrate.sh --old-to-vm`.
2. Replace `http://192.168.2.4:9000` by `http://s3.rdulinux.com:9000` (the name, so a later move needs no code change) in `infra/backend.tf`, `environments/{prod,qa,cka}/backend.tf` and the `terraform_remote_state` block of `environments/{prod,qa,cka}/main.tf`; also `S3_HEALTH_URL` in `scripts/db-replication-monitor.sh` and the address in `scripts/c3-rebuild-all.sh`, `scripts/s3-purge-state-prefix.py` and `scripts/s3-tfstate-backup.sh`.
3. In `infra` and each environment: `terraform init -reconfigure`, then `terraform plan`. **Expect no change from the move itself** (see the drift note below).
4. On the backup box, `/etc/tfstate-backup.env` (root, 600) with `ENDPOINT=http://s3.rdulinux.com:9000`, `AK=...`, `SK=...` (the keys are the ones in `/backup/rustfs-vm-config/rustfs.env`); `tfstate-backup` then snapshots the VM's store, and `c3`'s pull keeps working unchanged.
5. Leave the old container running and unused for a week, then stop it (keep `/opt/rustfs/data`).
**Rollback** before step 5: put the old address back and `terraform init -reconfigure`. If a state was written to the VM after the switch, copy the VM's store back first: `scripts/s3-vm-migrate.sh --vm-to-old`, or use the snapshots as in "If a state is damaged or lost".

### Traps found while building it
- **`terraform plan` in `environments/prod` wants to power on every prod VM** while the environment is stopped (`power_state "shutoff" -> "active"` on all 10 stopped VMs). That is the stop being seen as drift, not a change anyone wrote. **Never apply a full plan while prod is stopped.** Add or change one VM with `-target`: `terraform plan -target='module.node["s3"]'` shows `6 to add, 0 to change`; check that line before applying. (`terraform apply -refresh-only` would accept the stop into the state if you prefer a clean plan.)
- **`scripts/env-vms.py` must never stop `s3`.** It stops every VM with `env=prod`, and an unknown role was ranked as a worker: a prod stop took the state store down seven minutes after the VM was created. Role `objstore` is now skipped (`NEVER_STOP_ROLES`); **every copy of the script must have this**, an older copy will stop it again. If it is stopped, `openstack server start s3` and Terraform works again.
- cloud-init needs `package_update: true` for `docker.io` on a fresh image; fixed in `cloud-init/objstore.yaml.tftpl`.

### Switched (2026-11-15)
Terraform now uses `http://s3.rdulinux.com:9000` in `infra`, `environments/{prod,qa,cka}` (backends and remote-state blocks), and so do `db-replication-monitor.sh` (`S3_HEALTH_URL`), `s3-purge-state-prefix.py` and `s3-tfstate-backup.sh`; `c3-rebuild-all.sh` checks RustFS on the VM and the new pull timer. Checked from `c3` with `terraform init -reconfigure` and `plan` in every stack against the VM: `infra` no changes; `prod` and `cka` only the power-state drift of stopped VMs, nothing about `s3`; `qa` plans to create its VMs because its state is an empty 317-byte object in both stores (as before the move; do not apply it). The state snapshot job on the backup box reads the VM through `/etc/tfstate-backup.env` (the previous script is kept as `/usr/local/sbin/tfstate-backup.before-vm-switch`).
**The old container on the desktop machine is still running and now unused** (its data is untouched, as of the switch). Stop it after a week (`docker stop rustfs` on `s3`; keep `/opt/rustfs/data`), delete nothing before then. The monitor on the runner VM only picks up the new URL when its copy of `db-replication-monitor.sh` is redeployed.

