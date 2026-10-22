#!/usr/bin/env bash
# Install the etcd snapshot timer on an EXISTING controller (new controllers get it from cloud-init).
#   scripts/install-etcd-snapshot.sh <controller-host> <cluster-name>   e.g. c1-prod.rdulinux.com prod
set -euo pipefail
HOST=${1:?controller host}
CLUSTER=${2:?cluster name (prod|qa)}
FILES="$(cd "$(dirname "$0")/../cloud-init/files" && pwd)"
SSH_USER=${SSH_USER:-root}

scp "$FILES/etcd-snapshot.sh" "$FILES/etcd-snapshot.service" "$FILES/etcd-snapshot.timer" "$SSH_USER@$HOST:/tmp/"
ssh "$SSH_USER@$HOST" bash -s -- "$CLUSTER" <<'REMOTE'
set -euo pipefail
install -m 0755 /tmp/etcd-snapshot.sh /usr/local/sbin/etcd-snapshot
install -m 0644 /tmp/etcd-snapshot.service /tmp/etcd-snapshot.timer /etc/systemd/system/
echo "REMOTE_DIR=/nfsshare/etcd-backups/$1" > /etc/default/etcd-snapshot
systemctl daemon-reload
systemctl enable --now etcd-snapshot.timer
systemctl start etcd-snapshot.service        # take one now
systemctl --no-pager status etcd-snapshot.service | sed -n 1,8p || true
ls -lh /var/backups/etcd
REMOTE
