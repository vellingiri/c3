#!/usr/bin/env bash
# Move Nova's VM disks (/var/lib/nova/instances, 65 GB on the 140 GB root partition) to their own partition made from the free space on the NVMe disk.
# RUN ON c3 AS ROOT. Why and the design: docs/c3-disk-expansion.md. Nothing here runs by itself; each phase is started by hand.
#
#   c3-nova-disk-move.sh status      read-only: disk layout, free space, instances size, what each phase would do
#   c3-nova-disk-move.sh prepare     NO DOWNTIME: new partition (p4) in the free space, ext4 labelled nova-instances, mounted at /mnt/nova-new,
#                                    first copy of the instances directory while the VMs run (a live copy, only a head start)
#   c3-nova-disk-move.sh cutover     DOWNTIME (about 5 to 10 min): stops every VM (the Octavia health manager is stopped too, so the amphorae are not
#                                    failed over), stops nova-compute and libvirtd, final copy, mounts the new partition at /var/lib/nova/instances (fstab by UUID),
#                                    starts everything again in the right order, waits for ACTIVE. The old directory is kept as /var/lib/nova/instances.old
#   c3-nova-disk-move.sh finish      later (after a few quiet days): deletes /var/lib/nova/instances.old
# Rollback until `finish`: umount /var/lib/nova/instances; remove its fstab line; mv /var/lib/nova/instances.old /var/lib/nova/instances; start libvirtd, nova-compute, the VMs.
# Admin credentials: sourced from /root/.bashrc like the other c3 helpers. Needs: parted, rsync, openstack CLI.
set -euo pipefail
DISK=/dev/nvme0n1; PART=${DISK}p4; LABEL=nova-instances
SRC=/var/lib/nova/instances; NEW=/mnt/nova-new; STATE=/root/nova-disk-move
mkdir -p "$STATE"
# shellcheck disable=SC1091
source /root/.bashrc >/dev/null 2>&1 || true
say() { printf '\n== %s\n' "$*"; }
die() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root on c3"
OS() { openstack "$@" 2>/dev/null; }

status() {
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
  parted -s "$DISK" unit GB print free | tail -8
  df -h / "$SRC" | tail -2; du -sh "$SRC" 2>/dev/null
  mount | grep -E "$NEW|$SRC" || echo "(neither $NEW nor a separate $SRC is mounted)"
  grep -n nova-instances /etc/fstab || echo "(no fstab line yet)"
  echo "ACTIVE VMs: $(OS server list --all-projects --status ACTIVE -f value -c Name | wc -l)"
}

prepare() {
  [ ! -e "$PART" ] || die "$PART already exists; look at 'status'"
  FREE=$(parted -s "$DISK" unit MiB print free | awk '/Free Space/ {s=$1; e=$2; sz=$3} END {print s, e, sz}')
  echo "last free area (start end size): $FREE"
  START=$(echo "$FREE" | awk '{gsub("MiB","",$1); print $1}'); SIZE=$(echo "$FREE" | awk '{gsub("MiB","",$3); print int($3)}')
  [ "$SIZE" -gt 102400 ] || die "less than 100 GB free at the end of $DISK ($SIZE MiB)"
  say "create $PART from ${START}MiB to the end of the disk ($((SIZE/1024)) GB)"
  parted -s -a optimal "$DISK" mkpart "$LABEL" ext4 "${START}MiB" 100%
  partprobe "$DISK"; sleep 2; [ -b "$PART" ] || die "$PART did not appear"
  mkfs.ext4 -q -L "$LABEL" -m 1 "$PART"
  mkdir -p "$NEW"; mount "$PART" "$NEW"
  say "first copy (VMs keep running; this copy is inconsistent by itself and only saves time later)"
  rsync -aHAXS --info=progress2 "$SRC"/ "$NEW"/
  df -h "$NEW" | tail -1
  echo "prepare done. Next: pick a window and run 'cutover'."
}

cutover() {
  mountpoint -q "$NEW" || die "$NEW is not mounted: run 'prepare' first"
  ORDER=$STATE/vm-order.txt
  say "list of running VMs (start order: databases, controllers, the rest)"
  OS server list --all-projects --status ACTIVE -f value -c ID -c Name | awk '{print ($2 ~ /^db|^dbw/ ? 1 : ($2 ~ /^c[0-9]/ ? 2 : 3)), $1, $2}' | sort -n > "$ORDER"
  cat "$ORDER"
  read -r -p "Stop all of these, copy and switch? Type 'cutover' to go on: " a; [ "$a" = cutover ] || die "cancelled"
  say "stop the Octavia health manager (amphorae must not be failed over while they are down)"
  systemctl stop octavia-health-manager 2>/dev/null || echo "(no octavia-health-manager unit here)"
  say "stop the VMs (reverse order)"
  tac "$ORDER" | while read -r _ id name; do OS server stop "$id" || true; echo "stop $name"; done
  for _ in $(seq 1 60); do [ "$(virsh list --name | grep -c .)" = 0 ] && break; sleep 3; done
  [ "$(virsh list --name | grep -c .)" = 0 ] || die "VMs still running in libvirt: $(virsh list --name | tr '\n' ' ')"
  say "stop nova-compute and libvirt"
  systemctl stop nova-compute libvirt-guests libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket
  say "final copy"
  rsync -aHAXS --delete --info=stats1 "$SRC"/ "$NEW"/ | tail -4
  say "switch"
  umount "$NEW"; mv "$SRC" "$SRC.old"; mkdir "$SRC"
  UUID=$(blkid -s UUID -o value "$PART")
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $SRC ext4 defaults 0 2   # nova-instances ($(date +%F))" >> /etc/fstab
  systemctl daemon-reload; mount "$SRC"; mountpoint -q "$SRC" || die "mount failed; rollback: mv $SRC.old $SRC"
  chown nova:nova "$SRC"; chmod 755 "$SRC"; df -h "$SRC" | tail -1
  say "start libvirt and nova-compute"
  systemctl start libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket libvirtd libvirt-guests nova-compute
  for _ in $(seq 1 30); do OS compute service list --service nova-compute -f value -c State | grep -q up && break; sleep 4; done
  systemctl start octavia-health-manager 2>/dev/null || true
  say "start the VMs"
  while read -r _ id name; do OS server start "$id" || true; echo "start $name"; sleep 3; done < "$ORDER"
  for _ in $(seq 1 60); do [ "$(OS server list --all-projects --status SHUTOFF -f value -c ID | wc -l)" = 0 ] && break; sleep 5; done
  OS server list --all-projects -f value -c Name -c Status | sort | awk '{print "  " $0}'
  say "Placement now"; OS resource provider usage show "$(OS resource provider list -f value -c uuid | head -1)" || true
  echo "cutover done. Check the front doors, then 'finish' after a few days."
}

finish() { [ -d "$SRC.old" ] || die "nothing to delete"; mountpoint -q "$SRC" || die "$SRC is not a separate mount: do not delete the old copy"; du -sh "$SRC.old"; read -r -p "Delete $SRC.old? (yes) " a; [ "$a" = yes ] && rm -rf "$SRC.old"; }

case "${1:-status}" in status) status ;; prepare) prepare ;; cutover) cutover ;; finish) finish ;; *) die "usage: $0 status|prepare|cutover|finish" ;; esac
