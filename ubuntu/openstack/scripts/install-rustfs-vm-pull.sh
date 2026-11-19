#!/usr/bin/env bash
# Install the hourly pull of the s3 VM's RustFS data on the backup box (`s3`, 192.168.2.4). Re-runnable. Run from your Mac.
#   scripts/install-rustfs-vm-pull.sh
# Needs the pull key authorised on the VM first (the restrict,command="/usr/bin/rrsync -ro /opt/rustfs" line in its authorized_keys; docs/s3-state-store.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
scp -q "$HERE/rustfs-vm-pull.sh" backup:/tmp/rustfs-vm-pull
ssh backup bash -s <<'REMOTE'
set -euo pipefail
install -m 0700 /tmp/rustfs-vm-pull /usr/local/sbin/rustfs-vm-pull; rm -f /tmp/rustfs-vm-pull
cat > /etc/systemd/system/rustfs-vm-pull.service <<'UNIT'
[Unit]
Description=pull the RustFS data of the s3 VM to /backup/rustfs-vm

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rustfs-vm-pull
UNIT
cat > /etc/systemd/system/rustfs-vm-pull.timer <<'UNIT'
[Unit]
Description=hourly pull of the s3 RustFS data

[Timer]
OnBootSec=10min
OnCalendar=*:20
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload; systemctl enable --now rustfs-vm-pull.timer >/dev/null 2>&1
systemctl start rustfs-vm-pull.service; journalctl -u rustfs-vm-pull -n 3 --no-pager | cut -c1-170
ls -l /backup/rustfs-vm | tail -4
REMOTE
