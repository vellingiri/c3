#!/usr/bin/env bash
# Stop every running VM on c3 in a safe order, and remember which ones ran so c3-vms-start.sh can bring back exactly those.  RUN ON c3 AS ROOT.
#   c3-vms-stop.sh [--yes] [--dry-run]
# 1. stops the Octavia health manager (otherwise it fails the amphorae over after heartbeat_timeout = 300 s and builds new ones),
# 2. writes the list of ACTIVE VMs to /root/vm-start-list.txt (the cka VMs are only in it if they were running),
# 3. stops them gracefully, applications first and the data last: runner, workers, amphorae, control planes, databases, witness,
# 4. waits until libvirt shows no guest.
# Use before: planned host maintenance, disk work, `systemctl poweroff` of c3. For a normal reboot you do not need it (libvirt-guests stops the guests).
set -euo pipefail
LIST=${VM_LIST:-/root/vm-start-list.txt}; YES=0; DRY=0
for a in "$@"; do case "$a" in --yes) YES=1 ;; --dry-run) DRY=1 ;; *) echo "usage: $0 [--yes] [--dry-run]" >&2; exit 2 ;; esac; done
# shellcheck disable=SC1091
source /root/.bashrc >/dev/null 2>&1 || true
OS() { openstack "$@" </dev/null 2>/dev/null; }   # </dev/null: when the script is piped through ssh, openstack must not read the script from stdin (made the start script die silently on 2026-10-22)
# stop rank: smaller = earlier
rank() { case "$1" in ci*|runner*) echo 1 ;; w[0-9]*) echo 2 ;; amphora-*) echo 3 ;; c[0-9]*) echo 4 ;; db[0-9]*) echo 5 ;; dbw*) echo 6 ;; *) echo 3 ;; esac; }

OS server list --all-projects --status ACTIVE -f value -c ID -c Name | while read -r id name; do echo "$(rank "$name") $id $name"; done | sort -n > "$LIST.new"
[ -s "$LIST.new" ] || { echo "no ACTIVE VMs"; rm -f "$LIST.new"; exit 0; }
echo "will stop $(wc -l < "$LIST.new" | tr -d ' ') VMs (stop order):"; awk '{print "  " $3}' "$LIST.new" | tr '\n' ' '; echo
[ $DRY = 1 ] && { rm -f "$LIST.new"; echo "(dry run: nothing stopped)"; exit 0; }
if [ $YES = 0 ]; then read -r -p "Stop all of them? Everything (finance, argo, databases, kubectl) goes down. Type 'stop': " a; [ "$a" = stop ] || { rm -f "$LIST.new"; echo cancelled; exit 1; }; fi
mv "$LIST.new" "$LIST"; echo "start list saved in $LIST"

systemctl stop octavia-health-manager 2>/dev/null && echo "octavia-health-manager stopped (start it again with c3-vms-start.sh)" || echo "(no octavia-health-manager unit)"
prev=""
while read -r r id name; do
  if [ -n "$prev" ] && [ "$r" != "$prev" ]; then sleep 20; fi   # let one tier finish its shutdown before the next one gets its signal
  OS server stop "$id" || true; echo "stop $name"; prev=$r
done < "$LIST"
for _ in $(seq 1 90); do [ "$(virsh list --name | grep -c .)" = 0 ] && break; sleep 3; done
left=$(virsh list --name | grep -c . || true)
[ "$left" = 0 ] && echo "all guests are off" || { echo "STILL RUNNING in libvirt: $(virsh list --name | tr '\n' ' ')" >&2; exit 1; }
