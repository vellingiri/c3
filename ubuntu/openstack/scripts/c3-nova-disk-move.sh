#!/usr/bin/env bash
# Move Nova's state directory /var/lib/nova (VM disks in instances/, 65 GB, plus compute_id, CA, keys) from the 140 GB root partition to its OWN partition.
# YOU create the partition and filesystem first (commands in docs/c3-disk-expansion.md) and mount it at /mnt/nova-new; this script only copies and switches.
# RUN ON c3 AS ROOT. Why and the design: docs/c3-disk-expansion.md. Nothing here runs by itself; each phase is started by hand.
#
#   c3-nova-disk-move.sh status      read-only: disk layout, free space, instances size, what each phase would do
#   c3-nova-disk-move.sh prepare     NO DOWNTIME: checks that your new filesystem is mounted at /mnt/nova-new and empty, first copy of /var/lib/nova
#                                    while the VMs run (a live copy, only a head start)
#   c3-nova-disk-move.sh cutover     DOWNTIME (about 5 to 10 min): stops every VM (the Octavia health manager is stopped too, so the amphorae are not
#                                    failed over), stops nova-compute and libvirtd, final copy, mounts the new partition at /var/lib/nova (fstab by UUID),
#                                    starts everything again in the right order, waits for ACTIVE. The old directory is kept as /var/lib/nova.old
#   c3-nova-disk-move.sh finish      later (after a few quiet days): deletes /var/lib/nova.old
# Rollback until `finish`: umount /var/lib/nova; remove its fstab line; rmdir /var/lib/nova; mv /var/lib/nova.old /var/lib/nova; start libvirtd, nova-compute, the VMs.
# Admin credentials: sourced from /root/.bashrc like the other c3 helpers. Needs: parted, rsync, openstack CLI.
set -euo pipefail
SRC=/var/lib/nova; NEW=/mnt/nova-new; STATE=/root/nova-disk-move
mkdir -p "$STATE"
# shellcheck disable=SC1091
source /root/.bashrc >/dev/null 2>&1 || true
say() { printf '\n== %s\n' "$*"; }
die() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root on c3"
OS() { openstack "$@" 2>/dev/null; }

status() {
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT
  df -h / "$SRC" "$NEW" 2>/dev/null | sort -u
  du -sh "$SRC" 2>/dev/null
  mount | grep -E " $NEW | $SRC " || echo "(neither $NEW nor a separate $SRC is mounted)"
  grep -n -E " /var/lib/nova " /etc/fstab || echo "(no fstab line for /var/lib/nova yet)"
  echo "ACTIVE VMs: $(OS server list --all-projects --status ACTIVE -f value -c Name | wc -l)"
}

prepare() {
  mountpoint -q "$NEW" || die "mount your new filesystem at $NEW first (docs/c3-disk-expansion.md)"
  [ "$(findmnt -no SOURCE "$NEW")" != "$(findmnt -no SOURCE /)" ] || die "$NEW is on the root filesystem"
  [ -z "$(ls -A "$NEW" | grep -v '^lost+found$')" ] || die "$NEW is not empty"
  AVAIL=$(df -BG --output=avail "$NEW" | tail -1 | tr -dc 0-9); [ "$AVAIL" -gt 150 ] || die "only ${AVAIL} GB on $NEW; expected hundreds"
  say "first copy of $SRC (VMs keep running; inconsistent by itself, only a head start)"
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
  NOVA_SVCS="nova-api nova-api-metadata nova-conductor nova-scheduler nova-novncproxy nova-serialproxy"
  systemctl stop $NOVA_SVCS nova-compute libvirt-guests libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket   # nothing may hold files in /var/lib/nova while it is swapped
  say "final copy"
  rsync -aHAXS --delete --info=stats1 "$SRC"/ "$NEW"/ | tail -4
  say "switch"
  DEV=$(findmnt -no SOURCE "$NEW"); FST=$(findmnt -no FSTYPE "$NEW"); UUID=$(blkid -s UUID -o value "$DEV")
  umount "$NEW"; mv "$SRC" "$SRC.old"; mkdir "$SRC"
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $SRC $FST defaults 0 2   # nova state, moved off / ($(date +%F))" >> /etc/fstab
  systemctl daemon-reload; mount "$SRC"; mountpoint -q "$SRC" || die "mount failed; rollback: rmdir $SRC; mv $SRC.old $SRC"
  chown nova:nova "$SRC"; chmod 755 "$SRC"; df -h "$SRC" | tail -1
  say "start libvirt, nova-compute and the other nova services"
  systemctl start libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket libvirtd libvirt-guests nova-compute $NOVA_SVCS
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
