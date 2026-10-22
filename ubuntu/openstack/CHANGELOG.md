# Changelog (infrastructure release notes)

What changed in the lab infrastructure, newest first. One entry per day that mattered, with **breaking changes** called out because they are
what bites later. The matching app-side changes are in the finance repo (`docs/RELEASE_NOTES.md`, [PR 309](https://github.com/vellingiri/finance/pull/309)). Design background: `docs/`.
Update this file in the same commit as any change, and list anything done **by hand** (not in Terraform) under "Not in Terraform".

---

## 2026-10-20 (later): automatic database failover (Patroni)

### Breaking changes
| Gone / changed | Now |
|---|---|
| Manual database failover (`pg_promote`, `db-replica-setup.sh` by hand) | **do not use on db1/db2**; Patroni owns PostgreSQL. Use `patronictl switchover` / `failover` / `reinit` (`docs/db-ha-patroni.md`). `postgresql@16-main` is masked on both |
| `DATABASE_URL` with one host | two hosts, `target_session_attrs=read-write`; the app finds the writable one |
| `db.rdulinux.com` followed the primary | still points at the original primary, **not updated on failover**; nothing uses it |
| 17 VMs | **18**: new `db-witness` (m1.tiny, 10.0.1.120 / 192.168.2.104). Memory headroom on `c3` is now ~1.1 GB |

### What was built
- Patroni 3.2.2 on `db1`/`db2` (adopted the existing data, about 2 s of failed writes), etcd 3.4 with three members (`db1`, `db2`, `db-witness`), nftables guard for etcd/Patroni ports, ntfy message on every role change.
- App (finance repo, `sha-aa0101f`): per-host connect timeout and `FailoverPool`, query timeout, scheduler leader watchdog, `pg_dump` connect timeout.
- Monitor (`db-replication-monitor`) also checks Patroni on each node, the cluster view and the witness.
- **Drills, all passed on live prod:** planned switchover 14-16 s; process kill ~5 s; primary VM power-off ~40 s (app self-recovered, no data loss); network partition (no split brain, ~12 s failed writes); witness loss (no effect). The first VM-crash drill found the asyncpg shared-timeout problem, fixed and repeated.

### Everything on the database VMs now comes from Terraform (cloud-init); a replaced node needs nothing by hand
- New `cloud-init/db-ha.yaml.tftpl` + `files/db-ha-node.sh`: etcd (joins a running cluster or forms one), nftables guard, Patroni config incl. `pg_hba`, patronictl config, ntfy callback. `ip:` is now required in `nodes.yaml` for database/witness nodes (same addresses as today). Passwords are Terraform variables from the git-ignored `environments/prod/secrets.auto.tfvars` (`scripts/db-ha-secrets.sh`). Existing VMs untouched (plan: no changes).
- **Found while testing a `db-witness` replace and fixed on `c3` (by hand, in OpenStack, not Terraform):** Nova could not release a Terraform-owned port when deleting a server, because Neutron refused the update for the user `neutron`. Granted it the `service` role (`openstack role add --user neutron --project service service`) and restarted `nova-compute`. Details and proof: `docs/port-unbind-fix.md`.
- **Proven:** `db-witness` and then `db2` were each replaced with one `terraform apply -replace` and joined/streamed by themselves in about 2 minutes (details in `docs/db-ha-patroni.md`).
- **Proven on the primary too:** switchover to `db2` (`patronictl switchover`), then `db1` was replaced; it needed one plain `terraform apply` because its old Nova-made port had been deleted with the VM (`docs/port-unbind-fix.md`), then rebuilt itself and streams from `db2`. **`db2` is now the primary and `db1` the replica**; roles can stay that way (names do not matter, the app finds the writable host).
- **OpenStack actions taken during this work (all reverted):** QA VMs `learn`, `w2` and `w3` were stopped for a scratch rehearsal and started again; the three scratch VMs `dbt1`, `dbt2`, `dbt-witness` (and their ports) failed with NoValidHost (stopped VMs keep their memory reserved) and were deleted; a test VM `porttest` and its port were created and deleted to prove the port fix; the stale port of the replaced witness had its `device_id` cleared by hand once; the VMs `db-witness` and `db2` were replaced through Terraform (new VMs, same addresses, same names).

### Capacity and cleanup done the same day (OpenStack, by hand)
- `ram_allocation_ratio` 1.1 -> 1.2 on `c3` (nova.conf + nova-compute restart); see `docs/port-unbind-fix.md`.
- `w4` and `w5` retired: VMs removed through Terraform, then their load balancer pool members and Kubernetes nodes deleted. **Prod now has 3 workers, no spare node**: draining one blocks until it is back (`docs/k8s-operations.md`). VM count 16.
- The whole database group was rebuilt from nothing on three scratch VMs (deleted afterwards); it found and fixed a startup race in `db-ha-node.sh`.

### CKA practice cluster (built and verified)
- New `environments/cka` (1 controller + 3 workers, m1.small, `cka.rdulinux.com`) and the zone `cka.rdulinux.com.` in `infra/infra.yaml`. Build, use and teardown: `docs/cka-cluster.md`. Apply `infra` first (DNS zone), then `environments/cka`.

### Host reboot test 5: all VMs stopped, force reboot, manual start (`docs/c3-reboot.md`)
- `c3` back in 31 s after `systemctl reboot --force --force`; everything recovered (front doors 200, 12/12 pods, Patroni 1 Leader + 1 Replica, etcd 3/3, same amphorae). Found: VMs started right after boot can stick in `powering-on` (new `scripts/c3-restart-stuck-vms.py`; wait a minute after `nova-compute` is up); `openstack server reboot --hard` fails because Cinder is disabled (use stop/start); the `runner` guest hit a kernel oops once (cause unknown, did not recur).
- Capacity/Cinder note: Cinder has been disabled since August 2026; nothing here uses volumes.

### Host reboot test 6: automatic VM start after a hard reset with every VM running, passed; why a plain reboot hangs
- All 19 VMs started by themselves after the reset, both front doors 200 about 4 minutes after `c3` answered ssh, no load balancer failovers, no stuck VM (`docs/c3-reboot.md` Test 6; an earlier wording that called it a clean plain reboot was wrong, the shutdown had hung and the host was reset by hand).
- **Why `systemctl reboot` hangs:** `ovn-controller` and the other network services stopped before `libvirt-guests` shut the guests down, so the prod workers (`w1` to `w3`) lost their network and sat for the full 300 s shutdown timeout. Added the drop-in `/etc/systemd/system/libvirt-guests.service.d/20-order-after-ovn.conf` on `c3` (by hand, untested). **Standing rule: restart `c3` with a force reboot** until a plain reboot has been seen to complete.

### 2026-10-22: prod database VMs, witness and runner renamed in place (`db1-prod`, `db2-prod`, `dbw1-prod`, `ci1-prod`)
- Hostname, `/etc/hosts` and the OpenStack server name only (`scripts/vm-rename-in-place.sh`), nothing restarted: after each rename Patroni stayed `db1` Leader + `db2` Sync Standby, etcd 3 of 3, the front door 200; the GitHub runner `finance-runner` stayed online and the monitor kept running. **Internal names did not change**: Patroni and etcd members are still `db1`, `db2`, `dbw1` (they are fixed in `/etc/patroni/config.yml` and `/etc/default/etcd`). To keep that true when a database VM is rebuilt, `nodes.yaml` has `member: db1` for the VM `db1-prod`, `environments/prod/main.tf` builds the group's member list from `member`, and `cloud-init/files/db-ha-node.sh` now finds its own member name **by its address** instead of by hostname. The runner is `ci1-prod` (role `runner`). `nodes.yaml` keys, `moved.tf`; **`terraform plan` must again replace no VM**. Mac: ssh aliases `db1`, `db2`, `runner`/`ci1` pinned to the floating IPs (`*-prod` patterns work through DNS after the apply). Docs/scripts say `ssh ci1`.

### 2026-10-22 (night, last): c3 `/root` tidied
- Removed the disk-move leftovers, three empty mount directories in `/root/amphora-fix` and the two superseded amphora files `amphora-fixed.qcow2` and `amphora-orig.qcow2` (same bytes still in Glance as `c537e966` and `90ce7754`, untagged; `amphora-fixed2.qcow2` = the live image `3f82fe7b`, tag Amphora, kept). Later the same night also removed from `/root` on c3: the older copies of `octavia-argo-lb-ha.sh` and `octavia-k8s-api-lb.sh` (the repo has the current ones), the superseded `nova.conf.bak-20261020-ram/-ratios/-ratio17`, the August router files (`openwrt-config.tar.gz`, `openwrt-clean.tar.gz`, `firewall`; replaced by the daily s3 backups, `docs/openwrt-router.md`) and the 103 KB console log of the w1-prod shutdown test (findings are in `docs/c3-reboot.md`). The live amphora image file `amphora-fixed2.qcow2` was moved by the owner to `/nfsshare/qcow2/` (the `repo` host's NFS share, so a copy that is not on c3); `c3-dr-capture.sh` now mirrors `*.qcow2` from both `/root/amphora-fix` and `/nfsshare/qcow2`. Afterwards, at the owner's request, also deleted the last three config backups (`nova.conf.bak-20261022-ratio12`, `nova.conf.bak-20261022-resize`, `octavia.conf.bak-20261020-heartbeat`): **older entries that name these files as rollback points no longer have them**; the values are in the entries themselves (ram_allocation_ratio 1.7 before 1.2; heartbeat_timeout was the default before 300). Was kept: `work` (Octavia work dir), `backups`, `amphora-fix`, `octavia.conf.bak-20261020-heartbeat`, `nova.conf.bak-20261022-resize` and `-ratio12`.

### 2026-10-22 (night, last): VM disk space on c3 moved to its own partition (done)
- **Done:** new partition `p4` (550 GB, made by the owner) mounted at `/var/lib/nova`; the script's `prepare` copied the data live, the cutover was done by hand; all 17 VMs back ACTIVE, front doors 200, Patroni (`db2` Leader), etcd 3/3 and 6 of 6 nodes healthy, Placement disk total 136 -> 540 GB (capacity 340 -> 1,350 GB). The old copy `/var/lib/nova.old` (65 GB) is still on `/` until `finish`. Next: grow the cka VMs and the witness to 20 GB, consider `disk_allocation_ratio` 1.0 (`docs/c3-disk-expansion.md`).
- Background: found that the NVMe disk has about 760 GB unpartitioned (root partition 140 GB, 71 % full). Approved: a new partition for `/var/lib/nova/instances`. `scripts/c3-nova-disk-move.sh` (phases status, prepare, cutover, finish) and `docs/c3-disk-expansion.md` written and syntax-checked; **nothing was run or changed on c3**. Needs a maintenance window.

### 2026-10-22 (night, later): rest of prod resized in place to 20 GB root disks
- New flavors on c3 (`openstack flavor create`): **`m1.small-20g`** (2 vCPU, 4 GB, 20 GB), **`m1.medium-20g`** (4 vCPU, 8 GB, 20 GB), next to **`k8s.worker`** (same as `m1.small-20g`, created for the workers). Resized in place, one VM at a time (`openstack server resize --flavor ...`, check, `resize confirm`; about 70 s each, disk 20 GB, same RAM and CPUs): control planes **`c3-prod`, `c2-prod` (m1.small-20g), `c1-prod` (m1.medium-20g)** with etcd 3 of 3 and 6 of 6 nodes Ready after each (drained first); the runner **`ci1-prod`** (m1.medium-20g) while CI was idle, `finance-runner` back online; the databases: **`db2-prod`** (the standby) first, then a planned **`patronictl switchover --candidate db2 --force`**, then **`db1-prod`**. Front door 200 throughout (a few seconds of paused writes at most), Patroni at the end: **`db2` Leader, `db1` Sync Standby, lag 0**. **The leader is now `db2`** (it was `db1`; either is fine, the app lists both). `nodes.yaml` updated, so Terraform sees no flavor difference (`terraform plan` in prod: check).
- Left at 10 GB on purpose: the four cka VMs and the witness `dbw1-prod`. Reason: c3's Placement disk capacity is 340 GB (136 GB x ratio 2.5), 240 used before this and about 300 now; the host's real disk is 71 % full (39 GB free). `docs/pending.md`.
- Not in Terraform: the three flavors.

### 2026-10-22 (night): worker role shown by `kubectl get nodes`; CI browser-journeys evicted for disk
- `ROLES` was `<none>` for workers (kubeadm only labels control planes, and a kubelet may not label itself `node-role.kubernetes.io/*`). `cloud-init/files/k8s-publish-join.sh` (runs hourly on every control plane) now labels every node without the control-plane label as `worker`; `k8s-rejoin-node.sh` labels at once. Applied: the 3 prod workers labelled and the new publisher copied to the 3 prod control planes (by hand, cloud-init covers new ones). **cka: the publisher on its `c1` is still the old one** (cluster stopped); copy it when cka is started, or label by hand.
- **CI run 39731638339 (`Restart QA Pods` > Browser journeys) fails: the Playwright pod is evicted** ("node low on ephemeral-storage"): the workers have 10 GB root disks (flavor `m1.small`), the Playwright image is about 3 GB and w2-prod had 1.9 GB free (threshold 1.5 GB). Pruned unused images on the 3 workers (free: 3.8 / 5.0 / 5.2 GB); the re-run still failed because the image plus the pod's scratch space again crossed the threshold. **Fixed the same night:** new flavor `k8s.worker` (2 vCPU, 4 GB, **20 GB** disk; created on c3 with `openstack flavor create`), the three prod workers resized **in place** one at a time (cordon, drain, `openstack server resize --flavor k8s.worker`, check, `resize confirm`, uncordon; about 70 s each, disk 20 GB with 12 to 15 GB free, 6 of 6 nodes Ready, finance door 200, Argo Synced/Healthy after each), `nodes.yaml` now says `k8s.worker` so Terraform shows no difference. The failed CI run was re-run and **passed**. Disk budget: Placement `DISK_GB` capacity 340 (136 x ratio 2.5), 240 used, so growing all other VMs by 10 GB (+110) does not fit; plan for the rest in `docs/pending.md`. A failed `resize` shows as `RESIZE` for a minute: wait for `VERIFY_RESIZE` before touching the node.

### 2026-10-22 (night): OpenWrt router checked and tidied; backup and restore scripts
- Checked read-only (ASUS RT-AX53U, OpenWrt 25.12.5, up 7 days): interfaces, routes, firewall, DNS and DHCP fine. Changed on the router (all backed up first): **DHCP pool `.25-.123` -> `.25-.59`** (it contained lab addresses `.61`, `.75`, `.113` and the OpenStack floating IPs; the router had a lease and an ARP entry for `.75` on the s3 host's MAC); **timezone GMT -> IST**; **`rebind_domain rdulinux.com`** (dnsmasq discarded every `*.rdulinux.com` answer as a DNS-rebind attack when asked directly; clients use `192.168.2.2` so nobody noticed). wan-to-lan forwarding stays on on purpose.
- New `scripts/openwrt-backup.sh` (archive + `uci export` to `s3:/backup/openwrt/`, checksum-verified, newest 30 kept) and `scripts/openwrt-restore.sh` (safety backup, `sysupgrade -r`, reboot, verify); `docs/openwrt-router.md`. Restore script not yet run (reboots the gateway).
- **Daily router backup on s3** (`openwrt-backup.timer`, 03:15, only when something changed; key `/root/.ssh/openwrt_backup` on s3 added to the router's authorized keys): `scripts/s3-openwrt-backup.sh`, `scripts/install-s3-openwrt-backup.sh`. First run stored `openwrt-20261022-121013-daily`; a second run said "unchanged".
- Not in Terraform: the router settings (documented in `docs/openwrt-router.md`, recoverable from the s3 archives).

### 2026-10-22 (evening): pods could not resolve outside names (Argo CD could not reach GitHub) — fixed; app-layer bootstrap script
- **Found after the prod node re-join:** Argo CD showed `Unknown` (repo-server could not look up github.com) and its repo-server crash-looped on its liveness probe. Cause: CoreDNS forwards to the node's `/etc/resolv.conf` (our DNS server `192.168.2.2`, set with `--resolv-conf` on 2026-10-21), and the **pod network `192.168.0.0/16` contains `192.168.2.2`**, so Calico does not masquerade pod traffic to it; the query left the VM with a pod source address and OpenStack dropped it. CoreDNS pods started before the re-join still had the old resolver, which is why it only showed now. cka had the same timeouts in its CoreDNS log.
- **Fix:** every node masquerades `192.168.0.0/16 -> 192.168.2.2` (systemd unit `pod-dns-masq.service`: `iptables -t nat -I POSTROUTING 1 -s 192.168.0.0/16 -d 192.168.2.2 -j MASQUERADE`, idempotent). Installed by hand on the 6 prod and 4 cka nodes, and in `cloud-init/k8s-common.yaml.tftpl` for new nodes (user_data only; check `terraform plan` shows no VM replaced). After it: CoreDNS logs clean, `finance-qa` Synced/Healthy, repo-server restarted once (pod deleted).
- New **`k8s/bootstrap.sh`** in the finance repo (app layer on an empty cluster: namespaces, secrets, Argo CD v3.5.1, Application, checks; `--check` is read-only). `docs/c3-rebuild.md` step 2 now points to it; removed from `docs/pending.md`.
- cka: the workers were already `w1-cka`..`w3-cka`; `c1` stays (single control plane).
- Not in Terraform: the unit on the 10 existing nodes.

### 2026-10-22 (later): prod Kubernetes node names changed to `c1-prod` ... `w3-prod` by re-joining each node
- A node cannot be renamed, so each left and came back, one at a time, with the new `scripts/k8s-rejoin-node.sh prod <node>`: workers `w3 w2 w1` (cordon, drain, delete node, `kubeadm reset`, join), then control planes `c3 c2 c1` (drain, etcd member removed while the other two kept the majority, node deleted, reset, `kubeadm join --control-plane`). The VM, address and disk stay. After every node: all nodes Ready, finance door 200, no pod outside Running/Completed, Argo CD Synced/Healthy. End state: 6 nodes Ready, etcd 3 of 3, `/livez` ok.
- Problems found on the way and fixed in the scripts: `k8s-retire-node.sh` recognised a control plane by the *value* of the `control-plane` label, which is empty, so it treated c3 as a worker and left its etcd member behind (the join then stopped at `check-etcd`); fixed by testing for the label key. Removed the stale member by hand, re-joined c3. Both scripts also now accept a node name that already carries `-<env>` (c2-prod). While c1 left etcd (2 members) one API call timed out for a few seconds; the retry worked.
- Not in Terraform: node objects and etcd members only. cka keeps `c1`, `w1`.. (single control plane).

### 2026-10-22: prod Kubernetes nodes renamed in place to `c1-prod` ... `w3-prod`
- Same method as cka, no VM rebuilt, the finance app answered 200 and 12 of 12 pods stayed Running throughout: for each node in turn (`w3 w2 w1 c3 c2 c1`) `scripts/k8s-rename-node-vm.sh prod <node> <node>-prod` pinned the kubelet to its old Kubernetes node name (`--hostname-override`, proven in the kubelet's command line before the hostname changed), set the hostname and `/etc/hosts`, renamed the OpenStack server; after each node the node, the API (`/livez` through `api.prod`), the system pods and both front doors were checked. Kubernetes node names were changed afterwards by re-joining (entry above). `db1`, `db2`, `dbw1` and `runner` are unique across environments and keep their names. `environments/prod`: `nodes.yaml` keys `c1-prod`..`w3-prod`, `moved.tf`, DNS domain `rdulinux.com`; **`terraform plan` first, it must replace no VM (only DNS `A` records), then apply**. Docs and scripts that used `c1.prod`/`w1.prod` now say `c1-prod`/`w1-prod`; ssh pattern `*-prod`.

### 2026-10-22: new VM naming `<role><n>-<env>` (cka done, renamed in place); RAM ratio back to 1.2
- VMs now carry their environment: `c1-cka`, `w1-cka`, (prod: `c1-prod`, `w1-prod` later). Done for **cka without rebuilding**: `scripts/k8s-rename-node-vm.sh cka <node> <node>-cka` per node (kubelet pinned to its old Kubernetes node name with `--hostname-override`, hostname and `/etc/hosts`, OpenStack server name), nodes.yaml keys renamed with `environments/cka/moved.tf`, DNS domain `rdulinux.com` (names are `c1-cka.rdulinux.com`), ssh patterns `*-cka *-prod`. **Run `terraform plan` in `environments/cka` and check it replaces no VM** (expected: names changed in place, DNS records re-created), then apply. Kubernetes node names stay `c1`, `w1`.. (see `docs/cka-cluster.md`, "Names"). `k8s-ha-convert.sh` and `k8s-retire-node.sh` find nodes under either naming.
- `ram_allocation_ratio` 1.7 -> **1.2** in `/etc/nova/nova.conf` (backup `/root/nova.conf.bak-20261022-ratio12`, `nova-compute` restarted): allowed 95.6 GB, allocated 77.8 GB, so a load balancer failover (2 to 4 GB) still fits; the over-allocation that helped cause the out-of-memory kill is gone.

### 2026-10-22: `qa` cluster destroyed (3 VMs: `c1`, `w1`, `w2`)
- It ran nothing but `ingress-nginx` (the finance app's "QA" deployment is the `finance-qa` Argo application in the **prod** cluster). `terraform destroy` in `environments/qa` (state on `s3`); VMs, ports, floating IPs and DNS records gone. Real memory use on `c3` went from 72 to 66 GB (14.3 GB available), placement allocation from 94 to 78 GB. The configuration stays in git: `terraform apply` in `environments/qa` recreates it in about 10 minutes (the zone `qa.rdulinux.com.` is in `infra` and stays). `~/.kube/qa` and its entry in `KUBECONFIG` are stale.

### 2026-10-22: etcd voters back from five to three (`dbw2`, `dbw3` removed) to give memory back to `c3`
- `c3` had 3 GB of real memory left and the kernel had already killed a VM (21 Oct 12:11). Each extra witness used about 1.5 GB. Done safely with the new `scripts/db-ha-etcd-shrink.sh apply dbw3 dbw2`: Patroni's `etcd3.hosts` cut to three, the two members removed from etcd one at a time (5 -> 4 -> 3 voters), firewall updated; Patroni never left Leader + Sync Standby. Then `nodes.yaml` has `dbw2`/`dbw3` commented out (**run `terraform apply` in `environments/prod` to destroy the two VMs: 4 GB allocated and about 3 GB of real memory back**). Monitor and scripts know one witness again. The double failure "witness + one database" stops automatic failover again; see `docs/db-ha-patroni.md`.

### 2026-10-22: `runner` resized m1.large -> m1.medium (8 GB RAM and 4 vCPUs back to the host)
- The runner VM used about 0.5 GB of its 16 GB when idle (CI jobs: pytest, buildx, Trivy, one job at a time). Resized **in place** (no rebuild, so the GitHub registration, addresses and disk stay): `allow_resize_to_same_host = true` added to `[DEFAULT]` in `/etc/nova/nova.conf` on `c3` (backup `/root/nova.conf.bak-20261022-resize`; `nova-api`, `nova-conductor`, `nova-scheduler`, `nova-compute` restarted), `openstack server resize --flavor m1.medium runner`, health check, `openstack server resize confirm`. 72 s to `VERIFY_RESIZE`; afterwards 4 vCPUs, 7.9 GB, `finance-runner` online, monitor active. `nodes.yaml` now says `m1.medium` so Terraform sees no difference (it could not be applied: the state store `s3` was down). **Watch the lowest "available" memory on the runner during CI runs** (`free -m`); if it ever drops under about 2 GB, go back to large the same way. Any VM can now be resized in place the same way.

### 2026-10-21: rebuild `c3` from nothing (scripts and runbook; nothing was changed on `c3`)
- New `docs/c3-rebuild.md` and `scripts/c3-dr/`: `c3-dr-capture.sh` (everything needed to rebuild c3: all of `/etc`, every OpenStack database, MariaDB users with hashes, RabbitMQ definitions, Glance images, the `/share` tree, `/root`, `/usr/local`, small state, cron, package lists, read-only dumps of the whole cloud), `c3-dr-install.sh` (platform on a fresh Debian 13 in phases 0 to 8: Keystone and Glance restored from their dumps, everything else migrated empty and rebuilt by Terraform; config comes from the capture, not retyped), `c3-dr-post.sh` (Octavia ids, the four load balancers with their old floating IPs, check), `install-c3-dr-capture.sh` (nightly timer, **not installed**). `octavia-k8s-api-lb.sh` can pin its floating IP and start without members.
- Verified read-only on the live c3: capture `--dry-run`, the lookup helpers, the `/etc` audit and OVS-setting parser. **The installer has not been run on a blank machine**; rehearse it (`docs/pending.md`).

### 2026-10-21: nodes removed by destroying the VMs (cka c2/c3, qa w3)
- `cka` `c2`/`c3` and `qa` `w3` were removed from `nodes.yaml` and the VMs destroyed without draining or leaving the cluster: `qa` `w3` stayed `NotReady` (node object deleted by hand), and `cka` lost its etcd majority (1 of 3 members), so its API timed out. New `scripts/k8s-retire-node.sh` (drain, etcd member removal, node delete) and the runbook in `docs/k8s-ha-control-plane.md` ("Removing a node", including the `--force-new-cluster` recovery). Prod was not affected.

- **`cka` recreated** (1 controller + 3 workers) with `terraform destroy` + `apply` instead of repairing etcd: all four nodes Ready through `api.cka.rdulinux.com` without any manual step (the kubelet resolver fix in cloud-init worked), `cka-api` points at the new `c1`; the stale join files on the NFS share were removed first (a worker would otherwise pick up the old token). Kubeconfig refetched. Procedure and the stale-file trap in `docs/cka-cluster.md`.

### Two-amphora failover of `finance-lb` fixed (it was capacity)
- Cause found: the replacement amphora is built before the old one is deleted, and under the old RAM ratio (1.1/1.2, then 1.5 with the new VMs) less than 2 GB was allocatable at that moment: Placement returned no candidates. `ram_allocation_ratio` **1.5 -> 1.7** on `c3` (nova.conf, backup `/root/nova.conf.bak-20261020-ratio17`; allowed 135,371 MB, allocated 118,784 MB). Two full `openstack loadbalancer failover finance-lb` runs: ACTIVE in 84 s and 78 s on the first try, 376 probes, none failed. **Real memory use is 67 of 80 GB: no more VMs without checking `free -m`.** The last item of `docs/pending.md` is gone.

### Kubernetes control planes are highly available (cka drilled, prod converted)
- **cka:** `c2`, `c3` joined through the new API load balancer `cka-api` (`api.cka.rdulinux.com`); powering the first control plane off: the API stayed available (5 failed probes of 51 during the 25 s the load balancer needed to notice; now 3 s x 2 monitor), a write worked at once, leadership moved, `c1` rejoined by itself.
- **prod:** converted in place (`scripts/k8s-ha-convert.sh prod`: new API certificate, every node's kubelet/kube-proxy pointed at `api.prod.rdulinux.com`, join publisher on `c1`); load balancer `prod-api` (ACTIVE_STANDBY). Front door 200, Argo 200, 12/12 pods, Argo Synced Healthy throughout. **Prod `c2`/`c3` created by Terraform and joined by themselves** (m1.small, 10.0.1.25 and .251), 6 of 6 nodes Ready, `prod-api` 3 members; **drill: prod `c1` powered off during live traffic: front door 200 on all 68 probes, API 3 failed of 68, writes worked, leadership moved, `c1` rejoined.** CoreDNS was found stuck on `c1` and is now 3 replicas spread over nodes (also in cloud-init). Mac kubeconfig and the CI runner's kubeconfig (backup `config.bak-20261020-ha`) now use the API name.
- New: `cloud-init/k8s-controller-join.yaml.tftpl` (role `controller_join`), `cloud-init/files/k8s-publish-join.*` (hourly join publisher, with a lock), `scripts/octavia-k8s-api-lb.sh`, `scripts/k8s-ha-convert.sh`, `scripts/k8s-api-lb-reconciler.py` + `install-k8s-api-lb-reconciler.sh` (timer `k8s-api-lb` on `c3` keeps the load balancer members equal to the control-plane VMs, credentials in `/etc/default/k8s-api-lb-reconciler`, mode 600), OVN VIP reconciler also probes 6443. Found and fixed: concurrent publisher runs gave a bad certificate key (lock); new nodes never Ready because kubelet's resolver file listed only 8.8.8.8 (`resolvConf: /etc/resolv.conf` in all node templates and by hand on c2/c3). Docs: `docs/k8s-ha-control-plane.md`.
- OpenStack by hand: load balancers `cka-api` and `prod-api` (and their floating IPs 192.168.2.75 / .61, health monitors 3 s x 2), `disk_allocation_ratio` 2.0 -> **2.5** (`/etc/nova/nova.conf`, backup `/root/nova.conf.bak-20261020-ratios`).

### The `s3` state store (RustFS) checked and hardened
- Versioning was already on, but there was **no backup** of any state. Added an hourly snapshot job on `s3` (`/backup/terraform-state/`, change-only, JSON-validated) and a daily pull to `c3:/root/backups/terraform-state/`; pinned the image (`rustfs/rustfs:1.0.2-pinned`), `/opt/rustfs/recreate-rustfs.sh`, health check in the runner's monitor. Details and restore steps: `docs/s3-state-store.md`.

### `backup` renamed `s3`
- The host at 192.168.2.4 (MinIO for the Terraform state on :9000, NFS `/backup`) is now **`s3`** / `s3.rdulinux.com`: hostname and `/etc/hosts` changed on the machine (backups of the old files in `/root/*.bak-20261020`), DNS record `s3` in `infra/infra.yaml` replaces `backup` (**run `terraform apply` in `infra`**; until then `s3.rdulinux.com` does not resolve and `backup.rdulinux.com` still does), ssh alias `s3` (pinned to the address until the DNS record exists). Nothing depended on the name: Terraform's backends use the address 192.168.2.4, the NFS export is by network, cron and scripts on `c3`, `runner` and `repo` do not mention it. The Cinder backup copy is at `s3:/root/backups/c3-cinder-removal-20261020.tgz`.

### Five etcd voters (`dbw2`, `dbw3` added) and `dbw` renamed `dbw1`
- Two more witnesses (10.0.1.121/.122, m1.tiny) built by Terraform/cloud-init and joined to etcd by themselves; Patroni lists all five addresses; monitor checks every witness; `scripts/db-ha-etcd-grow.sh` for the existing machines. **Drill: witness `dbw1` and the primary `db2` powered off together: `db1` Leader after 35 s, zero acknowledged writes lost** (the scenario that used to stop failover). Emergency procedure for a real loss of the majority is in `docs/db-ha-patroni.md`.
- `dbw` renamed **`dbw1`** (same address 10.0.1.120): the VM is replaced by Terraform (two applies, the first may stop on "IP already allocated"). The new VM rejoins etcd by itself.

### Load balancers: `argo-lb` is ACTIVE_STANDBY, dead amphora repaired in 5 minutes (OpenStack, by hand, scripted)
- `argo-lb` rebuilt as ACTIVE_STANDBY with `scripts/octavia-argo-lb-ha.sh` (new VIP `10.0.1.76`, the floating IP `192.168.2.113` moved, old load balancer deleted): master amphora powered off, 100 of 100 requests HTTP 200. Four amphorae now.
- `heartbeat_timeout` 900 -> **300** (and `octavia-health-manager` restarted; backup `/root/octavia.conf.bak-20261020-heartbeat`). Plain reboot of `c3` afterwards: 0 failovers, same four amphorae, front doors 200.

### Database replication is now synchronous (zero acknowledged-write loss on a primary failure)
- Patroni `synchronous_mode: true`, `synchronous_node_count: 1` (not strict) on the live pair and in `cloud-init/files/db-ha-node.sh`. Drilled: primary powered off during writes, highest acknowledged commit == last row on the new primary (1470 / 1470); standby powered off: writes pause 34.5 s then continue asynchronously. New probe `scripts/db-sync-loss-probe.py`. Also raised on `c3` (by hand, backup `/root/nova.conf.bak-20261020-ratios`): `ram_allocation_ratio` 1.5 and `disk_allocation_ratio` 2.0 (physical use: RAM 46 of 80 GB, disk 40 GB free), needed for the redundancy work below.

### Frontend handles SIGTERM (finance repo)
- `app/frontend/server.js` now exits cleanly on SIGTERM/SIGINT (it is PID 1 in its container and ignored them); test added. Effect: frontend pods stop in about a second instead of the full grace period. **Deployed and verified** (image `sha-2c4f522`, CI green): deleting a frontend pod took 1 s (grace period 30 s), the replacement was Running within seconds, front door 200 throughout.

### Host reboot test 8: plain reboot with both fixes, passed
- `systemctl reboot` at 19:32:40: all 19 guests shut down within 32 s, host down after 75 s, back (ssh) 109 s after the command, all VMs auto-started, front doors 200 about 4.5 minutes after the command; no failovers, no stuck VM (`docs/c3-reboot.md` Test 8). The force reboot is now only the fallback.

### Why prod workers took 4.5 minutes to power off: fixed (kubelet graceful shutdown)
- Cause: kubelet's `shutdownGracePeriod` was 0, so at power-off the network and the pods' NFS mounts went away while a `node` container was still running; it hung and systemd waited 3 x 90 s. Reproduced (271 s) and fixed: `shutdownGracePeriod: 30s`, `shutdownGracePeriodCriticalPods: 10s` on every node (by hand) and in the k8s cloud-init templates; the same worker now powers off in 33 s. Details and evidence: `docs/c3-reboot.md`.
- The host route `10.0.1.0/24 via 192.168.2.174` on `c3` is persistent and documented (`docs/c3-host-route.md`; `up`/`down` lines in `/etc/network/interfaces`), present after every reboot test.

### Host reboot test 7: plain reboot with the ordering fix; the reboot is slow, not stuck
- Plain `systemctl reboot` completed by itself: `c3` back 327 s after the command, all VMs auto-started, everything healthy (`docs/c3-reboot.md` Test 7). The shutdown waits about 4.5 min for the prod workers `w1` to `w3` (cause still open; `docs/pending.md`); the hand reset in test 6 came just before they finished. OVN now stops after the guests (drop-in works). Prod workers' journals made persistent (by hand) and added to `cloud-init/base.yaml.tftpl` for new VMs.

### Cinder removed from the catalog
- Cinder (block storage) had been disabled since 2026-08-17 and nothing used volumes (0 volumes, snapshots, backups, 0 volume attachments in Nova). Its catalog service `cinderv3` and its 3 endpoints were deleted; the packages and the `cinder` database stay installed but unused. **Backups** (before deleting): `/root/backups/cinder-removal-20261020/` on `c3` (database dump, `/etc/cinder`, service and endpoint JSON, `RESTORE.txt`, checksums) and a copy on the `backup` host at `/root/backups/c3-cinder-removal-20261020.tgz`. Effect: `openstack server reboot --hard` works again (tested on a CKA worker).
- New `docs/pending.md`: the list of open items and accepted limits.

### `db-witness` renamed `dbw`
- Short name like the other VMs (`db1`, `c1`, `w1`). In `nodes.yaml` the key changed, so Terraform replaces the VM (new VM, same address 10.0.1.120): run `terraform apply` in `environments/prod`; if the first apply stops with an IP-in-use error on the new port (old and new are created at the same time), run it a second time. The new VM joins etcd by itself and replaces the old member (same address). The monitor on the runner (`WITNESS` default) and `~/.ssh/config` (`Host dbw`) were updated. Older entries of this file still say `db-witness`.

### Spare VM removed
- `learn` (QA, m1.small) removed from `environments/qa/nodes.yaml`; the VM, its port, floating IP and DNS records go away with `terraform apply` in `environments/qa`. VM count 15 after that.

### Limits
Asynchronous replication (a hard failure can lose the last seconds of writes); losing two of the three etcd machines stops automatic failover.

### Not in Terraform
Patroni and etcd configs, nftables guard, patroni-notify, `pg_hba` lines, monitor on the runner (all listed in `docs/db-ha-patroni.md`). In Terraform: role `witness` and VM `db-witness`.

---

## 2026-10-20: load balancers, 3-replica HA, database replica

### Breaking changes (names and addresses that no longer work)
| Gone / changed | Now |
|---|---|
| VM `haproxy` and name `haproxy.rdulinux.com` (192.168.2.5, then `.119`) | destroyed; **192.168.2.5 is the Octavia load balancer `finance-lb`**. ssh alias `haproxy` removed |
| `qa.rdulinux.com` (apex record, finance app) | removed. The zone `qa.rdulinux.com.` stays for the QA VMs (`c1.qa`, ...). The app is `finance.rdulinux.com` |
| `lb.rdulinux.com` | existed for a few minutes as the renamed `haproxy`, then retired |
| `argo.rdulinux.com` → 192.168.2.5 | now → **192.168.2.113**, its own load balancer `argo-lb` |
| VM `db` | renamed **`db1`** (same VM, IP and data). `db.rdulinux.com` is now an alias for the current primary (TTL 60 s) |
| the *original* prod worker `w1` (10.0.1.118) and the test VMs `web1`, `web2` | deleted; prod `w1` was re-created as a new VM |
| ssh alias `qa` | removed; `ssh w1.prod` and `ssh w1.qa` both work |

### Verified: client addresses behind the load balancer
- nginx logs the real visitor address (`192.168.1.13`, `192.168.2.2`) as `client_ip` behind `finance-lb`, so per-address limits count per person (still per nginx pod). Noted in the finance repo's `docs/CICD_SETUP.md`.
- The finance backend's `/health` now ends with a newline (finance repo, deployed in `sha-94290d1`).

### Host `c3`: a plain reboot now brings everything back, including both front doors (see `docs/amphora-reboot-fix.md`)
- **Result:** two plain reboots of `c3` with all 17 VMs running and no manual step: VMs back by themselves in about 2 minutes, both front doors 200 about 3 minutes after `c3` answered ssh, the same three amphorae (no rebuilds), load balancers `ACTIVE`/`ONLINE`.
- **Root causes found and fixed:** (1) the amphora image (Octavia 16.1.1) lost its VIP network after any clean shutdown: its boot script paired lines of `ip link` (breaks on `altname` lines) and raced udev's NIC rename; **patched image `Amphora-netns-fix-v2-20261020`** (the only one tagged `Amphora`; all three amphorae rebuilt from it); (2) OVN's router (`always_learn_from_arp_request=false`, no aging) kept a stale MAC for a rebuilt amphora: new **`ovn-vip-binding.timer`** watcher on `c3` (`scripts/ovn-vip-binding-reconciler.py`, every 30 s, no credentials needed); (3) Octavia's health manager rebuilt amphorae that were just waking up: **`heartbeat_timeout = 900`** (and `failover_threshold = 2`).
- **Behaviour change:** a really dead amphora is now replaced automatically only after 15 minutes. **Known flaw left:** `openstack loadbalancer failover finance-lb` (two amphorae at once) fails about half the time with a Nova/Placement "no allocation candidates" error and needs a retry; cause not found.
- Old images `90ce7754…` (original) and `c537e966…` (first, insufficient patch) are kept untagged as backups. The patch must be redone if the amphora image is ever replaced.
- Also: the earlier autostart settings, `nmbd` fix and `ndots:2` (next entry) are unchanged.

### Host `c3`: VMs restart by themselves after a boot, plus two small fixes
- **Autostart configured** (`docs/c3-reboot.md`): `resume_guests_state_on_host_boot = true` (Nova), clean parallel guest shutdown and no libvirt autostart (`/etc/default/libvirt-guests`), a systemd drop-in so `nova-compute` stops before the guests are shut down, and Octavia `failover_threshold = 2` so a reboot does not trigger a mass rebuild of amphorae. Proven on the spare VM `learn` (restarted in 24 s; a VM stopped on purpose stays off); proven through two plain reboots (see the entry above).
- **`nmbd` fixed:** Samba listened on `enp3s0`, which has no IP (it is a port of the bridge `br0`); now `br0`. **Name lookups on `c3` fixed:** `options ndots:2` so `nslookup w1.prod` works. Backups of every changed file: `*.bak-20261020`.

### Rehearsed: rebooting the cloud host `c3` (see `docs/c3-reboot.md`)
- All 17 VMs were shut down gracefully, `c3` was rebooted (back in 150 s), the persistent route came up by itself, and everything was started again in order. The prod and QA clusters, both databases (replication resumed on its own) and the app came back with no data loss.
- **Findings:** Nova does not restart VMs after a host boot; Octavia's health manager rebuilt amphorae right after it started and some rebuilds failed, so both load balancers needed a manual `openstack loadbalancer failover` (about 100 s each); `nmbd` fails on every boot (unrelated). OpenStack on `c3` is Debian packages, not Kolla (docs corrected).

### Added
- **Octavia load balancers** (built by hand, doc: `docs/octavia-finance-lb.md`): `finance-lb` (active/standby, two amphorae, flavor `ha`) at 192.168.2.5 for the finance app, `argo-lb` (one amphora) at 192.168.2.113 for Argo CD. Health-checked, round robin over the prod workers. Failover tested: 485 requests, 0 failed while the active amphora was powered off.
- **Workers `w4` and `w5`** in prod; the original `w1` was drained and retired with 0 failed requests, then **a fresh `w1` was added the same day** (private 10.0.1.67, floating 192.168.2.52), so prod is `c1` plus **`w1` to `w5`**. All five are members of both load balancer pools. The four apps were then rolled one at a time so `w1` runs a pod of each (186 requests during the rollouts, 0 failed).
- **Finance app on 3 replicas**, one per node, with required anti-affinity, `PodDisruptionBudget`s, one-at-a-time rollouts and `preStop` drains (finance repo, `k8s/`; doc: `docs/k8s-operations.md`).
- **PostgreSQL replica `db2`** streaming from `db1`; scripts `db-replica-setup.sh` and `db-replication-status.sh`; **replication monitor with ntfy alerts** on the runner (`install-db-monitor.sh`). Doc and runbook: `docs/db-replication.md`.
- **Rehearsed on live prod:** planned switchover both ways (26 s and 23 s of failed writes) and an unplanned crash of `db1` (failover with 0 rows lost; the monitor alerted in about 80 s and again on split brain).
- `docs/ARCHITECTURE.md`, `docs/k8s-operations.md`, `docs/operations-cheatsheet.md`, `docs/terraform-v2-migration.md`, `docs/db-auto-failover-plan.md` (proposal), this changelog and a docs index.
- DNS: `finance.rdulinux.com` (192.168.2.5), `db.rdulinux.com` (alias, TTL 60 s); per-record `ttl` support in the DNS module.

### Changed
- Backups: the backend image now carries the **PostgreSQL 16 client**, matching the 16 server, so dumps restore with plain `psql` (they used to carry a PostgreSQL 17 `SET transaction_timeout` line). Verified: 85/85 tables, row counts identical. Doc: `docs/finance-db-restore.md`.
- Security-group lookups by name instead of hard-coded IDs; `security_group_ids` output reduced to `k8s`.
- `db-replica-setup.sh` no longer appends duplicate `pg_hba` rules (the duplicates were cleaned from both hosts; backups kept as `pg_hba.conf.bak-20261020`).

### Removed
- The `loadbalancer` Terraform role, `cloud-init/haproxy.*`, the temporary `web` role and its security group.

### Not in Terraform (done by hand; see `docs/ARCHITECTURE.md`)
- **`c3` host route** `10.0.1.0/24 via 192.168.2.174` (runtime and in `/etc/network/interfaces`, backup `.bak-20261020`): `c3` can now reach VMs on their private IPs, not only floating IPs. Explained in `docs/c3-host-route.md`.
- All Octavia objects and their floating IPs; Octavia needed `[health_manager] controller_ip_port_list` and `heartbeat_key`, and **both** `octavia-worker` and `octavia-health-manager` must be restarted after any `octavia.conf` change.
- Placement allocation ratios raised (disk 1.5, memory 1.1) and the project core quota set to 64 (two 2 GB amphorae per HA load balancer).
- Kubernetes secret `db-secret` is edited during a database failover; PostgreSQL roles, rules, slot and conf files on `db1`/`db2`; the monitor on the runner.

### Fixed
- `pg_dump` 17 against the 16 server (above). A rollout stuck on a spread constraint that counted the tainted control plane as an empty domain (`nodeTaintsPolicy: Honor`). Argo CD answering with the finance app (a host rule matched only the exact name; now a separate load balancer).
- A load balancer VIP on the amphora management network (members all `ERROR`): the VIP must be on the private subnet.

### Known gaps
No automatic database failover (proposal in `docs/db-auto-failover-plan.md`); single control plane per cluster; NFS on `repo` has no replica; the monitor runs on the runner (no alert if the runner is down); `argo-lb` has one amphora (and a dead amphora is replaced only after 15 minutes); rebuilding two amphorae at once is flaky; `/health` does not test the database.

---

## 2026-10-19: prod Kubernetes cluster rebuilt, names and zones cleaned up

### Breaking changes
- **VM names no longer contain the environment** (`prod-c1` → `c1`). `moved` blocks kept the VMs; the environment is a tag.
- **Per-environment DNS zones:** prod nodes are `<name>.prod.rdulinux.com`, qa nodes `<name>.qa.rdulinux.com`. Shared services stay in `rdulinux.com`.
- The prod cluster was **rebuilt** (nodes `c1`, `w1` to `w3` re-created with proper hostnames and node names). The kubeconfig CA changed; the CI runner's kubeconfig had to be replaced.

### Added
- Rebuild without user-visible outage: workloads **parked on the qa cluster**, haproxy swapped twice (one reload each), data safe on NFS. Procedure and real log: `docs/prod-k8s-rebuild.md`.
- **Backup proof before touching anything:** the finance database backup was restored into a scratch database (85/85 tables, identical row counts), and an **etcd snapshot restore was rehearsed on QA** (`docs/etcd-restore-rehearsal.md`). A safety tarball of NFS uploads and backups went to `backup:/backup/finance-qa/pre-rebuild-20261019/`.
- **etcd snapshot timer** on controllers (cloud-init and `scripts/install-etcd-snapshot.sh`); `scripts/k8s-copy-between.sh` (copy objects between clusters through two kubeconfigs, secrets never on disk); `scripts/install-ingress-nginx.sh`; `scripts/clear-stale-port.sh`; `scripts/openstack-shortcuts.sh` (Env column); a `learn` VM role.

### Changed
- `k8s` security group rules limited to `192.168.2.0/24` and `10.0.1.0/24` (443 and ICMP stay open). Worker join retries 5 times; the join file is per cluster (`/nfsshare/join-<cluster>.sh`); metrics-server patched with `--kubelet-insecure-tls` on new controllers.

---

## 2026-10-17: Terraform v2

### Added / changed
- **Redesigned Terraform** (`infra/` + `environments/{prod,qa}/` + `modules/`): YAML-driven, `for_each` with stable keys so nothing shifts or is recreated, cloud-init composed per role, `ignore_changes` so editing a template never replaces a running VM. Rationale and the migration method: `docs/terraform-v2-migration.md`.
- **State moved from local files to S3 (MinIO)**; keys `openstack/infra/...` and `openstack/<env>/nodes/...`.
- All live VMs **adopted in place** (`scripts/adopt-node.sh`), no recreation; `c2` and the old `w4` to `w6` removed.
- The v1 stacks were retired (`terraform state rm` of 32 and 55 entries) and kept in `../archive/` with a "do not apply" notice. DNS for the `backup` host (192.168.2.4) added.

---

Earlier history (2026-03 to 2026-08: first cluster, GitLab, runner, image paths, timezone) is in `git log`; nothing before the v2 redesign is documented here.
