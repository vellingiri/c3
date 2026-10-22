#!/usr/bin/env bash
# Build (or check) the 3-member etcd cluster that Patroni uses to decide which database is primary.
#   scripts/db-ha-etcd.sh install      install and start etcd on db1, db2 and dbw1 (first time: forms a NEW cluster)
#   scripts/db-ha-etcd.sh status       member list and health
# Run from your Mac (ssh as root to the three hosts). Design and reasons: docs/db-ha-patroni.md.
#
# etcd listens on the private IP only and a host firewall (nftables table "etcd_guard") drops port 2379/2380 and Patroni's 8008 from
# anything outside 10.0.1.0/24 (2379/2380: only the three members and localhost), because etcd here has no TLS and no login.
# "install" refuses to run when a cluster already exists on a host (a data directory is present): re-forming would lose the leader key.
set -euo pipefail

HOSTS=(db1 db2 dbw1)
TOKEN=finance-db-ha

ip_of() { ssh "$1" "hostname -I | awk '{print \$1}'"; }

status() {
  local eps="" h
  for h in "${HOSTS[@]}"; do eps+="http://$(ip_of "$h"):2379,"; done
  eps=${eps%,}
  ssh db1 "ETCDCTL_API=3 etcdctl --endpoints=$eps member list -w table; ETCDCTL_API=3 etcdctl --endpoints=$eps endpoint health -w table 2>&1 | head -8"
}

install() {
  # (plain arrays: macOS ships bash 3.2, which has no associative arrays)
  local IPS=() i h cluster="" members=""
  for h in "${HOSTS[@]}"; do IPS+=("$(ip_of "$h")"); done
  for i in $(seq 0 $((${#HOSTS[@]}-1))); do cluster+="${HOSTS[$i]}=http://${IPS[$i]}:2380,"; members+="${IPS[$i]},"; done
  cluster=${cluster%,}; members=${members%,}
  echo "cluster: $cluster"
  for h in "${HOSTS[@]}"; do
    if ssh "$h" "test -d /var/lib/etcd/db-ha"; then echo "$h already has /var/lib/etcd/db-ha; refusing to re-form the cluster (use 'status')" >&2; exit 1; fi
  done
  for i in $(seq 0 $((${#HOSTS[@]}-1))); do
    h=${HOSTS[$i]}; ip=${IPS[$i]}
    echo "== $h ($ip): packages, config, firewall"
    ssh "$h" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq etcd-server etcd-client nftables >/dev/null 2>&1; systemctl stop etcd; rm -rf /var/lib/etcd/default"
    ssh "$h" "cat > /etc/default/etcd" <<ETCDENV
# managed by scripts/db-ha-etcd.sh (docs/db-ha-patroni.md)
ETCD_NAME=$h
ETCD_DATA_DIR=/var/lib/etcd/db-ha
ETCD_LISTEN_PEER_URLS=http://$ip:2380
ETCD_LISTEN_CLIENT_URLS=http://$ip:2379,http://127.0.0.1:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=http://$ip:2380
ETCD_ADVERTISE_CLIENT_URLS=http://$ip:2379
ETCD_INITIAL_CLUSTER=$cluster
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=$TOKEN
ETCD_HEARTBEAT_INTERVAL=250
ETCD_ELECTION_TIMEOUT=2500
ETCD_AUTO_COMPACTION_MODE=periodic
ETCD_AUTO_COMPACTION_RETENTION=1h
ETCD_QUOTA_BACKEND_BYTES=536870912
ETCDENV
    ssh "$h" "cat > /etc/nftables-etcd.conf" <<NFT
# managed by scripts/db-ha-etcd.sh: etcd has no TLS and no login, so only the three members may reach it; Patroni's REST port only the private subnet
table inet etcd_guard
delete table inet etcd_guard
table inet etcd_guard {
  chain input {
    type filter hook input priority -10; policy accept;
    tcp dport { 2379, 2380 } ip saddr != { 127.0.0.1, $members } drop
    tcp dport 8008 ip saddr != { 127.0.0.1, 10.0.1.0/24 } drop
  }
}
NFT
    ssh "$h" 'grep -q "nftables-etcd.conf" /etc/nftables.conf || echo "include \"/etc/nftables-etcd.conf\"" >> /etc/nftables.conf; nft -f /etc/nftables-etcd.conf; systemctl enable nftables >/dev/null 2>&1'
  done
  echo "== start all three together (a new cluster needs a majority up within a few seconds)"
  for h in "${HOSTS[@]}"; do ssh "$h" "systemctl enable etcd >/dev/null 2>&1; systemctl restart etcd" & done
  wait
  sleep 6
  status
}

case "${1:-}" in
  install) install ;;
  status) status ;;
  *) sed -n 2,12p "$0"; exit 2 ;;
esac
