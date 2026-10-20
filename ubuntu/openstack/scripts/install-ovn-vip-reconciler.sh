#!/usr/bin/env bash
# Install the OVN VIP binding reconciler on c3 as a systemd timer (every 30 s). Re-runnable. Run from your Mac.
#   scripts/install-ovn-vip-reconciler.sh [host]        default: c3
# Why: docs/c3-reboot.md ("OVN router keeps a stale MAC for a rebuilt amphora").
set -euo pipefail
HOST=${1:-c3}
HERE="$(cd "$(dirname "$0")" && pwd)"

scp -q "$HERE/ovn-vip-binding-reconciler.py" "root@$HOST:/tmp/ovn-vip-binding-reconciler.py"
ssh "root@$HOST" bash -s <<'REMOTE'
set -euo pipefail
install -m 0755 /tmp/ovn-vip-binding-reconciler.py /usr/local/sbin/ovn-vip-binding-reconciler
rm -f /tmp/ovn-vip-binding-reconciler.py
cat > /etc/systemd/system/ovn-vip-binding.service <<'UNIT'
[Unit]
Description=Point OVN's router entry for each Octavia VIP at the amphora that answers
After=ovn-central.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ovn-vip-binding-reconciler
UNIT
cat > /etc/systemd/system/ovn-vip-binding.timer <<'UNIT'
[Unit]
Description=Check the Octavia VIPs every 30 seconds

[Timer]
OnBootSec=90s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now ovn-vip-binding.timer >/dev/null
echo "installed; next run:"; systemctl list-timers ovn-vip-binding.timer --no-pager | sed -n 2p
/usr/local/sbin/ovn-vip-binding-reconciler --dry-run && echo "dry run ok"
REMOTE
