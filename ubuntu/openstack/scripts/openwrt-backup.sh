#!/usr/bin/env bash
# Back up the OpenWrt router (192.168.2.1) and keep the copies on the s3 host:  scripts/openwrt-backup.sh [label]
# Two files per run in s3:/backup/openwrt/ : openwrt-<date>[-label].tar.gz (sysupgrade -b: everything /etc/config and the other kept files; restore with scripts/openwrt-restore.sh)
# and openwrt-<date>[-label].uci.txt (uci export, readable, for diffs). `latest.tar.gz` / `latest.uci.txt` point at the newest. The newest 30 runs are kept.
# Read-only on the router (the archive is built in its /tmp and removed). Run from the Mac; needs ssh keys for root@ROUTER and root@s3.
set -euo pipefail
ROUTER=${ROUTER:-root@192.168.2.1}; DEST_HOST=${DEST_HOST:-s3}; DEST=${DEST:-/backup/openwrt}; KEEP=${KEEP:-30}
STAMP="$(date +%Y%m%d-%H%M%S)${1:+-$1}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "== router: build the archive"
ssh "$ROUTER" 'sysupgrade -b /tmp/openwrt-backup.tar.gz 2>/dev/null; ls -l /tmp/openwrt-backup.tar.gz | awk "{print \$5, \"bytes\"}"'
ssh "$ROUTER" 'cat /tmp/openwrt-backup.tar.gz; rm -f /tmp/openwrt-backup.tar.gz' > "$WORK/b.tar.gz"
ssh "$ROUTER" 'uci export' > "$WORK/b.uci.txt"
tar tzf "$WORK/b.tar.gz" | grep -q '^etc/config/network$' || { echo "STOP: the archive has no etc/config/network; not stored" >&2; exit 1; }
grep -q '^config interface' "$WORK/b.uci.txt" || { echo "STOP: uci export is empty; not stored" >&2; exit 1; }
echo "   $(tar tzf "$WORK/b.tar.gz" | wc -l | tr -d ' ') files in the archive, $(wc -c < "$WORK/b.tar.gz" | tr -d ' ') bytes"

echo "== $DEST_HOST:$DEST"
ssh "$DEST_HOST" "mkdir -p $DEST && chmod 700 $DEST"
ssh "$DEST_HOST" "cat > $DEST/openwrt-$STAMP.tar.gz && chmod 600 $DEST/openwrt-$STAMP.tar.gz" < "$WORK/b.tar.gz"
ssh "$DEST_HOST" "cat > $DEST/openwrt-$STAMP.uci.txt && chmod 600 $DEST/openwrt-$STAMP.uci.txt" < "$WORK/b.uci.txt"
# verify what arrived is what was sent
want=$(shasum -a 256 < "$WORK/b.tar.gz" | cut -d' ' -f1)
got=$(ssh "$DEST_HOST" "sha256sum $DEST/openwrt-$STAMP.tar.gz" | cut -d' ' -f1)
[ "$want" = "$got" ] || { echo "STOP: checksum differs after the copy" >&2; exit 1; }
ssh "$DEST_HOST" "cd $DEST && ln -sf openwrt-$STAMP.tar.gz latest.tar.gz && ln -sf openwrt-$STAMP.uci.txt latest.uci.txt && ls -1 openwrt-*.tar.gz | sort | head -n -$KEEP | while read -r f; do rm -f \"\$f\" \"\${f%.tar.gz}.uci.txt\"; done; ls -l openwrt-*.tar.gz | tail -3"
echo "ok: openwrt-$STAMP (sha256 $want)"
