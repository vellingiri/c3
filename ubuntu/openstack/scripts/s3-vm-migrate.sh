#!/usr/bin/env bash
# Keep the old s3 host's RustFS and the s3-prod VM's RustFS comparable, and say so. Run from your Mac. Each direction is explicit, so a stale copy can never
# overwrite the live store by accident.
#   scripts/s3-vm-migrate.sh --check        # compare both stores object by object, version by version (read-only; always safe)
#   scripts/s3-vm-migrate.sh --old-to-vm    # BEFORE the switch only: re-copy old -> VM, then compare
#   scripts/s3-vm-migrate.sh --vm-to-old    # ROLLBACK after the switch: copy the VM's store back to the old host, then compare
# The store being copied FROM is stopped for the few seconds of the copy and started again; the one being copied TO keeps its previous data, moved to
# /opt/rustfs/data.before-sync-<time> (never deleted). Run with no Terraform running anywhere. Since 2026-11-15 the VM is the live store (docs/s3-state-store.md);
# after that, --old-to-vm would replace the live store with an older copy: it asks for ALLOW_OLD_TO_VM=1.
set -euo pipefail
OLD="${OLD_S3:-s3}"                       # ssh name of the old host
OLD_URL="${OLD_URL:-http://192.168.2.4:9000}"
VM="${S3_VM:-root@s3-prod.rdulinux.com}"
VM_URL="${VM_URL:-http://s3-prod.rdulinux.com:9000}"
SSHV=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
vm() { "${SSHV[@]}" "$VM" "$@"; }
old() { ssh -o BatchMode=yes "$OLD" "$@"; }

listing() {   # $1 = base URL; prints every object and every version (key, version id, size), keys read on the VM from its own settings, never printed
vm "AK=\$(sed -n 's/^RUSTFS_ACCESS_KEY=//p' /opt/rustfs/.env); SK=\$(sed -n 's/^RUSTFS_SECRET_KEY=//p' /opt/rustfs/.env)
for q in 'list-type=2' 'versions'; do curl -fsS --aws-sigv4 'aws:amz:us-east-1:s3' --user \"\$AK:\$SK\" \"$1/terraform-state?\$q&max-keys=1000\"; echo; done" |
python3 -c "
import sys,re
x=sys.stdin.read()
for e in sorted(re.findall(r'<(?:Contents|Version|DeleteMarker)>.*?</(?:Contents|Version|DeleteMarker)>',x,re.S)):
    g=lambda t:(re.search('<'+t+'>(.*?)</'+t+'>',e) or [0,''])[1]
    print(g('Key'),g('VersionId'),g('Size'))"
}
compare() {
  local a b; a=$(listing "$VM_URL" | sort); b=$(listing "$OLD_URL" | sort)
  if [ "$a" = "$b" ] && [ -n "$a" ]; then echo "IDENTICAL: $(echo "$a" | wc -l) entries (objects and versions) match between $OLD_URL and $VM_URL"; return 0; fi
  echo "DIFFERENT: the stores do not match:"; diff <(echo "$a") <(echo "$b") | head -12; return 1
}
mode="${1:-}"
case "$mode" in
  --check) compare; exit $? ;;
  --old-to-vm) [ "${ALLOW_OLD_TO_VM:-}" = 1 ] || { echo "refusing: the VM is the live store now; --old-to-vm would replace it with the old host's copy. Set ALLOW_OLD_TO_VM=1 only if you mean it." >&2; exit 2; } ;;
  --vm-to-old) ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \?//'; exit 2 ;;
esac

stamp=$(date +%Y%m%d-%H%M%S)
tmp=/tmp/rustfs-sync.$$
if [ "$mode" = "--old-to-vm" ]; then
  echo "re-copying $OLD:/opt/rustfs/data -> $VM (the old store is stopped for the copy)"
  old 'docker stop rustfs >/dev/null 2>&1; tar -C /opt/rustfs --numeric-owner -cf - data; docker start rustfs >/dev/null 2>&1' > "$tmp"
  vm 'docker stop rustfs >/dev/null 2>&1 || true'
  vm "[ -d /opt/rustfs/data ] && mv /opt/rustfs/data /opt/rustfs/data.before-sync-$stamp; true"
  vm 'tar -C /opt/rustfs --numeric-owner -xpf -' < "$tmp"
  vm 'docker start rustfs >/dev/null'
else
  echo "ROLLBACK: copying $VM:/opt/rustfs/data -> $OLD (the VM's store is stopped for the copy)"
  vm 'docker stop rustfs >/dev/null 2>&1; tar -C /opt/rustfs --numeric-owner -cf - data; docker start rustfs >/dev/null 2>&1' > "$tmp"
  old 'docker stop rustfs >/dev/null 2>&1 || true'
  old "[ -d /opt/rustfs/data ] && mv /opt/rustfs/data /opt/rustfs/data.before-sync-$stamp; true"
  old 'tar -C /opt/rustfs --numeric-owner -xpf -' < "$tmp"
  old 'docker start rustfs >/dev/null'
fi
rm -f "$tmp"
for i in $(seq 1 20); do [ "$(curl -s -o /dev/null -w %{http_code} "$VM_URL/health")" = 200 ] && [ "$(curl -s -o /dev/null -w %{http_code} "$OLD_URL/health")" = 200 ] && break; sleep 2; done
compare
