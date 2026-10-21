#!/usr/bin/env bash
# Install the Terraform-state backup on the s3 host (hourly, to /backup/terraform-state) and an hourly pull of it to c3 (/root/backups/terraform-state),
# so the states exist on three disks: RustFS's own, another partition on s3, and a different machine. Re-runnable. Run from your Mac.
#   scripts/install-s3-tfstate-backup.sh
# Restore: docs/s3-state-store.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
scp -q "$HERE/s3-tfstate-backup.sh" s3:/tmp/tfstate-backup
ssh s3 bash -s <<'REMOTE'
set -euo pipefail
install -m 0700 /tmp/tfstate-backup /usr/local/sbin/tfstate-backup; rm -f /tmp/tfstate-backup
cat > /etc/systemd/system/tfstate-backup.service <<'UNIT'
[Unit]
Description=copy the Terraform states from RustFS to /backup/terraform-state
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tfstate-backup
UNIT
cat > /etc/systemd/system/tfstate-backup.timer <<'UNIT'
[Unit]
Description=hourly copy of the Terraform states

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload; systemctl enable --now tfstate-backup.timer >/dev/null 2>&1
systemctl start tfstate-backup.service; journalctl -u tfstate-backup -n 3 --no-pager | cut -c1-160
REMOTE
ssh c3 bash -s <<'REMOTE'
set -euo pipefail
mkdir -p /root/backups/terraform-state; chmod 700 /root/backups/terraform-state
cat > /etc/systemd/system/tfstate-pull.service <<'UNIT'
[Unit]
Description=pull the Terraform state snapshots from the s3 host to c3
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rsync -a -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" root@192.168.2.4:/backup/terraform-state/ /root/backups/terraform-state/
UNIT
cat > /etc/systemd/system/tfstate-pull.timer <<'UNIT'
[Unit]
Description=hourly pull of the Terraform state snapshots

[Timer]
OnCalendar=*-*-* *:35:00
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload; systemctl enable --now tfstate-pull.timer >/dev/null 2>&1
which rsync >/dev/null || apt-get install -y -qq rsync >/dev/null
systemctl start tfstate-pull.service; ls /root/backups/terraform-state | head -3; du -sh /root/backups/terraform-state | cut -f1
REMOTE
