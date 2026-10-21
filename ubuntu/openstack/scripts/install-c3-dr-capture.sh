#!/usr/bin/env bash
# Install the daily disaster-recovery capture of c3 (scripts/c3-dr/c3-dr-capture.sh) as a systemd timer ON c3. Re-runnable. Run from your Mac:
#   scripts/install-c3-dr-capture.sh [host]        default: c3
# Each run builds a bundle in /root/dr-staging (2 kept) and pushes it to s3:/backup/c3-dr/bundles/ (21 kept; images and /share are mirrored there too).
# Needs: root ssh from c3 to s3 by key (it already works: the Terraform state pull uses it). What it captures and why: docs/c3-rebuild.md.
set -euo pipefail
HOST=${1:-c3}
HERE="$(cd "$(dirname "$0")" && pwd)"
scp -q "$HERE/c3-dr/c3-dr-capture.sh" "root@$HOST:/tmp/c3-dr-capture.sh"
ssh "root@$HOST" bash -s <<'REMOTE'
set -euo pipefail
install -m 0700 /tmp/c3-dr-capture.sh /usr/local/sbin/c3-dr-capture; rm -f /tmp/c3-dr-capture.sh
cat > /etc/systemd/system/c3-dr-capture.service <<'UNIT'
[Unit]
Description=capture everything needed to rebuild c3 and push it to the s3 host
After=network-online.target mariadb.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/c3-dr-capture
Nice=10
IOSchedulingClass=idle
UNIT
cat > /etc/systemd/system/c3-dr-capture.timer <<'UNIT'
[Unit]
Description=daily disaster-recovery capture of c3

[Timer]
OnCalendar=*-*-* 02:20:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now c3-dr-capture.timer >/dev/null 2>&1
/usr/local/sbin/c3-dr-capture --dry-run | head -5
systemctl list-timers c3-dr-capture.timer --no-pager | head -3
echo "installed. First real run: systemctl start c3-dr-capture.service (about a minute; images are copied once)"
REMOTE
