# Rebuilding `c3` from nothing (disaster recovery)

If the machine `c3` is lost (disk failure, fire, a bad upgrade), everything in this lab goes with it: the OpenStack cloud, every VM, both Kubernetes clusters, the database pair, the load balancers.
This page and the scripts in `scripts/c3-dr/` are how to get all of it back on a new machine of the same kind. Written 2026-10-21. **Read "Test status" first.**

The platform was originally built by following Server World's *OpenStack Epoxy on Debian 13* series ([overview](https://www.server-world.info/en/note?os=Debian_13&p=openstack_epoxy&f=1);
Keystone, Glance, Nova, Neutron with OVN, Horizon, Designate, Octavia), with Apache instead of nginx in front of Keystone. The rebuild does not retype those steps: it **puts back the configuration that is
captured every night** and re-creates what is not configuration (databases that can be rebuilt, VMs, networks) from Terraform.

## What is covered, and how it comes back
| On `c3` (or depending on it) | How it is restored |
|---|---|
| Debian 13, kernel, hostname `c3.rdulinux.com`, the package set (OpenStack Epoxy from Debian packages) | fresh minimal Debian 13 + `c3-dr-install.sh` phase 1 (explicit package list; Cinder is not reinstalled: disabled since August, removed from the catalog 2026-10-20) |
| Host network: bridge `br0` (192.168.2.2/24, gateway 192.168.2.1, DNS = itself), route `10.0.1.0/24 via 192.168.2.174` (`c3-host-route.md`), IPv6 off, second NIC `enp4s0` as the OVS provider bridge `br-enp4s0` (`physnet1`) | `/etc/network/interfaces`, `sysctl.d` from the bundle (phase 3); the OVS bridge and the OVN chassis settings (`ovn-remote`, `ovn-encap-ip`, `ovn-encap-type`, `ovn-bridge-mappings`, `ovn-cms-options`) from `ref/ovs-external-ids.txt` (phase 5) |
| MariaDB (`max_connections`, bind address), RabbitMQ (user `openstack`), Memcached | configs from `/etc`; DB users **with their password hashes** from `db/users.sql`; RabbitMQ users from `rabbitmq-definitions.json` (phase 2) |
| **Keystone** (users, projects, roles, service catalog, endpoints, Fernet and credential keys) | **database dump restored** + `/etc/keystone` (keys) (phases 2, 4): all passwords, the `admin` login and every service user come back unchanged |
| **Glance** (images: `ubuntu2404`, `debian13`, the patched amphora image `Amphora-netns-fix-v2-20261020` carrying the tag `Amphora`, two older amphora images) | **database dump + the image files** mirrored on `s3` (phase 4): same image ids, so Terraform's image state stays valid |
| Placement, Nova (api, conductor, scheduler, compute, VNC/serial proxies), Neutron (ML2/OVN, DHCP agent, OVN metadata agent), Open vSwitch + OVN central/host | packages + the captured `/etc` configs (RAM ratio 1.7, disk ratio 2.5, `resume_guests_state_on_host_boot`, the `nova-compute` and `libvirt-guests` systemd drop-ins that fix reboots, ...); databases created empty and migrated (`db sync`); flavors `m1.tiny/small/medium/large` and the private `m1.octavia` (id 100) created (phases 4 to 6) |
| libvirt/QEMU (`libvirt-guests` shutdown settings) | `/etc/libvirt`, `/etc/default/libvirt-guests`, drop-ins (phase 3) |
| Designate + BIND (zones `rdulinux.com.`, `prod.`, `qa.`, `cka.`), pool `default` via `pools.yaml`, `rndc` keys | `/etc/designate`, `/etc/bind` (incl. keys); the zones and records themselves are recreated by `terraform apply` in `infra/` (they are declared in `infra.yaml`) |
| Octavia (API, health manager `heartbeat_timeout = 300`, housekeeping, worker, the CA and client certificates, `amp_*` settings) | `/etc/octavia` incl. `certs/`; the two ids that change (external network, amphora security group) are patched in by `c3-dr-post.sh octavia`; flavor profile `active-standby` and flavor `ha` recreated |
| Horizon (dashboard) | Apache config, `local_settings.py`, `/var/lib/openstack-dashboard` (secret key) |
| Local software: `ovn-vip-binding` (OVN router stale-MAC fix, `amphora-reboot-fix.md`), `k8s-api-lb` (API load balancer members), `tfstate-pull` (state snapshots from `s3`), their timers and credentials file | `/usr/local/sbin` + `/etc/systemd/system` + `/etc/default` from the bundle (phases 3, 7) |
| NFS export and Samba share of `/share` (25 GB partition, the finance app tree incl. `.git`), `nmbd` fix | `/etc/exports`, `/etc/samba`, `/var/lib/samba` (users), the data from `s3:/backup/c3-dr/share/` (phase 7); the partition itself is made by hand (below) |
| root's crontab: hourly/daily/weekly/monthly pull of the website data from the Contabo server into `/nfsshare/backups/rdulinux.com` (scripts live on the NFS share of `repo`) | `cron/root.crontab`, `/root/.ssh` keys, the `/nfsshare` mount from `/etc/fstab` (phase 3c, 7) |
| `/root` (admin credentials in `.bashrc`, the Octavia work dir, `amphora-fix` scripts, the router config is no longer kept here: daily backups on `s3:/backup/openwrt/` (`docs/openwrt-router.md`), `firewall`) | `root.tgz`; the large amphora `.qcow2` files are mirrored on `s3` separately |
| **Networks, router, security groups, key pair, DNS zones** | `terraform apply` in `infra/` (state is on `s3`, hourly snapshots) |
| **All VMs**: prod, qa, cka clusters, `db1` `db2` `dbw1-3`, `runner` | `terraform apply` in each environment; the database pair, etcd, Kubernetes control planes and workers **build themselves from cloud-init** (`db-ha-patroni.md`, `k8s-ha-control-plane.md`) |
| **Load balancers** `finance-lb` (.5), `argo-lb` (.113), `prod-api` (.61), `cka-api` (.75) | `c3-dr-post.sh api-lbs` / `app-lbs`: same flavor, listeners, pools, health monitors and floating IPs as before |
| Application data and the app layer in Kubernetes | see "Applications" below: this is the part that depends on other backups |

