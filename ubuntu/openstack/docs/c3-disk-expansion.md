# c3: more disk for the VMs (new partition for `/var/lib/nova/instances`)

**Status: prepared 2026-10-22, NOT run.** `scripts/c3-nova-disk-move.sh` exists; nothing on c3 has been changed. Needs a maintenance window (all VMs stop for 5 to 10 minutes).

## Why
- The NVMe disk (`/dev/nvme0n1`) is 931.5 GB but only about 170 GB is partitioned: `p1` 139.7 GB `/` (92 GB used, 71 %), `p2` 4.7 GB `/boot/efi`, `p3` 25 GB `/share`, and about **760 GB unallocated after `p3`**.
- Nova's VM disks live on `/` (`/var/lib/nova/instances`, 65 GB). Placement's disk capacity is that filesystem times `disk_allocation_ratio`: 136 GB x 2.5 = **340 GB** (about 300 allocated after the 20 GB root disks of 2026-10-22), which is why the cka VMs and the witness could not be grown too.
- Growing `/` in place is not possible (`p2` and `p3` sit behind it) and moving them on the boot disk is not worth the risk. So: **a new partition `p4` from the free space, mounted at `/var/lib/nova/instances`.**

## Result
- `/` gets 65 GB free again (about 104 GB free, 25 % used).
- A new filesystem of about 760 GB for the VMs: with ratio 2.5 Placement would offer about 1,900 GB. Consider lowering `disk_allocation_ratio` to 1.0 afterwards (thin qcow2 disks can then never overcommit the real disk); with 760 GB real space all current VMs (about 300 GB allocated) fit comfortably either way.
- Then the remaining 10 GB VMs can be grown (cka x4: `m1.small-20g`; `dbw1-prod`: a tiny flavor with 20 GB) the same way as the others.

## How (phases of the script, run as root on c3)
1. `status`: read-only.
2. `prepare` (**no downtime**): creates `p4` (parted, in the free space), `mkfs.ext4 -L nova-instances`, mounts it at `/mnt/nova-new`, first `rsync -aHAXS` of the instances directory while the VMs run.
3. `cutover` (**downtime 5 to 10 min**, typed confirmation): records the running VMs, stops the Octavia health manager (otherwise it fails the amphorae over after 300 s), stops all VMs (Nova API), then `nova-compute` and `libvirtd`, final `rsync --delete`, mounts the new partition at `/var/lib/nova/instances` (fstab by UUID), starts libvirt, nova-compute, the health manager, then the VMs in the order databases, controllers, rest, and waits for ACTIVE. The old directory stays as `/var/lib/nova/instances.old`.
4. After: front doors 200 (`./c3-dr-post.sh check`), `patronictl list`, `kubectl get nodes`, etcd 3/3, `openstack server list`. Then, after a few quiet days, `finish` deletes `instances.old`.

## Rollback (until `finish`)
`umount /var/lib/nova/instances`, delete the fstab line, `mv /var/lib/nova/instances.old /var/lib/nova/instances`, start libvirtd, nova-compute and the VMs. The data of the old directory is untouched by everything above.

## Risks and notes
- The live copy in `prepare` is inconsistent on purpose; only the final copy after the VMs stopped counts.
- After a host reboot everything depends on the new mount being there before libvirt/nova start: the fstab line is a normal (not `nofail`) entry, so a missing partition stops the boot rather than letting Nova create empty instance directories on `/`. Check `docs/c3-reboot.md` ordering (libvirt-guests drop-in) after the move; one clean `systemctl reboot` test is recommended.
- The DR capture (`docs/c3-rebuild.md`) does not back up the VM disks; a rebuilt c3 gets VMs from Terraform. Add `p4` to the layout described there.
- Nothing is changed in Terraform. The flavors for the cka and witness resizes are created when those resizes are done.
