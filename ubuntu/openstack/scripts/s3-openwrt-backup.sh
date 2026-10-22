#!/usr/bin/env bash
# Daily backup of the OpenWrt router, run ON THE s3 HOST (installed as /usr/local/sbin/openwrt-backup, timer openwrt-backup.timer, see install-s3-openwrt-backup.sh).
# Pulls `sysupgrade -b` and `uci export` from root@192.168.2.1 with the key /root/.ssh/openwrt_backup and stores them in /backup/openwrt/ in the same
# format as scripts/openwrt-backup.sh, a new copy only when a saved file changed (fingerprint of the contents of every file `sysupgrade -l` lists).
# /backup/openwrt/last-ok is touched on every successful run, changed or not: its age is the health of this job (older than 2 days = broken).
# Restore: scripts/openwrt-restore.sh (from the Mac). Newest 30 copies are kept.
set -euo pipefail
ROUTER=${ROUTER:-root@192.168.2.1}; DEST=${DEST:-/backup/openwrt}; KEEP=${KEEP:-30}
KEY=${KEY:-/root/.ssh/openwrt_backup}
R() { ssh -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$ROUTER" "$@"; }
mkdir -p "$DEST"; chmod 700 "$DEST"
WORK=$(mktemp -d "$DEST/.tmp.XXXXXX"); trap 'rm -rf "$WORK"' EXIT

fp=$(R 'sysupgrade -l 2>/dev/null | while read -r f; do [ -f "$f" ] && sha256sum "$f"; done | sha256sum' | cut -d' ' -f1)
[ ${#fp} = 64 ] || { echo "no fingerprint from the router (is it up, is the key accepted?)" >&2; exit 1; }
if [ "$fp" = "$(cat "$DEST/.fingerprint" 2>/dev/null || true)" ]; then touch "$DEST/last-ok"; echo "unchanged"; exit 0; fi

R 'sysupgrade -b /tmp/openwrt-backup.tar.gz >/dev/null 2>&1; cat /tmp/openwrt-backup.tar.gz; rm -f /tmp/openwrt-backup.tar.gz' > "$WORK/b.tar.gz"
R 'uci export' > "$WORK/b.uci.txt"
tar tzf "$WORK/b.tar.gz" | grep -q '^etc/config/network$' || { echo "archive has no etc/config/network; not stored" >&2; exit 1; }
grep -q '^config interface' "$WORK/b.uci.txt" || { echo "uci export empty; not stored" >&2; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)-daily
mv "$WORK/b.tar.gz" "$DEST/openwrt-$STAMP.tar.gz"; mv "$WORK/b.uci.txt" "$DEST/openwrt-$STAMP.uci.txt"
chmod 600 "$DEST"/openwrt-"$STAMP".*
ln -sf "openwrt-$STAMP.tar.gz" "$DEST/latest.tar.gz"; ln -sf "openwrt-$STAMP.uci.txt" "$DEST/latest.uci.txt"
echo "$fp" > "$DEST/.fingerprint"; touch "$DEST/last-ok"
cd "$DEST" && ls -1 openwrt-*.tar.gz | sort | head -n -"$KEEP" | while read -r f; do rm -f "$f" "${f%.tar.gz}.uci.txt"; done
echo "stored openwrt-$STAMP"
