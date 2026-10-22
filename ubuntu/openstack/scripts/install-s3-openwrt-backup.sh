#!/usr/bin/env bash
# Install the daily router backup on the s3 host (run from the Mac; needs ssh keys for s3 and for the router):  scripts/install-s3-openwrt-backup.sh
# 1. key pair on s3 (/root/.ssh/openwrt_backup, no passphrase, used only for this) and its public half added to the router's /etc/dropbear/authorized_keys,
# 2. the script as /usr/local/sbin/openwrt-backup, service + timer (daily 03:15, Persistent so a missed run happens at boot),
# 3. one run now. Nothing on c3, nothing else on the router.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROUTER=${ROUTER:-root@192.168.2.1}; S3=${S3:-s3}
ssh "$S3" '[ -f /root/.ssh/openwrt_backup ] || ssh-keygen -q -t ed25519 -N "" -C "s3-openwrt-backup" -f /root/.ssh/openwrt_backup; chmod 600 /root/.ssh/openwrt_backup'
PUB=$(ssh "$S3" 'cat /root/.ssh/openwrt_backup.pub')
ssh "$ROUTER" "grep -qF '$PUB' /etc/dropbear/authorized_keys || echo '$PUB' >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; wc -l < /etc/dropbear/authorized_keys"
# so that a plain `ssh root@192.168.2.1` (or `ssh openwrt-router`) from s3 uses that key too
ssh "$S3" 'grep -q "^Host openwrt-router" /root/.ssh/config 2>/dev/null || { printf "\nHost openwrt-router 192.168.2.1\n  HostName 192.168.2.1\n  User root\n  IdentityFile /root/.ssh/openwrt_backup\n  IdentitiesOnly yes\n" >> /root/.ssh/config; chmod 600 /root/.ssh/config; }'
scp -q "$HERE/s3-openwrt-backup.sh" "$S3:/usr/local/sbin/openwrt-backup"
ssh "$S3" 'chmod 0755 /usr/local/sbin/openwrt-backup
cat > /etc/systemd/system/openwrt-backup.service <<U
[Unit]
Description=Back up the OpenWrt router to /backup/openwrt
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openwrt-backup
U
cat > /etc/systemd/system/openwrt-backup.timer <<U
[Unit]
Description=Daily OpenWrt router backup
[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
U
systemctl daemon-reload && systemctl enable --now openwrt-backup.timer >/dev/null 2>&1
systemctl start openwrt-backup.service; systemctl --no-pager status openwrt-backup.service | sed -n "1,3p;/stored\|unchanged/p"; journalctl -u openwrt-backup -n 3 --no-pager -o cat
systemctl list-timers openwrt-backup.timer --no-pager | head -2; ls -l /backup/openwrt | tail -6'
