#!/usr/bin/env bash
# Pull the RustFS data directory of the s3-prod VM to this machine (the backup box, formerly `s3`): dated, hard-linked snapshots under
# /backup/rustfs-vm/<timestamp>/ (so 200 hourly copies of a 14 MB store cost a few MB), a `latest` link and a `last-ok` marker.
# Installed as /usr/local/sbin/rustfs-vm-pull by scripts/install-rustfs-vm-pull.sh and run hourly by rustfs-vm-pull.timer.
# Read-only on the VM: the key can only run `rrsync -ro /opt/rustfs` (restrict in the VM's authorized_keys), so nothing here can change or delete
# anything there, and the VM holds no credential into this machine. A snapshot is never deleted because the VM deleted something; only the oldest
# beyond KEEP are pruned. This is the second layer under the API-level state snapshots (s3-tfstate-backup.sh): it restores the WHOLE store,
# versions included. Restore: scripts/s3-vm-restore.sh, docs/s3-state-store.md.
set -euo pipefail
SRC="${RUSTFS_VM:-s3.rdulinux.com}"
DEST=/backup/rustfs-vm
KEEP=200
KEY=/root/.ssh/s3vm-backup
[ -f /etc/rustfs-vm-pull.env ] && . /etc/rustfs-vm-pull.env     # may set RUSTFS_VM to an address when DNS is not there

mkdir -p "$DEST"; chmod 700 "$DEST"
TMP=$(mktemp -d "$DEST/.tmp.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
RSH="ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
LINK=(); [ -d "$DEST/latest" ] && LINK=(--link-dest="$(readlink -f "$DEST/latest")")
# the store is live: copy, then copy again so a write that landed during the first pass is picked up by the second
for pass in 1 2; do rsync -a --numeric-ids -e "$RSH" "${LINK[@]}" "root@$SRC:data/" "$TMP/"; done
# do not trust an empty or partial copy
n=$(find "$TMP" -type f | wc -l)
[ -d "$TMP/terraform-state" ] && [ "$n" -ge 50 ] || { echo "copy from $SRC looks wrong ($n files, terraform-state present: $([ -d "$TMP/terraform-state" ] && echo yes || echo no)); keeping the previous snapshots" >&2; exit 1; }
if [ -d "$DEST/latest" ] && diff -rq "$DEST/latest/" "$TMP/" >/dev/null 2>&1; then touch "$DEST/last-ok"; echo "unchanged ($n files)"; exit 0; fi
SNAP="$DEST/$(date +%Y%m%d-%H%M%S)"
mv "$TMP" "$SNAP"; chmod 700 "$SNAP"
ln -sfn "$(basename "$SNAP")" "$DEST/latest"; touch "$DEST/last-ok"        # a relative link, so the folder can be copied elsewhere
ls -1d "$DEST"/2* | head -n -"$KEEP" | xargs -r rm -rf
echo "snapshot $SNAP ($n files)"
