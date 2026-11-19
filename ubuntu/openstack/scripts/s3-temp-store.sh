#!/usr/bin/env bash
# A TEMPORARY Terraform state store, for the one situation where the real one is gone: the RustFS on the `s3-prod` VM, which lives INSIDE the cloud
# it describes. Terraform cannot read its state to create the VM that serves its state, so for a while another RustFS serves it: this one, started
# on the backup host (192.168.2.4, outside the cloud) from the newest whole-store snapshot there. Procedure and reasons: docs/c3-rebuild.md,
# "When the state store is gone too", and docs/s3-state-store.md.
#
#   s3-temp-store.sh status                          is it running, which states does it hold (serial, lineage), is a hosts override active HERE
#   s3-temp-store.sh start [SNAPSHOT] [--dry-run]    copy the newest (or a named) snapshot of /backup/rustfs-vm to /opt/rustfs-temp/data and run RustFS 1.0.2
#                                                    on 192.168.2.4:9000 with the same keys as the VM (so AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY keep working)
#   s3-temp-store.sh handback --vm root@IP [--dry-run]   after the s3-prod VM exists again (terraform apply -target in environments/prod): stop the
#                                                    temporary store, keep its data as a new snapshot <time>-recovery on the backup host, restore THAT into
#                                                    the VM (scripts/s3-vm-restore.sh), and check the VM holds exactly the same states
#   s3-temp-store.sh stop [--remove]                 stop the temporary store (--remove also sets its data aside)
#
# Terraform finds this store because the address in every backend and every terraform_remote_state is the NAME s3.rdulinux.com: on the machine that
# runs Terraform, one /etc/hosts line points that name at the temporary store (this script prints it; it never edits /etc/hosts). While it is there,
# every `terraform apply` writes the NEW state into the temporary store, which is why `handback` restores from it and not from the old snapshot.
# Safe by construction: the snapshot under /backup/rustfs-vm is only READ (copied), never mounted; nothing is deleted.
set -euo pipefail
BOX="${BACKUP_BOX:-root@192.168.2.4}"
SNAPS=/backup/rustfs-vm; CFG=/backup/rustfs-vm-config; TEMP=/opt/rustfs-temp; NAME=rustfs-temp
IMG=rustfs/rustfs:1.0.2-pinned; IP=192.168.2.4; HOSTNAME_S3=s3.rdulinux.com
HERE="$(cd "$(dirname "$0")" && pwd)"
box() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$BOX" "$@" </dev/null; }
say() { printf '\n== %s\n' "$*"; }
die() { echo "STOP: $*" >&2; exit 1; }

# serial, lineage and resource count of every state object in the store at ADDR (run ON the backup host; the keys are read there, never printed)
STATES_PY='
import os, re, subprocess, json, sys
addr = sys.argv[1]
AK, SK = os.environ["RUSTFS_ACCESS_KEY"], os.environ["RUSTFS_SECRET_KEY"]
def get(path):
    p = subprocess.run(["curl", "-fsS", "-m", "20", "--aws-sigv4", "aws:amz:us-east-1:s3", "--user", AK + ":" + SK, "http://%s/terraform-state%s" % (addr, path)], capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None
x = get("?list-type=2")
if x is None: print("NOT READABLE"); sys.exit(1)
for k in sorted(re.findall(r"<Key>(.*?)</Key>", x)):
    if k.endswith(".tflock"): continue
    try:
        j = json.loads(get("/" + k)); print("%s serial=%s lineage=%s resources=%d" % (k, j.get("serial"), j.get("lineage", "")[:8], len(j.get("resources", []))))
    except Exception: print("%s UNREADABLE" % k)
'
states_at() {   # states_at ADDR : on the backup host, with the keys of the VM (the same as the temporary store uses)
  box "set -a; . $CFG/rustfs.env; set +a; python3 -c '$STATES_PY' $1"
}

cmd=${1:-}; shift || true
dry=0; remove=0; vm=""; snap=""
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) dry=1 ;; --remove) remove=1 ;; --vm) vm=$2; shift ;;
  2*) snap=$1 ;;
  *) die "unknown argument: $1" ;;
esac; shift; done

