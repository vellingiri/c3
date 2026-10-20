#!/usr/bin/env bash
# One-time migration of the LIVE etcd group from 3 to 5 members (two more witnesses, `dbw2` and `dbw3`), see docs/db-ha-patroni.md "Five etcd members".
# New nodes are built by Terraform/cloud-init (cloud-init/files/db-ha-node.sh joins the running cluster by itself); what cloud-init cannot do is change
# the machines that already exist, which is what this script is for. Run it from your Mac (ssh as root to db1, db2, dbw1):
#   scripts/db-ha-etcd-grow.sh firewall        BEFORE terraform apply: let the two new addresses reach etcd on the existing members
#   scripts/db-ha-etcd-grow.sh patroni-hosts   AFTER the new members have joined: list all five etcd addresses in Patroni's config (reloaded, no restart)
#   scripts/db-ha-etcd-grow.sh status          members and health
# A node built from the current cloud-init already has all of this; only the three VMs created before the change need it.
set -euo pipefail

EXISTING=(db1 db2 dbw1)
ALL_IPS="10.0.1.191 10.0.1.69 10.0.1.120 10.0.1.121 10.0.1.122"   # db1 db2 dbw1 dbw2 dbw3

firewall() {
  local h set
  set=$(echo "$ALL_IPS" | sed 's/ /, /g')
  for h in "${EXISTING[@]}"; do
    ssh "$h" "sed -i 's/ip saddr != { 127.0.0.1, [0-9., ]* } drop/ip saddr != { 127.0.0.1, $set } drop/' /etc/nftables-etcd.conf && nft -f /etc/nftables-etcd.conf && grep 'dport { 2379' /etc/nftables-etcd.conf"
  done
}

patroni_hosts() {
  local h hosts
  hosts=$(for ip in $ALL_IPS; do printf '%s:2379,' "$ip"; done); hosts=${hosts%,}
  for h in db1 db2; do
    ssh "$h" "python3 - <<PY
import yaml
p='/etc/patroni/config.yml'; d=yaml.safe_load(open(p))
d['etcd3']['hosts']='$hosts'
open(p,'w').write(yaml.safe_dump(d, sort_keys=False))
PY
chown postgres:postgres /etc/patroni/config.yml; chmod 600 /etc/patroni/config.yml
systemctl kill --kill-whom=main -s HUP patroni; sleep 3; grep -A0 '^  hosts' /etc/patroni/config.yml"
  done
  ssh db1 patronictl list
}

status() {
  local eps=""; for ip in $ALL_IPS; do eps+="http://$ip:2379,"; done; eps=${eps%,}
  ssh db1 "ETCDCTL_API=3 etcdctl --endpoints=$eps member list -w table; ETCDCTL_API=3 etcdctl --endpoints=$eps endpoint health -w table 2>&1 | head -10"
}

case "${1:-}" in
  firewall) firewall ;;
  patroni-hosts) patroni_hosts ;;
  status) status ;;
  *) sed -n 2,10p "$0"; exit 2 ;;
esac
