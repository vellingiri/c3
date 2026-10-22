#!/usr/bin/env bash
# Put an OpenWrt configuration back on the router:  scripts/openwrt-restore.sh [<archive on s3, default latest>] [--yes]
#   scripts/openwrt-restore.sh                                  # shows what it would restore and asks
#   scripts/openwrt-restore.sh openwrt-20261022-120000.tar.gz   # a specific one (names: ssh s3 ls /backup/openwrt)
#   scripts/openwrt-restore.sh /path/on/mac/openwrt-x.tar.gz    # a local file (when s3 is not reachable)
# Method: copy the archive to the router's /tmp, `sysupgrade -r` (unpacks over /etc/config etc.), then reboot so every service starts from it.
# The router is unreachable for about a minute. A fresh backup of the CURRENT state is taken first (label "before-restore"), so a restore can be undone.
# A router that was reset or replaced: give it 192.168.2.1 and ssh access first (LuCI or the failsafe mode), then run this.
set -euo pipefail
ROUTER=${ROUTER:-root@192.168.2.1}; DEST_HOST=${DEST_HOST:-s3}; DEST=${DEST:-/backup/openwrt}
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC=latest.tar.gz; YES=0
for a in "$@"; do case "$a" in --yes) YES=1 ;; *) SRC=$a ;; esac; done
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ -f "$SRC" ]; then cp "$SRC" "$WORK/r.tar.gz"; echo "archive: local $SRC"
else ssh "$DEST_HOST" "cat $DEST/$SRC" > "$WORK/r.tar.gz"; echo "archive: $DEST_HOST:$DEST/$SRC ($(ssh "$DEST_HOST" "readlink -f $DEST/$SRC" | xargs basename))"; fi
tar tzf "$WORK/r.tar.gz" | grep -q '^etc/config/network$' || { echo "STOP: not an OpenWrt backup (no etc/config/network)" >&2; exit 1; }
echo "contains $(tar tzf "$WORK/r.tar.gz" | wc -l | tr -d ' ') files, e.g.:"; tar tzf "$WORK/r.tar.gz" | head -8 | sed 's/^/   /'
if [ $YES = 0 ]; then read -r -p "Restore this onto $ROUTER and reboot it? (type yes) " ans; [ "$ans" = yes ] || { echo "cancelled"; exit 1; }; fi

if ssh -o ConnectTimeout=6 -o BatchMode=yes "$ROUTER" true 2>/dev/null; then
  echo "== safety copy of the current state"; "$HERE/openwrt-backup.sh" before-restore || echo "(safety copy failed; continuing because you asked for the restore)"
fi
echo "== restore"
ssh "$ROUTER" 'cat > /tmp/restore.tar.gz' < "$WORK/r.tar.gz"
ssh "$ROUTER" 'sysupgrade -r /tmp/restore.tar.gz && echo restored; rm -f /tmp/restore.tar.gz; (sleep 2; reboot) >/dev/null 2>&1 &'
echo "== waiting for the router to come back"
sleep 20; for i in $(seq 1 30); do ping -c1 -W2 192.168.2.1 >/dev/null 2>&1 && break; sleep 4; done
sleep 8; ssh -o ConnectTimeout=8 "$ROUTER" 'uptime; uci get network.lan.ipaddr; uci get dhcp.lan.limit' || echo "router not back on ssh yet; check by hand"