**Not on `c3`, but needed**: the `repo` host (192.168.2.3: NFS `/nfsshare` with the `qcow2` image sources, the finance backups and etcd snapshots), the `s3` host (192.168.2.4: Terraform states, the DR bundles), the router at 192.168.2.1 (config tarballs are in `/root`), your Mac (`~/.ssh/id_ed25519.pub` is the key pair Terraform uploads), GitHub, the Contabo server.

## What is lost (recovery point)
| Data | Lost? | Comes back from |
|---|---|---|
| VM disks (`/var/lib/nova/instances`, 70 GB) | **yes, all of them** | the VMs are rebuilt; data from the items below |
| Finance database (PostgreSQL on `db1`/`db2`) | the live copy | hourly and daily `pg_dump` on the NFS share (`finance-db-restore.md`): **up to one hour of changes lost**. The replica is on the same host and does not help |
| Kubernetes state (etcd) | yes | the app is declared in git and deployed by Argo CD; etcd snapshots on NFS (`etcd-restore-rehearsal.md`) are a fallback; secrets not in git must be recreated (see below) |
| Uploads/logs/backups of the app | no | NFS on `repo` |
| Terraform states, DR bundle, `/share` copy | no | `s3` (and states also on `c3`, which is gone: so keep the `s3` copy safe) |
| OVN databases, Nova/Neutron/Octavia/Designate/Placement databases | yes | rebuilt from Terraform and the scripts |

