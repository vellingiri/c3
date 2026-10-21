#!/usr/bin/env bash
# Take a node out of a Kubernetes cluster PROPERLY, before its VM is removed from nodes.yaml / destroyed:
#   scripts/k8s-retire-node.sh <env> <node>          e.g.  scripts/k8s-retire-node.sh cka c3      or   prod w3
# 1. cordon and drain it (pods move to other nodes; a worker needs the cluster to have room: prod has exactly three workers, so draining one waits
#    for the PodDisruptionBudgets and leaves pods Pending until it is back: retire a prod worker only after adding one first),
# 2. if it is a CONTROL-PLANE node: remove its etcd member while etcd still has its majority (skip this and etcd keeps counting a member that no
#    longer exists; remove two of three the wrong way round and the cluster loses quorum: the API hangs, found 2026-10-21 on cka),
# 3. delete the node object.
# Then (by you): remove/comment the node in environments/<env>/nodes.yaml and `terraform apply`. The API load balancer member goes away by itself.
# Refuses to remove the last control-plane node and refuses a control-plane node if that would leave etcd without a majority.
set -euo pipefail
ENV_NAME=${1:?env (prod|qa|cka)}; NODE=${2:?node name}
KCFG=${KCFG:-$HOME/.kube/$ENV_NAME}
K() { kubectl --kubeconfig "$KCFG" --context "$ENV_NAME" "$@"; }
say() { printf '\n== %s\n' "$*"; }

K get node "$NODE" >/dev/null
IS_CP=$(K get node "$NODE" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null | wc -c | tr -d ' ')
CPS=$(K get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}')
echo "$ENV_NAME: node $NODE ($( [ "$IS_CP" != 0 ] && echo control-plane || echo worker )); control-plane nodes: $CPS"

if [ "$IS_CP" != 0 ]; then
  n=$(echo $CPS | wc -w | tr -d ' ')
  [ "$n" -ge 2 ] || { echo "$NODE is the only control-plane node; refusing" >&2; exit 1; }
  [ "$n" -ge 3 ] || echo "WARNING: after this the cluster has $((n-1)) control-plane node(s): no etcd fault tolerance"
  OTHER=$(for c in $CPS; do [ "$c" != "$NODE" ] && echo "$c" && break; done)
fi

say "1. drain $NODE"
K cordon "$NODE"
timeout 600 kubectl --kubeconfig "$KCFG" --context "$ENV_NAME" drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=540s || echo "drain did not finish (pods that cannot move stay; continuing is safe for the cluster, not for those pods)"

if [ "$IS_CP" != 0 ]; then
  say "2. remove $NODE from etcd (through $OTHER)"
  ETCDCTL='crictl exec $(crictl ps --name "^etcd$" -q | head -1) etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key'
  ssh "$OTHER.$ENV_NAME" "$ETCDCTL endpoint health --cluster" | cut -c1-90
  id=$(ssh "$OTHER.$ENV_NAME" "$ETCDCTL member list" | awk -F', ' -v n="$NODE" '$3==n {print $1}')
  if [ -z "$id" ]; then echo "no etcd member named $NODE (already removed?)"; else ssh "$OTHER.$ENV_NAME" "$ETCDCTL member remove $id"; fi
  ssh "$OTHER.$ENV_NAME" "$ETCDCTL member list -w table" | tail -6
fi

say "3. delete the node object"
K delete node "$NODE"
K get nodes --no-headers | awk '{print $1,$2,$3}' | tr '\n' ';'; echo
echo
echo "Next: comment out '$NODE' in environments/$ENV_NAME/nodes.yaml and run terraform apply there (the VM goes away; the API load balancer member is removed by the reconciler on c3)."
