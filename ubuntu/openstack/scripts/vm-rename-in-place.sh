#!/usr/bin/env bash
# Rename a (non-Kubernetes) VM IN PLACE to the convention <role><n>-<env>: OpenStack server name, hostname, /etc/hosts. No rebuild, no service restart.
#   scripts/vm-rename-in-place.sh <env> <old name> <new name> <ssh target of the VM now>      e.g.  scripts/vm-rename-in-place.sh prod db2 db2-prod db2
# Names that systems use INTERNALLY are separate from the VM's name and are NOT touched: the etcd member and Patroni member names (db1, db2, dbw1 are fixed in
# /etc/default/etcd and /etc/patroni/config.yml), PostgreSQL has no hostname dependence (pg_hba and all connections use addresses), the GitHub runner's registered
# name is `finance-runner`. For Kubernetes nodes use scripts/k8s-rename-node-vm.sh (the kubelet must be pinned to its node name first).
# DNS follows with `terraform apply` (moved.tf + nodes.yaml); until then the ssh alias must point at the floating IP.
set -euo pipefail
ENV_NAME=${1:?env}; OLD=${2:?old name}; NEW=${3:?new name}; TARGET=${4:?ssh target}
ID=$(ssh c3 "openstack server list --all-projects --long -f json -c ID -c Name -c Properties" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    p=s['Properties']
    if isinstance(p,str): p=dict(x.split('=',1) for x in p.replace(\"'\",'').split(', ') if '=' in x)
    if p.get('env')=='$ENV_NAME' and s['Name']=='$OLD': print(s['ID'])")
[ -n "$ID" ] && [ "$(echo "$ID" | wc -l | tr -d ' ')" = 1 ] || { echo "could not find exactly one server $OLD in env $ENV_NAME (found '$ID')" >&2; exit 1; }
echo "$ENV_NAME/$OLD ($ID) -> $NEW"
ssh "$TARGET" "hostnamectl set-hostname '$NEW'; sed -i 's/\\b$OLD\\b/$NEW/g' /etc/hosts; hostname; grep -m1 '$NEW' /etc/hosts || true"
ssh c3 "openstack server set --name '$NEW' $ID && openstack server show $ID -f value -c name"
