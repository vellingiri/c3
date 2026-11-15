# `c3-rebuild-all.sh`: one script for the whole of c3, and the audit of 2026-11-15

`scripts/c3-rebuild-all.sh` audits `c3` or builds it from nothing, in the order of `docs/c3-rebuild.md`, with a **dry run by default** and a log of every step. It does not replace the pieces that already existed (`scripts/c3-dr/c3-dr-install.sh`, `c3-dr-post.sh`, `c3-dr-capture.sh`, the Terraform folders, `k8s/bootstrap.sh`); it **runs them in the right order, checks each result, and adds everything that was changed since they were written** (settings, timers, flavors, the disk layout, the backup and router backups). Written 2026-11-15.

## How to run it
On c3, as root, from a checkout of this repository (on c3 today: `/nfsshare/c3/ubuntu/openstack`, a plain copy):
```bash
cd /nfsshare/c3/ubuntu/openstack/scripts
./c3-rebuild-all.sh                         # DRY RUN (default): changes nothing, prints OK / DRIFT / WARN / SKIP / WOULD
./c3-rebuild-all.sh --only layout,tuning    # some stages (names below); also --from STAGE and --skip a,b; --list shows the stages
./c3-rebuild-all.sh --apply --bundle /root/c3-dr/bundles/latest     # really does it; asks you to type 'rebuild' (--yes skips); stops at the first FAIL (--keep-going)
```
Options: `--tf-repo DIR` (where the Terraform code and `secrets.auto.tfvars` are), `--finance-repo DIR`, `--nova-dev /dev/nvme0n1pN` (a partition you made, to mount at `/var/lib/nova`), `--reinstall` (let the platform installer run over an existing OpenStack), `--offline-cpus` (keep CPUs 8-9 offline), `--install-capture` (the nightly capture timer), `--restore-router`, `--log-dir`.

## Stages
| Stage | Checks (dry run) | `--apply` does |
|---|---|---|
| `preflight` | root, Debian 13, CPU/RAM, VT-x, NICs, BIOS `A.C0`, ping of repo/s3/router, DNS, tools, `AWS_*` keys, the bundle's checksums | asks for `rebuild` |
| `layout` | `/var/lib/nova` on its own partition, `/share`, `/nfsshare`, kernels N and N-1, Wi-Fi absent, time, timezone, IPv6 sysctl, `br0` | mounts a partition given with `--nova-dev`, sets the timezone. **Never partitions a disk** (it prints how) |
| `platform` | the 35 services, the 9 databases, the 7 catalog endpoints, Nova/Neutron agents, the images and the single `Amphora` tag | `c3-dr-install.sh` (phases 0 to 8) **only if OpenStack is not installed** (or `--reinstall`) |
| `tuning` | `nova.conf` (RAM 1.2, disk 2.5, resize on the same host, resume guests), `octavia.conf` (heartbeat 300, threshold 2, amp flavor/tag), `libvirt-guests`, the two systemd drop-ins, OVN settings, NFS/Samba, the three timers and two reconcilers, **8 flavors** (`m1.octavia` id 100 is private), the Octavia flavor `ha` | sets what differs (crudini), creates missing flavors, restarts nova/octavia once at the end |
| `tf-infra`, `tf-prod`, `tf-cka` | `terraform plan -lock=false` (nothing written, no lock); only resource lines kept in the log | `terraform apply` (twice if the first stops on an address conflict) |
| `octavia`, `api-lbs`, `app-lbs` | amp security group and network ids in `octavia.conf`, the four load balancers and their floating IPs | `c3-dr-post.sh octavia / api-lbs / app-lbs` |
| `apps` | `k8s/bootstrap.sh --check` (needs `--finance-repo` and `~/.kube/prod`) | `k8s/bootstrap.sh` |
| `backup-host` | the backup timers, age of the last runs, free space (the stage was `backup` until 2026-11-15; `--only backup` still works) | installs the timers if missing |
| `router` | DHCP pool, timezone, rebind domain (needs a key for `root@192.168.2.1`) | restore from backup only with `--restore-router` (reboots the router) |
| `backups` | state pull to c3, a capture bundle exists, the capture timer | the capture timer with `--install-capture` |
| `verify` | services, Nova, VMs per environment, load balancers, front doors, kernel oops since boot | nothing |

Not automated, on purpose: partitioning, BIOS settings (Intel default settings, Wi-Fi off, no XMP, VT-x/VT-d), the GitHub runner token, the finance database restore (`docs/finance-db-restore.md`), the kubeconfigs on your Mac.

## Logging
Every line goes to the screen **and** to `LOG_DIR/c3-rebuild-<dry|apply>-<time>.log` (default `/var/log/c3-rebuild`), with the time and a level: `INFO`, ` OK `, `DRIFT` (differs from the target; `--apply` fixes it), `WARN` (look, not necessarily wrong), `SKIP`, `WOULD` (the command a dry run would run), ` DO ` (a command that really ran; its output follows, prefixed `|`), `FAIL`, `STOP`. Next to the log: `...summary.tsv` (time, stage, level, text, one row per check) and `plan-<stage>-<time>.txt` (the Terraform resource lines, never the values). The end of every run prints counts and the list of things to look at. Exit code 0 = no FAIL, 1 = a FAIL or a cancelled confirmation. A dry run writes nothing but these files.

