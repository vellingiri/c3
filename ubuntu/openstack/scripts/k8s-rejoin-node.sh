#!/usr/bin/env bash
# Give a Kubernetes node its NEW name (the hostname of its renamed VM, e.g. w1 -> w1-prod) by taking it out of the cluster and joining it again.
# Kubernetes cannot rename a node (client certificate, Node object, etcd member and static pod names carry the name), so the node leaves and comes back.
# The VM, its address, disk and containers images stay; only the cluster membership is redone. One node per run, never in parallel.
#
#   scripts/k8s-rejoin-node.sh <env> <current node name>        e.g.  scripts/k8s-rejoin-node.sh prod w1        (it joins as w1-prod)
#
# Worker:         cordon + drain (its pods go to the other workers; a pod that cannot move, for example because each app already runs on every worker,
#                 waits Pending until the node is back), delete the node, `kubeadm reset`, join with the worker join command published on the NFS share.
# Control plane:  scripts/k8s-retire-node.sh (drain, REMOVE ITS ETCD MEMBER while etcd has its majority, delete the node), `kubeadm reset`, then join as a
#                 control-plane node (certificate key refreshed first). Needs 3 healthy control planes; refuses on a single-control-plane cluster.
# After it: the kubelet is no longer pinned (--hostname-override gone), --resolv-conf and graceful shutdown set as in cloud-init, the node is Ready under the new name,
# and the checks (etcd health for a control plane, app front door) are printed. Stop at the first problem; nothing is retried blindly.
set -euo pipefail

ENV_NAME=${1:?env (prod|cka)}; OLD=${2:?current node name}
NEW="$OLD-$ENV_NAME"
KCFG=${KCFG:-$HOME/.kube/$ENV_NAME}
HERE="$(cd "$(dirname "$0")" && pwd)"
K() { kubectl --kubeconfig "$KCFG" --context "$ENV_NAME" "$@"; }
host_of() { case "$1" in *-$ENV_NAME) echo "$1"; return;; esac; if [ -n "$(dig +short "$1-$ENV_NAME.rdulinux.com" @192.168.2.2 2>/dev/null)" ]; then echo "$1-$ENV_NAME"; else echo "$1.$ENV_NAME"; fi; }
say() { printf '\n== %s\n' "$*"; }
die() { echo "STOP: $*" >&2; exit 1; }
ready_count() { K get nodes --no-headers | grep -c " Ready" || true; }
door() { curl -s -o /dev/null -m 5 -w '%{http_code}' http://finance.rdulinux.com/health 2>/dev/null; }

say "checks"
K get node "$OLD" >/dev/null || die "no node $OLD in $ENV_NAME"
TOTAL=$(K get nodes --no-headers | wc -l | tr -d ' ')
[ "$(ready_count)" = "$TOTAL" ] || die "not all $TOTAL nodes are Ready"
IS_CP=0; K get node "$OLD" -o jsonpath='{.metadata.labels}' | grep -q 'node-role.kubernetes.io/control-plane' && IS_CP=1
CPS=$(K get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}')
NODEIP=$(K get node "$OLD" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
TARGET=${TARGET_OVERRIDE:-$(host_of "$OLD")}      # TARGET_OVERRIDE=<floating ip> if this Mac has a stale DNS answer for the new name
ssh -o ConnectTimeout=8 "$TARGET" "hostname" | grep -qx "$NEW" || die "$TARGET's hostname is not $NEW (rename the VM first: scripts/k8s-rename-node-vm.sh)"
echo "$ENV_NAME: node $OLD ($NODEIP) -> $NEW, $([ $IS_CP = 1 ] && echo control-plane || echo worker); control planes: $CPS"
if [ "$IS_CP" = 1 ]; then
  [ "$(echo $CPS | wc -w | tr -d ' ')" -ge 3 ] || die "needs 3 control-plane nodes (found: $CPS)"
  OTHER=$(for c in $CPS; do [ "$c" != "$OLD" ] && echo "$c" && break; done)
else
  OTHER=$(echo $CPS | awk '{print $1}')
fi
OTHER_HOST=$(host_of "$OTHER")
echo "door: $(door)"

say "1. fresh join commands (published by $OTHER)"
ssh "$OTHER_HOST" "/usr/local/sbin/k8s-publish-join"

if [ "$IS_CP" = 1 ]; then
  say "2. leave the cluster properly: drain, etcd member removal, node delete"
  "$HERE/k8s-retire-node.sh" "$ENV_NAME" "$OLD"
else
  say "2. cordon and drain $OLD"
  K cordon "$OLD"
  kubectl --kubeconfig "$KCFG" --context "$ENV_NAME" drain "$OLD" --ignore-daemonsets --delete-emptydir-data --timeout=640s || die "drain did not finish; the node stays cordoned, uncordon it with: kubectl uncordon $OLD"
  K delete node "$OLD"
fi

say "3. reset $TARGET and join as $NEW"
ssh "$TARGET" bash -s <<REMOTE
set -e
kubeadm reset -f >/dev/null 2>&1 || true
rm -rf /etc/cni/net.d/* /var/lib/cni/* 2>/dev/null || true
# not pinned any more; resolver as in cloud-init (docs/k8s-ha-control-plane.md)
echo 'KUBELET_EXTRA_ARGS=--resolv-conf=/etc/resolv.conf' > /etc/default/kubelet
if [ $IS_CP = 1 ]; then
  bash /nfsshare/join-cp-$ENV_NAME.sh --apiserver-advertise-address $NODEIP --cri-socket unix:///run/containerd/containerd.sock 2>&1 | tail -4
  mkdir -p /root/.kube /home/ubuntu/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config; cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config; chown ubuntu:ubuntu /home/ubuntu/.kube/config
  systemctl enable --now etcd-snapshot.timer k8s-publish-join.timer >/dev/null 2>&1 || true
else
  bash /nfsshare/join-$ENV_NAME.sh --cri-socket unix:///run/containerd/containerd.sock 2>&1 | tail -3
fi
sed -i -e 's/^shutdownGracePeriod: 0s/shutdownGracePeriod: 30s/' -e 's/^shutdownGracePeriodCriticalPods: 0s/shutdownGracePeriodCriticalPods: 10s/' /var/lib/kubelet/config.yaml
systemctl restart kubelet
REMOTE

say "4. wait for $NEW to be Ready"
for i in $(seq 1 60); do K get node "$NEW" --no-headers 2>/dev/null | grep -q " Ready" && break; sleep 5; done
K get node "$NEW" --no-headers | grep -q " Ready" || die "$NEW did not become Ready; look at: ssh $TARGET journalctl -u kubelet -n 50"
[ "$IS_CP" = 1 ] || K label node "$NEW" node-role.kubernetes.io/worker= --overwrite >/dev/null   # ROLES column of kubectl get nodes
K get nodes --no-headers | awk '{print $1,$2,$3}' | tr '\n' ';'; echo

if [ "$IS_CP" = 1 ]; then
  say "5. control plane checks: etcd members, API through the load balancer"
  ssh "$OTHER_HOST" 'crictl exec $(crictl ps --name "^etcd$" -q | head -1) etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health --cluster 2>&1 | cut -c1-90'
  K get --raw /livez; echo
fi
say "6. pods back on the node, door"
for i in $(seq 1 60); do [ "$(K get pods -A --no-headers 2>/dev/null | grep -c -E 'Pending|ContainerCreating|Terminating')" = 0 ] && break; sleep 5; done
K get pods -A --no-headers | grep -v -E 'Running|Completed' | head -5 || true
echo "door: $(door)   nodes Ready: $(ready_count)/$TOTAL"
