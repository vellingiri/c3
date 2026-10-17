#!/usr/bin/env bash
# Snapshot the local etcd member (kubeadm static pod) and prune old copies.
# Uses crictl, so it works even when the Kubernetes API is down.
# Settings come from /etc/default/etcd-snapshot (BACKUP_DIR, KEEP, REMOTE_DIR).
set -euo pipefail
[ -r /etc/default/etcd-snapshot ] && . /etc/default/etcd-snapshot
: "${BACKUP_DIR:=/var/backups/etcd}"
: "${KEEP:=28}"
: "${REMOTE_DIR:=}"

stamp=$(date +%Y%m%dT%H%M%S)
dest="$BACKUP_DIR/etcd-$stamp.db"
mkdir -p "$BACKUP_DIR"

ctr=$(crictl ps --name '^etcd$' -q | head -1)
[ -n "$ctr" ] || { echo "etcd container not found" >&2; exit 1; }

# /var/lib/etcd is a hostPath in the etcd pod, so the file appears on the host too.
crictl exec "$ctr" etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot.tmp
mv /var/lib/etcd/snapshot.tmp "$dest"
[ -s "$dest" ] || { echo "empty snapshot $dest" >&2; exit 1; }
chmod 600 "$dest"

prune() { ls -1t "$1"/etcd-*.db 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f; }
prune "$BACKUP_DIR"

# Optional off-box copy (e.g. the NFS share); never fail the local backup over it.
if [ -n "$REMOTE_DIR" ] && mkdir -p "$REMOTE_DIR" 2>/dev/null && cp "$dest" "$REMOTE_DIR/" 2>/dev/null; then
  prune "$REMOTE_DIR"
else
  [ -z "$REMOTE_DIR" ] || echo "warning: could not copy to $REMOTE_DIR" >&2
fi
echo "etcd snapshot: $dest ($(du -h "$dest" | cut -f1))"
