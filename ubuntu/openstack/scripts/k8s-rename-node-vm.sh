#!/usr/bin/env bash
# Rename a Kubernetes node's VM IN PLACE (no rebuild, no re-join): the new naming convention is <role><n>-<env>, e.g. c1-cka, w1-cka.
#   scripts/k8s-rename-node-vm.sh <env> <old name> <new name>        e.g.  scripts/k8s-rename-node-vm.sh cka w3 w3-cka
# What changes: the OpenStack server name, the operating-system hostname, /etc/hosts.
# What deliberately does NOT change: the Kubernetes node name (w3). A node cannot be renamed in Kubernetes (its client certificate, its Node object, and for
# control-plane nodes the etcd member and the static pod names all carry it), and the kubelet takes its node name from the hostname, so BEFORE the hostname
# changes the kubelet is pinned to the old name with `--hostname-override=<old>` in /etc/default/kubelet. Node names only need to be unique inside a cluster.
# DNS and Terraform follow separately: add the node under its new key in environments/<env>/nodes.yaml with a `moved` block (environments/<env>/moved.tf),
# then `terraform apply` replaces only the DNS records. Do control-plane nodes last. Needs the node reachable by ssh under its CURRENT name (<old>.<env>).
set -euo pipefail
ENV_NAME=${1:?env}; OLD=${2:?old name}; NEW=${3:?new name}
KCFG=${KCFG:-$HOME/.kube/$ENV_NAME}
K() { kubectl --kubeconfig "$KCFG" --context "$ENV_NAME" "$@"; }
SSH_OLD="$OLD.$ENV_NAME"

K get node "$OLD" >/dev/null
say() { printf '\n== %s\n' "$*"; }
ID=$(ssh c3 "openstack server list --all-projects --long -f json -c ID -c Name -c Properties" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    p=s['Properties']
    if isinstance(p,str): p=dict(x.split('=',1) for x in p.replace(\"'\",'').split(', ') if '=' in x)
    if p.get('env')=='$ENV_NAME' and s['Name']=='$OLD': print(s['ID'])")
[ -n "$ID" ] && [ "$(echo "$ID" | wc -l | tr -d " ")" = 1 ] || { echo "could not find exactly one server named $OLD in env $ENV_NAME (found: '$ID')" >&2; exit 1; }
echo "$ENV_NAME/$OLD ($ID) -> $NEW"

say "1. pin the kubelet to the node name $OLD"
ssh "$SSH_OLD" "grep -q -- '--hostname-override' /etc/default/kubelet && echo 'already pinned' || { sed -i 's|^KUBELET_EXTRA_ARGS=\(.*\)\$|KUBELET_EXTRA_ARGS=\1 --hostname-override=$OLD|' /etc/default/kubelet; systemctl restart kubelet; }; cat /etc/default/kubelet"
for i in $(seq 1 30); do K get node "$OLD" --no-headers | grep -q " Ready" && break; sleep 4; done
K get node "$OLD" --no-headers | awk '{print "node:",$1,$2}'

say "2. hostname and /etc/hosts"
ssh "$SSH_OLD" "hostnamectl set-hostname '$NEW'; sed -i 's/\b$OLD\b/$NEW/g' /etc/hosts; hostname; grep -m2 '$NEW' /etc/hosts"

say "3. OpenStack server name"
ssh c3 "openstack server set --name '$NEW' $ID && openstack server show $ID -f value -c name"

say "4. check: the kubelet still reports the node as $OLD"
sleep 5
K get node "$OLD" --no-headers | awk '{print "node:",$1,$2}'
echo "Done. Reach it as ssh $NEW (alias *-$ENV_NAME in ~/.ssh/config) once DNS has the new name (terraform apply), or by its old DNS name until then."
