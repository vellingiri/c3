#!/usr/bin/env bash
# Install the Kubernetes API load balancer reconciler on c3 as a systemd timer (every 30 s). Re-runnable. Run from your Mac.
#   scripts/install-k8s-api-lb-reconciler.sh [host]        default: c3
# What it does and why: scripts/k8s-api-lb-reconciler.py, docs/k8s-ha-control-plane.md.
# It needs the OpenStack admin credentials. They are copied from root's environment on c3 (the OS_* variables its shell already exports) into
# /etc/default/k8s-api-lb-reconciler (mode 600, root only); nothing is printed and nothing leaves c3.
set -euo pipefail
HOST=${1:-c3}
HERE="$(cd "$(dirname "$0")" && pwd)"
scp -q "$HERE/k8s-api-lb-reconciler.py" "root@$HOST:/tmp/k8s-api-lb-reconciler.py"
ssh "root@$HOST" bash -s <<'REMOTE'
set -euo pipefail
install -m 0755 /tmp/k8s-api-lb-reconciler.py /usr/local/sbin/k8s-api-lb-reconciler; rm -f /tmp/k8s-api-lb-reconciler.py
if [ ! -s /etc/default/k8s-api-lb-reconciler ]; then
  ( umask 077; env | grep '^OS_' > /etc/default/k8s-api-lb-reconciler )
  chmod 600 /etc/default/k8s-api-lb-reconciler
fi
cat > /etc/systemd/system/k8s-api-lb.service <<'UNIT'
[Unit]
Description=Keep the Kubernetes API load balancers' members equal to the control-plane VMs
After=network-online.target nova-api.service octavia-api.service

[Service]
Type=oneshot
EnvironmentFile=/etc/default/k8s-api-lb-reconciler
ExecStart=/usr/local/sbin/k8s-api-lb-reconciler
UNIT
cat > /etc/systemd/system/k8s-api-lb.timer <<'UNIT'
[Unit]
Description=Reconcile the Kubernetes API load balancer members every 30 seconds

[Timer]
OnBootSec=4min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now k8s-api-lb.timer >/dev/null 2>&1
/usr/local/sbin/k8s-api-lb-reconciler --dry-run && echo "dry run ok"
echo installed; systemctl list-timers k8s-api-lb.timer --no-pager | head -3
REMOTE