hosts_here() { grep -E "^[^#]*[[:space:]]$HOSTNAME_S3" /etc/hosts 2>/dev/null | head -1 || true; }

case "$cmd" in
status)
  say "temporary store on $BOX"
  if box "docker ps --format '{{.Names}} {{.Status}} {{.Ports}}' | grep -q '^$NAME '"; then
    box "docker ps --format '  {{.Names}} | {{.Status}} | {{.Ports}}' --filter name=$NAME"
    echo "  health: $(box "curl -s -o /dev/null -m 5 -w '%{http_code}' http://$IP:9000/health")"
    states_at "$IP:9000" | sed 's/^/  /'
  else echo "  not running"; box "[ -d $TEMP/data ] && echo '  data from an earlier run is in $TEMP/data' || true"; fi
  say "this machine"
  h=$(hosts_here); if [ -n "$h" ]; then echo "  /etc/hosts overrides $HOSTNAME_S3: $h   <- Terraform here uses the TEMPORARY store"; else echo "  no /etc/hosts override: $HOSTNAME_S3 resolves normally ($(getent hosts $HOSTNAME_S3 2>/dev/null | awk '{print $1}' || true))"; fi
  ;;
start)
  [ -n "$snap" ] || snap=$(box "readlink $SNAPS/latest") || true
  [ -n "$snap" ] || die "no snapshot on the backup host ($SNAPS/latest)"
  say "start the temporary state store from snapshot $snap"
  box "[ -d $SNAPS/$snap/terraform-state ]" || die "snapshot $SNAPS/$snap has no terraform-state folder"
  box "command -v docker >/dev/null" || die "docker is not installed on the backup host"
  box "! ss -tln | grep -q '$IP:9000 '" || die "something already listens on $IP:9000 on the backup host (the old RustFS? $NAME?)"
  box "[ ! -e $TEMP/data ]" || die "$TEMP/data exists on the backup host: an earlier temporary store. Look at it (status), then stop --remove, or this would overwrite recovery work"
  box "[ -s $CFG/rustfs.env ] && [ -s $CFG/rustfs-1.0.2-image.tar ]" || die "the rebuild kit is incomplete: $CFG/rustfs.env or the image tarball is missing"
  echo "  snapshot: $SNAPS/$snap ($(box "du -sh $SNAPS/$snap | cut -f1"))   image: $IMG   listen: $IP:9000   data: $TEMP/data"
  if [ "$dry" = 1 ]; then echo "dry run: nothing started"; exit 0; fi
  if ! box "docker image inspect $IMG >/dev/null 2>&1"; then
    echo "  loading the RustFS image from the rebuild kit"; box "cd $CFG && sha256sum -c --quiet rustfs-1.0.2-image.tar.sha256 && docker load -i rustfs-1.0.2-image.tar" | tail -1
  fi
  box "umask 077; mkdir -p $TEMP/data && rsync -a --numeric-ids $SNAPS/$snap/ $TEMP/data/"
  box "docker run -d --name $NAME --restart no --user rustfs --security-opt no-new-privileges:true -p $IP:9000:9000 -v $TEMP/data:/data --env-file $CFG/rustfs.env $IMG /data >/dev/null"
  for i in $(seq 1 30); do [ "$(box "curl -s -o /dev/null -m 3 -w '%{http_code}' http://$IP:9000/health")" = 200 ] && break; sleep 2; done
  [ "$(box "curl -s -o /dev/null -m 3 -w '%{http_code}' http://$IP:9000/health")" = 200 ] || die "the temporary store did not become healthy (docker logs $NAME on the backup host)"
  echo "  health 200. States in it:"; states_at "$IP:9000" | sed 's/^/    /'
  cat <<EOF

NEXT (on the machine that runs Terraform: your Mac, or c3):
  1. point the name at the temporary store:
       echo "$IP $HOSTNAME_S3   # TEMPORARY state store (scripts/s3-temp-store.sh)" | sudo tee -a /etc/hosts
     (macOS: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder)
  2. in each stack:  terraform init -reconfigure     (same bucket and key, the name now resolves to the temporary store)
  3. rebuild as in docs/c3-rebuild.md; create the VM first:  cd environments/prod && terraform apply -target='module.node["s3-prod"]'
  4. when the VM is up:  scripts/s3-temp-store.sh handback --vm root@<its address>
EOF
  ;;
handback)
  [ -n "$vm" ] || die "give the new VM: --vm root@<address>   (its address, NOT the name: the name still points at the temporary store)"
  say "hand the state back to the s3-prod VM ($vm)"
  box "docker ps --format '{{.Names}}' | grep -q '^$NAME$'" || die "the temporary store is not running (status)"
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$vm" 'systemctl is-active docker' </dev/null | grep -q active || die "cannot reach $vm over ssh, or docker is not running there (is cloud-init finished?)"
  stamp=$(date +%Y%m%d-%H%M%S); new="$stamp-recovery"
  echo "  1. stop the temporary store (a clean stop, so its files are consistent)"
  echo "  2. keep its data as the snapshot $SNAPS/$new on the backup host"
  echo "  3. restore that snapshot into $vm with scripts/s3-vm-restore.sh (the VM's own data, if any, is moved aside, not deleted)"
  echo "  4. compare the states in the VM with the ones in the temporary store: they must be identical"
  if [ "$dry" = 1 ]; then echo "dry run: nothing changed"; exit 0; fi
  states_at "$IP:9000" > "${TMPDIR:-/tmp}/s3-temp-before.$$"
  box "docker stop -t 60 $NAME >/dev/null && umask 077 && mkdir -p $SNAPS/$new && rsync -a --numeric-ids $TEMP/data/ $SNAPS/$new/ && [ -d $SNAPS/$new/terraform-state ]" || die "could not make the recovery snapshot (the temporary store is stopped; docker start $NAME brings it back)"
  S3_VM="$vm" BACKUP_BOX="${BACKUP_BOX:-backup}" "$HERE/s3-vm-restore.sh" "$new"
  # the VM now serves; read its states by ITS address (the keys are the same)
  vm_ip=${vm#*@}
  states_at "$vm_ip:9000" > "${TMPDIR:-/tmp}/s3-temp-after.$$" || die "the VM does not answer on $vm_ip:9000"
  if diff -q "${TMPDIR:-/tmp}/s3-temp-before.$$" "${TMPDIR:-/tmp}/s3-temp-after.$$" >/dev/null; then echo "  the VM holds exactly the states the temporary store held:"; sed 's/^/    /' "${TMPDIR:-/tmp}/s3-temp-after.$$"
  else echo "DIFFERENT:" >&2; diff "${TMPDIR:-/tmp}/s3-temp-before.$$" "${TMPDIR:-/tmp}/s3-temp-after.$$" >&2 || true; rm -f "${TMPDIR:-/tmp}"/s3-temp-*.$$; die "do not go back yet: the VM and the temporary store differ (the temporary store is stopped, its data is in $TEMP/data and $SNAPS/$new)"; fi
  rm -f "${TMPDIR:-/tmp}"/s3-temp-*.$$
  cat <<EOF

NEXT:
  1. remove the override on the machine(s) that had it:   sudo sed -i.bak '/$HOSTNAME_S3/d' /etc/hosts     (macOS: sed -i '' ... ; flush the DNS cache)
  2. the name must now reach the VM (DNS record s3-prod -> its floating IP, made by terraform apply in infra):  dig +short $HOSTNAME_S3 @192.168.2.2
  3. in each stack:  terraform init -reconfigure ; terraform plan   (no changes expected)
  4. clean up:  scripts/s3-temp-store.sh stop --remove     (the data stays in $SNAPS/$new as a snapshot too)
EOF
  ;;
stop)
  say "stop the temporary store"
  if box "docker ps -a --format '{{.Names}}' | grep -q '^$NAME$'"; then box "docker rm -f $NAME >/dev/null && echo '  container removed'"; else echo "  no container"; fi
  if [ "$remove" = 1 ]; then box "[ -d $TEMP ] && mv $TEMP $TEMP.done-$(date +%Y%m%d-%H%M%S) && echo '  data set aside as $TEMP.done-<time> (delete it when you are sure)' || true"; fi
  h=$(hosts_here); [ -z "$h" ] || echo "  REMEMBER: this machine still has an /etc/hosts override: $h"
  ;;
*) sed -n 2,22p "$0"; exit 2 ;;
esac
