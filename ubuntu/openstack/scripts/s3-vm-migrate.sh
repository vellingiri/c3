#!/usr/bin/env bash
# Keep the s3-prod VM's RustFS identical to the old s3 host's, and say so. Run from your Mac.
#   scripts/s3-vm-migrate.sh --check     # compare both stores object by object, version by version (read-only)
#   scripts/s3-vm-migrate.sh             # re-copy old -> VM (the old store is stopped for the few seconds of the copy, then started again), then compare
# The old host stays the live state store until the Terraform backends are switched (docs/s3-state-store.md, "Moving the state store to s3-prod"). Until then
# every `terraform apply` writes to the OLD store, so run this again right before the switch, with no Terraform running anywhere.
# Nothing is deleted: the VM's previous data is moved to /opt/rustfs/data.before-sync-<time>.
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
[ "${1:-}" = "--check" ] && { compare; exit $?; }

stamp=$(date +%Y%m%d-%H%M%S)
echo "re-copying $OLD:/opt/rustfs/data -> $VM (old store stopped for the copy)"
old 'docker stop rustfs >/dev/null 2>&1; tar -C /opt/rustfs --numeric-owner -cf - data; docker start rustfs >/dev/null 2>&1' > /tmp/rustfs-sync.$$
vm 'docker stop rustfs >/dev/null 2>&1 || true'
vm "[ -d /opt/rustfs/data ] && mv /opt/rustfs/data /opt/rustfs/data.before-sync-$stamp; true"
vm 'tar -C /opt/rustfs --numeric-owner -xpf -' < /tmp/rustfs-sync.$$; rm -f /tmp/rustfs-sync.$$
vm 'docker start rustfs >/dev/null'
for i in $(seq 1 20); do [ "$(curl -s -o /dev/null -w %{http_code} "$VM_URL/health")" = 200 ] && break; sleep 2; done
compare
