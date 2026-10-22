# c3: more disk for the VMs (new partition for `/var/lib/nova/instances`)

**Status: prepared 2026-10-22, NOT run.** The partition is created and mounted by the owner (below); `scripts/c3-nova-disk-move.sh` then copies and switches. Nothing on c3 has been changed by this document. Needs a maintenance window (all VMs stop for 5 to 10 minutes).

## Why
- The NVMe disk (`/dev/nvme0n1`) is 931.5 GB but only about 170 GB is partitioned: `p1` 139.7 GB `/` (92 GB used, 71 %), `p2` 4.7 GB `/boot/efi`, `p3` 25 GB `/share`, and about **760 GB unallocated after `p3`**.
- Nova's state lives on `/`: `/var/lib/nova` (65 GB, nearly all of it `instances/`, plus `compute_id`, `CA`, `keys`). Placement's disk capacity is that filesystem times `disk_allocation_ratio`: 136 GB x 2.5 = **340 GB** (about 300 allocated after the 20 GB root disks of 2026-10-22), which is why the cka VMs and the witness could not be grown too.
- Growing `/` in place is not possible (`p2` and `p3` sit behind it) and moving them on the boot disk is not worth the risk. So: **a new partition `p4` from the free space, mounted at `/var/lib/nova` (the whole directory).**

## Result
- `/` gets 65 GB free again (about 104 GB free, 25 % used).
- A new filesystem of about 760 GB for the VMs: with ratio 2.5 Placement would offer about 1,900 GB. Consider lowering `disk_allocation_ratio` to 1.0 afterwards (thin qcow2 disks can then never overcommit the real disk); with 760 GB real space all current VMs (about 300 GB allocated) fit comfortably either way.
- Then the remaining 10 GB VMs can be grown (cka x4: `m1.small-20g`; `dbw1-prod`: a tiny flavor with 20 GB) the same way as the others.

## How
**1. You create the partition and the filesystem (no downtime, nothing else is touched)** as root on c3:
```bash
parted /dev/nvme0n1 unit GB print free         # the last "Free Space" line is the unallocated area after p3
parted -a optimal /dev/nvme0n1 mkpart nova ext4 <START>GB 100%      # START = start of that last free area, e.g. 170GB
partprobe /dev/nvme0n1; lsblk /dev/nvme0n1       # p4 appears
mkfs.ext4 -L nova -m 1 /dev/nvme0n1p4
mkdir -p /mnt/nova-new && mount /dev/nvme0n1p4 /mnt/nova-new
```
(`-m 1` keeps only 1 % reserved. You may use less than the whole free area, or xfs; the script copies to whatever is mounted at `/mnt/nova-new`.)

**2. The script (as root on c3):**
- `status`: read-only.
- `prepare` (**no downtime**): checks that `/mnt/nova-new` is a separate, empty filesystem, then a first `rsync -aHAXS` of `/var/lib/nova` while the VMs run.
- `cutover` (**downtime 5 to 10 min**, typed confirmation): records the running VMs, stops the Octavia health manager (otherwise it fails the amphorae over after 300 s), stops all VMs (Nova API), the nova services, `nova-compute` and `libvirtd`, final `rsync --delete`, mounts the new partition at `/var/lib/nova` (fstab by UUID), starts libvirt, nova-compute and the other nova services, the health manager, then the VMs in the order databases, controllers, rest, and waits for ACTIVE. The old directory stays as `/var/lib/nova.old`.
- After: front doors 200 (`./c3-dr-post.sh check`), `patronictl list`, `kubectl get nodes`, etcd 3/3, `openstack server list`. After a few quiet days, `finish` deletes `/var/lib/nova.old`.

## Rollback (until `finish`)
`umount /var/lib/nova`, delete the fstab line, `rmdir /var/lib/nova; mv /var/lib/nova.old /var/lib/nova`, start libvirtd, the nova services and the VMs. The data of the old directory is untouched by everything above.

## Risks and notes
- The live copy in `prepare` is inconsistent on purpose; only the final copy after the VMs stopped counts.
- After a host reboot everything depends on the new mount being there before libvirt/nova start: the fstab line is a normal (not `nofail`) entry, so a missing partition stops the boot rather than letting Nova create empty instance directories on `/`. Check `docs/c3-reboot.md` ordering (libvirt-guests drop-in) after the move; one clean `systemctl reboot` test is recommended.
- The DR capture (`docs/c3-rebuild.md`) does not back up the VM disks; a rebuilt c3 gets VMs from Terraform. Add `p4` to the layout described there.
- Nothing is changed in Terraform. The flavors for the cka and witness resizes are created when those resizes are done.
