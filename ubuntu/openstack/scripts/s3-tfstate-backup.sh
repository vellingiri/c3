#!/usr/bin/env bash
# Copy every Terraform state in the RustFS bucket `terraform-state` to /backup/terraform-state/<timestamp>/ on the s3 host (a different partition from
# the RustFS data), keeping a new snapshot only when something changed. Installed on s3 as /usr/local/sbin/tfstate-backup and run hourly by
# tfstate-backup.timer (scripts/install-s3-tfstate-backup.sh). Why: RustFS runs single-node on one disk, bucket versioning keeps the history but is
# on that same disk, and every state of this lab (infra, prod, qa, cka) lives there; docs/s3-state-store.md.
# The access keys are read from the running container's environment at run time, never stored or printed.
set -euo pipefail
BUCKET=terraform-state
ENDPOINT=http://192.168.2.4:9000
DEST=/backup/terraform-state
KEEP=300

AK=$(docker inspect rustfs --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^RUSTFS_ACCESS_KEY=//p')
SK=$(docker inspect rustfs --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^RUSTFS_SECRET_KEY=//p')
s3() { curl -fsS --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AK:$SK" "$@"; }

mkdir -p "$DEST"
TMP=$(mktemp -d "$DEST/.tmp.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
keys=$(s3 "$ENDPOINT/$BUCKET?list-type=2" | grep -o '<Key>[^<]*</Key>' | sed 's#</\?Key>##g' | grep -v '\.tflock$' || true)
[ -n "$keys" ] || { echo "no objects listed in $BUCKET (is RustFS up?)" >&2; exit 1; }
n=0
while IFS= read -r k; do
  mkdir -p "$TMP/$(dirname "$k")"
  s3 -o "$TMP/$k" "$ENDPOINT/$BUCKET/$k"
  # a state file must be valid JSON with a serial; otherwise do not trust this copy
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'serial' in d" "$TMP/$k"
  n=$((n+1))
done <<< "$keys"

if [ -d "$DEST/latest" ] && diff -r "$DEST/latest/" "$TMP/" >/dev/null 2>&1; then
  touch "$DEST/last-ok"; echo "unchanged ($n states)"; exit 0
fi
SNAP="$DEST/$(date +%Y%m%d-%H%M%S)"
mv "$TMP" "$SNAP"; chmod -R go-rwx "$SNAP"; chmod 700 "$DEST"
ln -sfn "$SNAP" "$DEST/latest"; touch "$DEST/last-ok"
ls -1d "$DEST"/2* | head -n -"$KEEP" | xargs -r rm -rf
echo "snapshot $SNAP ($n states)"