## Audit of c3 (2026-11-15, read-only)
Evidence: `docs/logs/c3-rebuild-all-dry-run-2026-11-15.log` (100 checks OK, 4 DRIFT, 9 WARN, 0 FAIL).

| Area | State |
|---|---|
| Hardware / OS | Debian 13 on an i9-14900K, 80 GB RAM, MSI BIOS `A.C0` (7E25vAC), microcode `0x137`, kernel `6.12.113` (N) with `6.12.95` (N-1), up 16 h, all 32 threads online, `c3-offline-cpus.service` installed but disabled (owner's choice, see `c3-hardware-instability.md`), Wi-Fi off in the BIOS |
| Storage | NVMe 931 GB: `/` 139.7 GB, `/boot/efi`, `/share` 25 GB, **`/var/lib/nova` 550 GB on its own partition (UUID in fstab)**, `/nfsshare` from the repo host |
| Platform | 35 services active; keystone masked (served by Apache), placement served by Apache; databases `designate glance keystone neutron_ml2 nova nova_api nova_cell0 octavia placement` (plus the old `cinder`); 7 endpoints (no Cinder); 5 images with one `Amphora`; 3 Nova services up |
| Settings changed since the install | all present and equal to the target (nova ratios 1.2 / 2.5, resize on the same host, resume guests, Octavia heartbeat 300, libvirt-guests, both drop-ins, OVN encap/mappings, exports, Samba) |
| OpenStack objects | 8 flavors (4 `m1.*`, private `m1.octavia`, `k8s.worker`, `m1.small-20g`, `m1.medium-20g`); Octavia profile `active-standby` / flavor `ha`; 4 load balancers (floating IPs .5 .113 .61 .75 attached); 18 floating IPs; 5 DNS zones, 25 records; 14 VMs (10 prod, 4 cka), **all SHUTOFF** at the time (a maintenance stop) |
| Local software | timers `ovn-vip-binding`, `k8s-api-lb`, `tfstate-pull` enabled and running; reconcilers in `/usr/local/sbin`; root crontab with the four website-data pulls |
| Backups | state snapshots on backup (job ran 33 min before) and pulled to c3; router backup 9 h before; free space on backup 747 GB |

### Findings
1. **No capture bundle exists and the nightly capture is not installed (the real gap).** `/root/dr-staging` does not exist and `backup:/backup/c3-dr` has no bundle. Everything in `c3-dr-install.sh` restores from a bundle, so **c3 cannot be rebuilt today**, only audited. Fix: `./c3-rebuild-all.sh --only backups --apply --install-capture` (adds a timer on c3; asked for by the owner earlier but deliberately not installed on 2026-10-22).
2. **A bug in the DR kit, fixed:** `c3-dr-post.sh` and the installer read the admin credentials with `grep '^export OS_' /root/.bashrc`, which finds nothing (they are in `/etc/keystonerc`, which `.bashrc` only sources). Your shell hid it because the variables were already set; in a clean environment the post-install steps would have failed with "missing auth-url". Both scripts now source `/etc/keystonerc`.
3. **Installer drift, fixed:** the installer installed `chrony`; the live host uses `systemd-timesyncd` (chrony would replace it). The package list now says `systemd-timesyncd`.
4. `crudini` is not installed on the live c3 (the installer lists it; the new script installs it before editing a config file under `--apply`).
5. A **GNOME desktop** (`task-gnome-desktop`, `gdm3`) is installed on c3 (2,484 packages): not needed by OpenStack; a rebuild starts minimal.
6. A **stale Neutron agent record** (`neutron-dhcp-agent` on host `c3`, not alive) from the hostname change to `c3.rdulinux.com`; harmless (`openstack network agent delete <id>`).
7. **Terraform on c3 runs from a plain copy** (`/nfsshare/c3/ubuntu/openstack`, no git metadata, last synced 22 October; `infra/` is not initialised there). Its `plan` shows **10 prod and 4 cka VMs `power_state "shutoff" -> "active"`: exactly the VMs that are switched off**, which is why `terraform apply` starts them. Run Terraform from the Mac, or sync the repo first.
8. Because prod and cka are off, the four load balancers show `ACTIVE/ERROR` and the front doors do not answer: expected, reported as WARN.
9. The prod Terraform folder on c3 has the git-ignored `secrets.auto.tfvars` now (the plan ran); keep it mode 600.

## Test status (read this)
- **Tested:** the dry run, twice, on the live c3 (`--dry-run`, stage selection with `--only`, `--from`, `--skip`, `--list`, an unknown option, and `--apply` without confirmation, which cancels with exit code 1 and runs nothing). The checks agree with an independent look at the host. The script ran `terraform plan -lock=false` for prod and cka.
- **Not tested:** `--apply` of anything. In particular the `platform` stage on a blank machine (the installer has never run end to end, `docs/c3-rebuild.md`), the flavor/config fixes, `terraform apply`, the load-balancer builders from `c3-dr-post.sh`, `bootstrap.sh`, and the s3/router installers when something is missing. A first real run belongs on a spare machine or a rehearsal VM, with `--keep-going` off, reading the log as it goes.
- Guards: `platform` refuses to touch an existing OpenStack without `--reinstall`; nothing partitions a disk; the router restore and the capture timer need their own flags; `--apply` asks for `rebuild`.