## Keep it ready (do this before you need it)
- The capture runs on `c3` every night once installed: `scripts/install-c3-dr-capture.sh` (**not installed yet**; installing it adds a timer on `c3`). Check: `ssh s3 'ls -l /backup/c3-dr/bundles/latest/ && cat /backup/c3-dr/bundles/latest/MANIFEST | head -5'` should be less than a day old. `scripts/c3-dr/c3-dr-capture.sh --dry-run` shows what it would take without writing anything.
- The bundle holds secrets (service passwords, Fernet keys, CA key, ssh keys): it lives only in `/root/dr-staging` on `c3` and root-only on `s3`. Treat the `s3` host like the key safe.
- Know the hardware: NIC names `enp3s0` (LAN, bridged into `br0`) and `enp4s0` (provider network), VT-x on, IOMMU. The disk layout of the old host: `nvme0n1p1` 139.7 GB `/` (ext4, also holds `/var/lib/nova`), `p2` 4.7 GB EFI, `p3` 25 GB `/share` (ext4); about 760 GB of the 931 GB NVMe were unpartitioned. A new machine should have **at least 200 GB for `/`** (VM disks grow) and a 25 GB `/share`.

## Rebuild, step by step
**0. The machine.** Install Debian 13 (minimal + ssh server; no desktop), root login by ssh, a temporary IP in 192.168.2.0/24 (the static `br0` config is applied at the first reboot after step 2). Create `/share` (ext4) and mount it at `/share`. Make sure `enp3s0` and `enp4s0` exist (otherwise `export NIC_LAN=... NIC_EXT=...`).
**1. Bring the bundle and the repo** (from your Mac, which can reach both):
```bash
rsync -a s3:/backup/c3-dr/ root@NEWHOST:/root/c3-dr/        # bundles/ images/ share/   (images are 4 GB)
rsync -a /opt/c3/ root@NEWHOST:/opt/c3/                      # this repository (or git clone it on the host)
```
**2. Install the platform** (on the new host; every phase can be repeated, `--dry-run` prints instead of doing):
```bash
cd /opt/c3/ubuntu/openstack/scripts/c3-dr
./c3-dr-install.sh --bundle /root/c3-dr/bundles/latest --dry-run          # read what it will do
./c3-dr-install.sh --bundle /root/c3-dr/bundles/latest                     # phases 0 to 8, asks you to type 'rebuild'
```
Read the **phase 3b audit** (entries of the old `/etc` that were not restored: should be nothing of substance) and the **phase 8 checks** (all must say `ok`). Then `reboot` (network files, OVS bridge).
**3. Terraform `infra`** (from your Mac): `cd infra && terraform apply`. The plan will show networks, router, security group, key pair, DNS zones as **created** (they are gone from Neutron/Designate) and the images **unchanged**. If Terraform complains about stale objects in its state, `terraform apply -refresh-only` first.
**4. Octavia and the API load balancers** (on `c3`): `./c3-dr-post.sh octavia` then `./c3-dr-post.sh api-lbs`.
**5. Environments** (Mac), in this order: `environments/prod`, then `cka`, then `qa` (`terraform apply` each; if the first apply of a VM stops on "IP already allocated" or a port conflict, apply again). The control planes initialise through the API load balancers (the reconciler adds them), the database pair forms with an **empty** database, the witnesses join etcd.
**6. Application load balancers** (on `c3`, once the prod workers are `ACTIVE`): `./c3-dr-post.sh app-lbs` (finance-lb .5, argo-lb .113). `./c3-dr-post.sh check` shows both front doors.
**7. Applications** (below). **8. Re-install the nightly capture and the monitors** (`scripts/install-c3-dr-capture.sh`, `scripts/install-ovn-vip-reconciler.sh` is already restored; the runner's monitor: `scripts/install-db-monitor.sh`).

## Applications (the part that is not just "restore the config")
1. **Finance database:** on the Patroni leader restore the newest dump from the NFS share, exactly as in `finance-db-restore.md` ("Restoring for real"; that procedure was verified on a scratch database, not yet as a whole-cluster rebuild). Then check the roles `financeapp`, `monitor` and the app's tables.
2. **Kubernetes prod:** the cluster is built by cloud-init. The app layer is scripted since 2026-10-22: from the finance repo, `KUBECONFIG=~/.kube/prod KCTX=prod k8s/bootstrap.sh` (`--check` first: read-only, shows what exists). It creates the namespaces, the secrets that are not in git (`db-secret` with `DATABASE_URL` listing both database hosts, `app-secret`, `ghcr-secret`, `argocd/finance-repo-creds`; values from `DB_PASSWORD`, `GHCR_TOKEN`, `GH_TOKEN` or asked silently), installs Argo CD v3.5.1 in plain-HTTP mode on NodePort 30443 (what `argo-lb` targets), registers the `finance-qa` Application, which then creates the NFS PVs, the app and the backup CronJobs from git, and waits for Synced/Healthy and the front door. Tested read-only against the live prod cluster (all steps reported "exists"); **not yet run on an empty cluster**. Not covered: `ingress-nginx` (prod uses the nginx NodePort 30080, not an ingress), the database restore (item 1), the runner (item 3). `prod-k8s-rebuild.md` records the manual 2026-10-19 rebuild.
3. **GitHub runner** (`runner` VM): needs a new registration token from GitHub (a manual step), then `finance repo: scripts/setup-github-runner-service.sh`; copy the new prod kubeconfig to `/home/runner/.kube/config`.
4. **Your Mac:** `~/.kube/prod`, `~/.kube/qa`, `~/.kube/cka` (the CAs are new), `~/.ssh/known_hosts`, `~/.ssh/config` pins for `dbw1` and `s3` if their addresses changed.
5. Checks: both front doors 200 (`./c3-dr-post.sh check`), `patronictl list`, `kubectl get nodes` on each cluster, the replication monitor, `ssh s3 ls /backup/terraform-state/last-ok`.

## Test status (read this)
Verified now (2026-10-21, no change was made to `c3`): the capture script's `--dry-run` runs on the live host and reports sizes (about 100 MB of configuration and databases, 4 GB of images, 750 MB of `/share`); the post script's `check` and its server/controller lookups return the live values; the installer's `/etc` audit and OVS-setting parser were run against the real contents of `/etc` and the real OVS settings (only `supercat` is unclassified); all scripts pass `bash -n`.
**Not yet verified: the installer on a blank machine.** It has never been run end to end. The likeliest problems are the ones a first run always meets: a debconf question the preseed list does not cover, a package starting with a default configuration, a Debian package name that differs, an `/etc` file that should have been in the restore list. Phases are re-runnable and print what they do, so a failure is a stop, not damage; but **rehearse it before you depend on it**: for example on a spare machine or a large VM (the `s3` host has 15 GB RAM and a 800 GB disk), capture a bundle first (`c3-dr-capture.sh --no-push`, copy it) and run phases 0 to 8, then delete everything. Nothing in the rehearsal touches `c3`.
Other limits: the Kubernetes app layer script (`k8s/bootstrap.sh`) has not run on an empty cluster; Cinder is not reinstalled; VM data is only as fresh as the hourly dumps.

## Files
`scripts/c3-dr/c3-dr-capture.sh` (nightly capture, `--dry-run`), `scripts/c3-dr/c3-dr-install.sh` (platform, phases 0 to 8), `scripts/c3-dr/c3-dr-post.sh` (Octavia, load balancers, check),
`scripts/install-c3-dr-capture.sh` (the timer), `scripts/octavia-k8s-api-lb.sh` and `scripts/octavia-argo-lb-ha.sh` (load balancer builders; `FIP=` pins the floating IP).
