#!/usr/bin/env bash
# Take witnesses OUT of the database HA etcd group, safely (the reverse of db-ha-etcd-grow.sh). Run from your Mac (ssh as root to db1, db2, dbw1):
#   scripts/db-ha-etcd-shrink.sh check                 read-only: Patroni and etcd state, which members would be removed
#   scripts/db-ha-etcd-shrink.sh apply dbw3 dbw2       remove the named witnesses from etcd one at a time (5 -> 4 -> 3 voters), then
#                                                      list only the remaining addresses in Patroni's config and the etcd firewall
# THEN (by you): comment the VMs out of environments/prod/nodes.yaml and `terraform apply`. Never destroy the VM first: its etcd member would
# stay in the cluster, count as a voter that is gone and can take the majority with it (this is what happened to cka on 2026-10-21).
# Keep the voter count ODD (3 or 5): 4 voters survive no more failures than 3 and can split 2/2. Refuses to go below 3 voters.
set -euo pipefail

# name=address of every voter that may exist; db1 and db2 are never removed
declare_all() { ALL="db1=10.0.1.191 db2=10.0.1.69 dbw1=10.0.1.120 dbw2=10.0.1.121 dbw3=10.0.1.122"; }
declare_all
ip_of() { for p in $ALL; do [ "${p%%=*}" = "$1" ] && echo "${p#*=}"; done; }
etcdctl() { ssh db1 "ETCDCTL_API=3 etcdctl --endpoints=http://10.0.1.191:2379 $*"; }
members() { etcdctl member list | awk -F', ' '{print $3"="$1}'; }       # name=id
healthy_count() { local n=0 p; for p in $ALL; do ssh -o ConnectTimeout=5 db1 "ETCDCTL_API=3 etcdctl --endpoints=http://${p#*=}:2379 --command-timeout=4s endpoint health" 2>&1 | grep -q "is healthy" && n=$((n+1)); done; echo $n; }

check() {
  echo "-- Patroni"; ssh db1 patronictl list | grep -E "db1|db2"
  echo "-- etcd members (name=id)"; members | tr '\n' ' '; echo
  echo "-- healthy endpoints among the known addresses: $(healthy_count)"
}

apply() {
  [ $# -ge 1 ] || { echo "name the witnesses to remove" >&2; exit 2; }
  for w in "$@"; do case "$w" in db1|db2) echo "refusing to remove $w" >&2; exit 1 ;; dbw1|dbw2|dbw3) ;; *) echo "unknown $w" >&2; exit 1 ;; esac; done
  local total; total=$(members | wc -l | tr -d ' ')
  [ $((total - $#)) -ge 3 ] || { echo "that would leave $((total - $#)) voters (minimum 3)" >&2; exit 1; }
  [ $(( (total - $#) % 2 )) = 1 ] || { echo "that would leave an EVEN number of voters ($((total - $#))); remove 2 at a time from 5, or 1 from 4" >&2; exit 1; }
  ssh db1 patronictl list | grep -q "Leader" && ssh db1 patronictl list | grep -q -E "Replica|Sync Standby" || { echo "Patroni is not healthy (need a leader and a replica); stopping" >&2; exit 1; }
  [ "$(healthy_count)" = "$total" ] || { echo "etcd: not all $total members are healthy; stopping" >&2; exit 1; }

  # remaining addresses
  local keep="" p n
  for p in $ALL; do n=${p%%=*}; case " $* " in *" $n "*) ;; *) members | grep -q "^$n=" && keep+="${p#*=} " ;; esac; done
  echo "remaining voters: $keep"

  echo "== 1. Patroni lists only the remaining etcd addresses (reloaded, no restart)"
  local hosts; hosts=$(for a in $keep; do printf '%s:2379,' "$a"; done); hosts=${hosts%,}
  for h in db1 db2; do
    ssh "$h" "python3 - <<PY
import yaml
p='/etc/patroni/config.yml'; d=yaml.safe_load(open(p)); d['etcd3']['hosts']='$hosts'
open(p,'w').write(yaml.safe_dump(d, sort_keys=False))
PY
chown postgres:postgres /etc/patroni/config.yml; chmod 600 /etc/patroni/config.yml; systemctl kill --kill-whom=main -s HUP patroni"
  done
  sleep 5; ssh db1 patronictl list | grep -E "db1|db2"

  echo "== 2. remove the members from etcd, one at a time"
  for w in "$@"; do
    id=$(members | awk -F= -v n="$w" '$1==n{print $2}')
    if [ -z "$id" ]; then echo "$w is not an etcd member (already removed)"; continue; fi
    etcdctl member remove "$id"
    sleep 5
    echo "   removed $w; healthy: $(healthy_count) endpoints answer (the removed one may still answer until its VM is destroyed)"
    ssh db1 patronictl list | grep -E "db1|db2"
  done

  echo "== 3. etcd firewall on the remaining machines allows only the remaining voters"
  local set; set=$(echo "$keep" | sed 's/ *$//; s/ /, /g')
  for h in db1 db2 dbw1; do
    ssh "$h" "sed -i 's/ip saddr != { 127.0.0.1, [0-9., ]* } drop/ip saddr != { 127.0.0.1, $set } drop/' /etc/nftables-etcd.conf && nft -f /etc/nftables-etcd.conf" || echo "(firewall on $h not changed)"
  done
  echo "== done. etcd members now:"; members | tr '\n' ' '; echo
  echo "Next: comment $* out in environments/prod/nodes.yaml, terraform apply; update WITNESS in scripts/db-replication-monitor.sh and install it on the runner."
}

case "${1:-}" in
  check) check ;;
  apply) shift; apply "$@" ;;
  *) sed -n 2,9p "$0"; exit 2 ;;
esac
