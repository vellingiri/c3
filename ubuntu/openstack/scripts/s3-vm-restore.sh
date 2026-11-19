#!/usr/bin/env bash
# Restore the RustFS store on the s3-prod VM from a snapshot held on the backup box (`s3`, /backup/rustfs-vm/<timestamp>/). Run from your Mac.
#   scripts/s3-vm-restore.sh --list                 # the snapshots there are
#   scripts/s3-vm-restore.sh --dry-run              # say what would happen, change nothing
#   scripts/s3-vm-restore.sh                        # restore the newest snapshot
#   scripts/s3-vm-restore.sh 20261115-133654        # restore a particular one
# Safe by construction: what is on the VM now is MOVED aside to /opt/rustfs/data.before-restore-<time> (never deleted), so a wrong choice is undone by moving it back.
# Also rebuilds a brand-new VM: if the VM has no RustFS image or settings yet, they come from /backup/rustfs-vm-config on the backup box (the exact 1.0.2 image and
# the keys; root-only). Afterwards `terraform plan` in infra and every environment must show no changes (docs/s3-state-store.md).
set -euo pipefail
VM="${S3_VM:-root@s3.rdulinux.com}"
BOX="${BACKUP_BOX:-backup}"
SNAPS=/backup/rustfs-vm
CFG=/backup/rustfs-vm-config
SSHV=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
vm() { "${SSHV[@]}" "$VM" "$@"; }
box() { ssh -o BatchMode=yes "$BOX" "$@"; }

dry=0; snap=""
for a in "$@"; do case "$a" in
  --list) box "ls -1d $SNAPS/2* | xargs -n1 basename | tail -30; echo; echo latest: \$(readlink $SNAPS/latest); echo last good copy: \$(stat -c %y $SNAPS/last-ok)"; exit 0;;
  --dry-run) dry=1;;
  2*) snap="$a";;
  *) echo "unknown argument: $a" >&2; exit 2;;
esac; done
[ -n "$snap" ] || snap=$(box "readlink $SNAPS/latest")
box "[ -d $SNAPS/$snap/terraform-state ]" || { echo "no such snapshot on $BOX: $SNAPS/$snap" >&2; exit 1; }
stamp=$(date +%Y%m%d-%H%M%S)
echo "restore $SNAPS/$snap  (from $BOX)  into  $VM:/opt/rustfs/data"
echo "  the current data is moved to /opt/rustfs/data.before-restore-$stamp, not deleted"
[ "$dry" = 1 ] && { echo "dry run: nothing changed"; exit 0; }

# a new VM: the image and the settings come from the backup box
vm 'command -v docker >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 rsync curl python3; }; systemctl enable --now docker >/dev/null 2>&1; mkdir -p /opt/rustfs && chmod 700 /opt/rustfs'
if ! vm 'docker image inspect rustfs/rustfs:1.0.2-pinned >/dev/null 2>&1'; then
  echo "loading the RustFS 1.0.2 image from the backup box"
  box "cd $CFG && sha256sum -c rustfs-1.0.2-image.tar.sha256 >/dev/null && cat $CFG/rustfs-1.0.2-image.tar" | vm 'docker load' | tail -1
fi
vm '[ -s /opt/rustfs/.env ]' || { echo "settings from the backup box"; box "cat $CFG/rustfs.env" | vm 'umask 077; cat > /opt/rustfs/.env'; }

vm "docker rm -f rustfs >/dev/null 2>&1 || true; [ -d /opt/rustfs/data ] && mv /opt/rustfs/data /opt/rustfs/data.before-restore-$stamp; mkdir -p /opt/rustfs"
box "tar -C $SNAPS/$snap --numeric-owner -cf - ." | vm 'mkdir -p /opt/rustfs/data && tar -C /opt/rustfs/data --numeric-owner -xpf -'
# the kit's .env may carry the address of the machine it came from: point RUSTFS_BIND_IP at THIS VM's own address
vm 'ip=$(hostname -I | cut -d" " -f1); [ -n "$ip" ] && sed -i "s/^RUSTFS_BIND_IP=.*/RUSTFS_BIND_IP=$ip/" /opt/rustfs/.env'
vm '[ -s /opt/rustfs/compose.yaml ]' || { echo "compose.yaml from the backup box"; box "cat $CFG/compose.yaml" | vm 'cat > /opt/rustfs/compose.yaml; chmod 644 /opt/rustfs/compose.yaml'; }
vm 'cd /opt/rustfs && docker compose up -d >/dev/null 2>&1' || true
vm '[ -n "$(docker ps -q -f name=^rustfs$)" ]' || vm 'docker run -d --name rustfs --restart unless-stopped --user rustfs --security-opt no-new-privileges:true -p 9000:9000 -p 80:9001 -v /opt/rustfs/data:/data --env-file /opt/rustfs/.env rustfs/rustfs:1.0.2-pinned /data >/dev/null'
for i in $(seq 1 20); do [ "$(vm 'curl -s -o /dev/null -w %{http_code} http://127.0.0.1:9000/health')" = 200 ] && break; sleep 2; done
vm 'echo "health: $(curl -s -o /dev/null -w %{http_code} http://127.0.0.1:9000/health)"
AK=$(sed -n "s/^RUSTFS_ACCESS_KEY=//p" /opt/rustfs/.env); SK=$(sed -n "s/^RUSTFS_SECRET_KEY=//p" /opt/rustfs/.env)
echo "state objects: $(curl -fsS --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AK:$SK" "http://127.0.0.1:9000/terraform-state?list-type=2" | grep -o "<Key>[^<]*</Key>" | grep -vc tflock)  (expect 4: infra, prod, qa, cka)"'
echo "done. Next: terraform plan in infra and each environment must show no changes. The replaced data is kept at /opt/rustfs/data.before-restore-$stamp"
