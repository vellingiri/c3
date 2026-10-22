#!/usr/bin/env bash
# Start the VMs that c3-vms-stop.sh stopped, in the right order, and the Octavia health manager.  RUN ON c3 AS ROOT.
#   c3-vms-start.sh [--list FILE] [--with-cka] [--dry-run]
# Order: witness (dbw1) and the databases (db1, db2) first, then the control planes, then the amphorae and the workers, then the runner.
# The list is /root/vm-start-list.txt (written by c3-vms-stop.sh); without it, every SHUTOFF VM except the cka ones is started.
# --with-cka also starts the cka VMs (stopped on purpose to save memory; they are not started otherwise).
# At the end it waits for ACTIVE, starts the health manager and prints the checks to run (Patroni, etcd, nodes, front doors).
set -euo pipefail
LIST=${VM_LIST:-/root/vm-start-list.txt}; CKA=0; DRY=0
while [ $# -gt 0 ]; do case "$1" in --list) LIST=$2; shift ;; --with-cka) CKA=1 ;; --dry-run) DRY=1 ;; *) echo "usage: $0 [--list FILE] [--with-cka] [--dry-run]" >&2; exit 2 ;; esac; shift; done
# shellcheck disable=SC1091
source /root/.bashrc >/dev/null 2>&1 || true
OS() { openstack "$@" 2>/dev/null; }
rank() { case "$1" in dbw*) echo 1 ;; db[0-9]*) echo 2 ;; c[0-9]*) echo 3 ;; ci*|runner*) echo 5 ;; *) echo 4 ;; esac; }   # amphorae and workers = 4

if [ -s "$LIST" ]; then awk '{print $2}' "$LIST" > /tmp/vm-ids.$$
else OS server list --all-projects --status SHUTOFF -f value -c ID | cat > /tmp/vm-ids.$$; echo "(no $LIST: using every SHUTOFF VM)"; fi
: > /tmp/vm-todo.$$
while read -r id; do
  [ -n "$id" ] || continue
  name=$(OS server show "$id" -f value -c name); st=$(OS server show "$id" -f value -c status)
  case "$name" in *-cka) [ $CKA = 1 ] || continue ;; esac
  [ "$st" = SHUTOFF ] || { echo "skip $name ($st)"; continue; }
  echo "$(rank "$name") $id $name" >> /tmp/vm-todo.$$
done < /tmp/vm-ids.$$
sort -n /tmp/vm-todo.$$ -o /tmp/vm-todo.$$
echo "will start $(wc -l < /tmp/vm-todo.$$ | tr -d ' ') VMs:"; awk '{print "  " $3}' /tmp/vm-todo.$$ | tr '\n' ' '; echo
[ $DRY = 1 ] && { rm -f /tmp/vm-ids.$$ /tmp/vm-todo.$$; echo "(dry run: nothing started)"; exit 0; }

prev=""
while read -r r id name; do
  if [ -n "$prev" ] && [ "$r" != "$prev" ]; then
    echo "-- waiting for tier $prev to be ACTIVE"; sleep 25
  fi
  OS server start "$id" || true; echo "start $name"; prev=$r
done < /tmp/vm-todo.$$
for _ in $(seq 1 90); do
  n=$(while read -r _ id _; do OS server show "$id" -f value -c status; done < /tmp/vm-todo.$$ | grep -vc ACTIVE || true)
  [ "$n" = 0 ] && break; sleep 5
done
echo "not yet ACTIVE: ${n:-?}"
systemctl start octavia-health-manager 2>/dev/null && echo "octavia-health-manager started" || echo "(no octavia-health-manager unit)"
rm -f /tmp/vm-ids.$$ /tmp/vm-todo.$$
cat <<'T'
Checks (a minute or two after the VMs are up):
  ssh db1-prod patronictl -c /etc/patroni/config.yml list          # one Leader, one Sync Standby, lag 0
  kubectl get nodes                                              # all Ready (control planes need a few minutes)
  curl -s -o /dev/null -w '%{http_code}\n' http://finance.rdulinux.com/health    # 200
  openstack loadbalancer list                                    # ONLINE (cka-api stays in ERROR while cka is off)
T
