#!/usr/bin/env bash
# Publish fresh join commands for this cluster on the shared NFS directory, so a node created LATER (a replacement worker, a new control-plane
# node) can join without anyone running kubeadm by hand:
#   /nfsshare/join-<cluster>.sh       worker join            (bootstrap token, valid 24 h)
#   /nfsshare/join-cp-<cluster>.sh    control-plane join     (same token + --control-plane + certificate key, which kubeadm keeps for 2 h)
# Run on a control-plane node by a timer every hour (k8s-publish-join.timer). The cluster name is in /etc/k8s-cluster-name.
# The endpoint in the printed command is the cluster's controlPlaneEndpoint (the API load balancer name once the cluster is HA).
set -euo pipefail
# One run at a time: every `upload-certs` makes a NEW certificate key and re-encrypts the kubeadm-certs secret with it, so two runs overlapping (the timer
# firing while an explicit run is going) could leave a file whose key no longer opens the secret ("message authentication failed" at the joining node).
exec 9>/run/k8s-publish-join.lock
flock 9
CLUSTER=$(cat /etc/k8s-cluster-name)
DIR=${JOIN_DIR:-/nfsshare}
export KUBECONFIG=/etc/kubernetes/admin.conf

# Give every worker the role label `kubectl get nodes` shows in ROLES (a kubelet may not label itself node-role.kubernetes.io/*; only a control plane can).
# Idempotent; a node that joined since the last run is labelled within the hour.
kubectl label nodes -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/worker' node-role.kubernetes.io/worker= >/dev/null 2>&1 || true

join=$(kubeadm token create --ttl 24h --print-join-command)
key=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
case "$key" in *[!0-9a-f]*|"") echo "could not get a certificate key (got: '$key')" >&2; exit 1 ;; esac

umask 022
printf '%s\n' "$join" > "$DIR/join-$CLUSTER.sh.new" && chmod +x "$DIR/join-$CLUSTER.sh.new" && mv -f "$DIR/join-$CLUSTER.sh.new" "$DIR/join-$CLUSTER.sh"
printf '%s --control-plane --certificate-key %s\n' "$join" "$key" > "$DIR/join-cp-$CLUSTER.sh.new" && chmod 0700 "$DIR/join-cp-$CLUSTER.sh.new" && mv -f "$DIR/join-cp-$CLUSTER.sh.new" "$DIR/join-cp-$CLUSTER.sh"
echo "published $DIR/join-$CLUSTER.sh and $DIR/join-cp-$CLUSTER.sh"
