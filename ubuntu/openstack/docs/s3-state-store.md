# The `s3` host: RustFS, where every Terraform state lives

Checked and hardened 2026-10-20. The machine formerly called `backup` is now **`s3`** (`s3.rdulinux.com`, 192.168.2.4; renamed the same day, `CHANGELOG.md`). It is a separate desktop machine, not a VM on `c3`.

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
Check any time: `ssh s3 'ls -l /backup/terraform-state/last-ok /backup/terraform-state/latest'` (should be less than an hour old) and `ssh c3 'ls /root/backups/terraform-state | tail -2'`.

## Terraform lock trap
A killed or interrupted `terraform plan` leaves a lock (`terraform.tfstate.tflock`): "Error acquiring the state lock ... PreconditionFailed". If no Terraform is running anywhere, `terraform force-unlock <ID from the message>` (seen 2026-10-20).
