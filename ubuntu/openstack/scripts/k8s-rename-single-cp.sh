#!/usr/bin/env bash
# Give the Kubernetes node of a SINGLE-control-plane cluster its new name, in place (from your Mac):
#   scripts/k8s-rename-single-cp.sh <env> <old node name> <new node name>      e.g.  scripts/k8s-rename-single-cp.sh cka c1 c1-cka
#
# A node cannot be renamed, and the usual way (scripts/k8s-rejoin-node.sh: leave the cluster and join again) needs three control planes so etcd keeps
# its majority. With one control plane that would destroy the cluster. This does it without leaving: the control plane's containers (etcd, API server,
# controller manager, scheduler) belong to the container runtime, not to the kubelet, so they keep running while the kubelet is stopped and comes back
# under the new name. Steps, on the control-plane VM:
#   1. etcd snapshot and a tarball of /etc/kubernetes and the kubelet files (rollback)
#   2. a new kubelet client certificate for system:node:<new> (O=system:nodes), signed by the cluster CA that is on this node
#   3. stop the kubelet; install the new kubelet.conf; drop --hostname-override from /etc/default/kubelet
#   4. delete the old Node object; start the kubelet, which registers <new>
#   5. put back what the Node object had: control-plane label, exclude-from-load-balancers label, NoSchedule taint, cri-socket annotation
# The etcd MEMBER name stays what it was (it is only a label inside etcd). Rollback: docs/k8s-docker-runtime.md "Rename" section or the tarball
# on the node (/root/<env>-<old>-rename-backup.tgz).
set -euo pipefail

ENV_NAME=${1:?env (cka)}; OLD=${2:?old node name}; NEW=${3:?new node name}
KCFG=${KCFG:-$HOME/.kube/$ENV_NAME}
K() { kubectl --kubeconfig "$KCFG" --context "$ENV_NAME" "$@"; }
say() { printf '\n== %s\n' "$*"; }
die() { echo "STOP: $*" >&2; exit 1; }
SSH=${SSH_TARGET:-$NEW}          # the VM is already called <new> (the VM rename came first), so ssh to it by that name

say "checks"
K get node "$OLD" >/dev/null || die "no node $OLD in $ENV_NAME"
[ "$(K get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l | tr -d ' ')" = 1 ] || die "this is for a cluster with exactly ONE control plane; with three use scripts/k8s-rejoin-node.sh"
K get node "$NEW" >/dev/null 2>&1 && die "a node called $NEW already exists"
READY=$(K get nodes --no-headers | grep -c ' Ready' || true); TOTAL=$(K get nodes --no-headers | wc -l | tr -d ' ')
[ "$READY" = "$TOTAL" ] || die "not all $TOTAL nodes are Ready"
ssh -o ConnectTimeout=8 "$SSH" "test \"\$(hostname)\" = $NEW" || die "the VM's hostname is not $NEW (rename the VM first)"
RUNTIME=$(K get node "$OLD" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}'); echo "$OLD -> $NEW, runtime $RUNTIME, nodes Ready $READY/$TOTAL"
SOCK=$(K get node "$OLD" -o jsonpath='{.metadata.annotations.kubeadm\.alpha\.kubernetes\.io/cri-socket}')

say "1. backups on $SSH"
ssh "$SSH" "/usr/local/sbin/etcd-snapshot 2>&1 | tail -1; tar czf /root/$ENV_NAME-$OLD-rename-backup.tgz -C / etc/kubernetes etc/default/kubelet var/lib/kubelet/config.yaml var/lib/kubelet/kubeadm-flags.env 2>/dev/null; ls -l /root/$ENV_NAME-$OLD-rename-backup.tgz | awk '{print \$5, \$9}'"

say "2. new kubelet credentials for system:node:$NEW"
ssh "$SSH" bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > /tmp/cluster-config.yaml
kubeadm kubeconfig user --config /tmp/cluster-config.yaml --client-name system:node:$NEW --org system:nodes > /tmp/kubelet-$NEW.conf
chmod 600 /tmp/kubelet-$NEW.conf
grep -c 'client-certificate-data' /tmp/kubelet-$NEW.conf | sed 's/^/embedded client certificate: /'
grep 'server:' /tmp/kubelet-$NEW.conf | sed 's/^ *//'
rm -f /tmp/cluster-config.yaml
REMOTE

say "3. stop the kubelet, swap the credentials and the name"
ssh "$SSH" bash -s <<REMOTE
set -euo pipefail
systemctl stop kubelet
cp -p /etc/kubernetes/kubelet.conf /etc/kubernetes/kubelet.conf.before-rename
install -m 600 /tmp/kubelet-$NEW.conf /etc/kubernetes/kubelet.conf
rm -f /tmp/kubelet-$NEW.conf
sed -i 's/ *--hostname-override=[^ ]*//' /etc/default/kubelet
echo "/etc/default/kubelet: \$(cat /etc/default/kubelet)"
echo "control-plane containers still running: \$(crictl ps 2>/dev/null | grep -c -E 'kube-apiserver|etcd|kube-controller|kube-scheduler')"
curl -sk -m 5 -o /dev/null -w 'API /livez while the kubelet is stopped: %{http_code}\n' https://127.0.0.1:6443/livez
REMOTE

say "4. delete the old Node object and start the kubelet"
K delete node "$OLD" >/dev/null
ssh "$SSH" "systemctl start kubelet"
for i in $(seq 1 60); do K get node "$NEW" --no-headers 2>/dev/null | grep -q ' Ready' && break; sleep 5; done
K get node "$NEW" --no-headers | grep -q ' Ready' || die "$NEW did not become Ready; look at: ssh $SSH journalctl -u kubelet -n 50 (rollback: restore /etc/kubernetes/kubelet.conf.before-rename, put --hostname-override=$OLD back, delete node $NEW)"

say "5. put back the control-plane label, taint and annotation"
K label node "$NEW" node-role.kubernetes.io/control-plane= node.kubernetes.io/exclude-from-external-load-balancers= --overwrite >/dev/null
K taint node "$NEW" node-role.kubernetes.io/control-plane=:NoSchedule --overwrite >/dev/null
[ -n "$SOCK" ] && K annotate node "$NEW" --overwrite kubeadm.alpha.kubernetes.io/cri-socket="$SOCK" >/dev/null
for i in $(seq 1 60); do [ "$(K get pods -A --no-headers 2>/dev/null | grep -c -v -E 'Running|Completed')" = 0 ] && break; sleep 5; done
echo "non-running pods: $(K get pods -A --no-headers | grep -c -v -E 'Running|Completed')"
K get nodes -o wide --no-headers | awk '{print $1,$2,$3,$NF}' | tr '\n' ';'; echo
echo "API: $(K get --raw /livez)   control-plane pods:"; K -n kube-system get pods --no-headers | grep -E "(etcd|kube-apiserver|kube-controller-manager|kube-scheduler)-$NEW" | awk '{print "  " $1, $2, $3}'
