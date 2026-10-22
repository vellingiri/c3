#!/usr/bin/env bash
# Capture everything needed to rebuild the host `c3` from nothing (docs/c3-rebuild.md). Run ON c3 as root.
#
#   c3-dr-capture.sh --dry-run          read-only: say what would be captured and how big it is (writes nothing)
#   c3-dr-capture.sh                    build a bundle in /root/dr-staging/c3-dr-<timestamp>/ (mode 700) and push it to s3
#   c3-dr-capture.sh --no-push          build the bundle only
#
# What goes in (and why; nothing here is "nice to have", each item is something the rebuild script needs):
#   etc.tgz            all of /etc except machine-specific noise (passwd/shadow/machine-id, per-VM libvirt/apparmor files, generated certs, OVS database)
#   db/*.sql.gz        every OpenStack database (keystone and glance are RESTORED; the others are kept for forensics and recreated by db sync)
#   db/users.sql       MariaDB users and their grants, with password hashes (so the services' passwords in /etc keep working)
#   rabbitmq-definitions.json   the RabbitMQ user/vhost/permissions
#   varlib.tgz         small stateful dirs under /var/lib and /var/cache (Samba, BIND, Octavia, Horizon secret key, libvirt, nova ssh key ...)
#   root.tgz           /root (scripts, ssh keys, the Octavia work dir, the router config tarballs; not caches, history or large images)
#   usr-local.tgz      /usr/local (the reconcilers installed by hand)
#   cron/              root's crontab and /var/spool/cron
#   packages/          dpkg selections, manually installed packages, versions of the OpenStack packages
#   ref/               read-only dumps of the cloud (catalog, flavors, networks, security groups, load balancers, images, DNS, ...) and of the host (ip, ovs, mounts)
#   MANIFEST + SHA256SUMS
# Mirrored separately (large, copied only when new): the Glance image files and the patched amphora images -> s3:/backup/c3-dr/images/,
# and /share (the NFS/Samba share, the finance app tree) -> s3:/backup/c3-dr/share/.
# NOT captured, on purpose: the VM disks (/var/lib/nova/instances, 70 GB; every VM is rebuilt by Terraform and its data restored from the
# app-level backups, docs/c3-rebuild.md "What is lost"), the OVN databases (rebuilt from Neutron by Terraform), podman images, logs, caches.
# The bundle contains secrets (service passwords, Fernet keys, the Octavia CA key, ssh keys): staging dir and the s3 copy are root-only.
set -euo pipefail
AMP_DIRS="$(ls /root/amphora-fix/*.qcow2 /nfsshare/qcow2/*.qcow2 2>/dev/null | tr '\n' ' ')"   # amphora images kept outside the OpenStack image store

STAGE=${STAGE:-/root/dr-staging}
S3=${S3:-root@192.168.2.4}
S3_DIR=${S3_DIR:-/backup/c3-dr}
KEEP_LOCAL=${KEEP_LOCAL:-2}
KEEP_REMOTE=${KEEP_REMOTE:-21}
DBS="keystone glance nova nova_api nova_cell0 neutron_ml2 octavia designate placement cinder"

DRY=0; PUSH=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-push) PUSH=0 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
OUT=$STAGE/c3-dr-$TS
say() { printf '%s\n' "$*"; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
umask 077

# ---- what to leave out of /etc (machine specific or regenerated); everything else is captured
ETC_EXCLUDES=(
  --exclude=etc/machine-id --exclude=etc/ssl/certs --exclude=etc/alternatives --exclude=etc/ca-certificates
  --exclude='etc/libvirt/qemu/*.xml' --exclude='etc/libvirt/qemu/autostart' --exclude='etc/apparmor.d/libvirt/libvirt-*'
  --exclude='etc/openvswitch/conf.db*' --exclude='etc/openvswitch/.conf.db*' --exclude=etc/lvm/archive --exclude=etc/cups/ppd
  --exclude=etc/resolv.conf.bak-* --exclude='etc/*.bak-2026*' --exclude='etc/*/*.bak-2026*'
)
ROOT_EXCLUDES=(
  --exclude=root/.cache --exclude=root/.local --exclude=root/.bash_history --exclude=root/.viminfo --exclude=root/.lesshst
  --exclude=root/backups --exclude=root/dr-staging --exclude='root/*.log' --exclude='root/*.qcow2' --exclude='root/amphora-fix/*.qcow2'
  --exclude='root/amphora-fix/mnt*' --exclude=root/.mariadb_history
)
VARLIB="var/lib/samba var/cache/bind var/lib/bind var/lib/octavia var/lib/openstack-dashboard var/lib/horizon var/lib/designate var/lib/neutron
        var/lib/keystone var/lib/placement var/lib/glance/.ssh var/lib/nova/.ssh var/lib/libvirt/secrets var/lib/ucf var/lib/nfs"

size_of_tar() { tar --ignore-failed-read "$@" -cf - 2>/dev/null | wc -c; }

if [ "$DRY" = 1 ]; then
  say "== dry run: nothing is written (bundle would be $OUT)"
  say "etc.tgz          ~ $(human "$(size_of_tar -C / "${ETC_EXCLUDES[@]}" etc)") uncompressed"
  say "root.tgz         ~ $(human "$(size_of_tar -C / "${ROOT_EXCLUDES[@]}" root)") uncompressed"
  say "usr-local.tgz    ~ $(human "$(size_of_tar -C / usr/local)") uncompressed"
  say "varlib.tgz       ~ $(human "$(size_of_tar -C / $VARLIB)") uncompressed"
  for d in $DBS; do
    n=$(mariadb -N -B -e "select round(coalesce(sum(data_length+index_length),0)/1024) from information_schema.tables where table_schema='$d'" 2>/dev/null || echo "?")
    say "db $d      ~ ${n} KiB of data"
  done
  say "rabbitmq definitions: $(rabbitmqctl list_users 2>/dev/null | wc -l) lines of users"
  say "glance images   : $(du -sh /var/lib/glance/images 2>/dev/null | cut -f1) in $(ls /var/lib/glance/images 2>/dev/null | wc -l) files (mirrored to $S3:$S3_DIR/images/, only new ones copied)"
  say "extra qcow2     : $(du -ch $AMP_DIRS 2>/dev/null | tail -1 | cut -f1) ($AMP_DIRS, mirrored too)"
  say "/share          : $(du -sh /share 2>/dev/null | cut -f1) (mirrored to $S3:$S3_DIR/share/)"
  say "not captured    : /var/lib/nova/instances $(du -sh /var/lib/nova/instances 2>/dev/null | cut -f1) (VM disks), logs, caches, podman images"
  say "reference dumps : $(command -v openstack >/dev/null && echo "openstack CLI available" || echo "openstack CLI MISSING")"
  exit 0
fi

mkdir -p "$OUT"/{db,cron,packages,ref}
chmod 700 "$STAGE" "$OUT"
say "== bundle $OUT"

say "-- /etc"
tar --xattrs --acls --ignore-failed-read -czf "$OUT/etc.tgz" -C / "${ETC_EXCLUDES[@]}" etc 2>/dev/null || true
say "-- /root, /usr/local, /var/lib (small state)"
tar --xattrs --ignore-failed-read -czf "$OUT/root.tgz" -C / "${ROOT_EXCLUDES[@]}" root 2>/dev/null || true
tar --xattrs --ignore-failed-read -czf "$OUT/usr-local.tgz" -C / usr/local 2>/dev/null || true
# shellcheck disable=SC2086
tar --xattrs --ignore-failed-read -czf "$OUT/varlib.tgz" -C / $VARLIB 2>/dev/null || true

say "-- databases"
for d in $DBS; do
  mariadb-dump --single-transaction --routines --events --skip-lock-tables "$d" 2>/dev/null | gzip > "$OUT/db/$d.sql.gz" || say "   (database $d: dump failed or absent)"
done
# users with password hashes and grants (restored before the databases, so the passwords in /etc keep working)
mariadb -N -B -e "SELECT CONCAT('SHOW CREATE USER \`',user,'\`@\`',host,'\`; SHOW GRANTS FOR \`',user,'\`@\`',host,'\`;') FROM mysql.user WHERE user NOT IN ('mariadb.sys','mysql','root','PUBLIC','')" \
  | mariadb -N -B | sed 's/$/;/' > "$OUT/db/users.sql"
chmod 600 "$OUT/db/"*
say "-- rabbitmq"
rm -f /tmp/rabbitmq-definitions.json
rabbitmqctl export_definitions /tmp/rabbitmq-definitions.json >/dev/null 2>&1 && mv /tmp/rabbitmq-definitions.json "$OUT/rabbitmq-definitions.json" || say "   (rabbitmq export failed)"

say "-- cron, packages"
crontab -l > "$OUT/cron/root.crontab" 2>/dev/null || : > "$OUT/cron/root.crontab"
tar --ignore-failed-read -czf "$OUT/cron/spool.tgz" -C / var/spool/cron 2>/dev/null || true
dpkg --get-selections > "$OUT/packages/dpkg-selections.txt"
apt-mark showmanual > "$OUT/packages/manual.txt"
dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | grep -E '^(nova|neutron|keystone|glance|placement|octavia|designate|cinder|openstack-dashboard|python3-(nova|neutron|keystone|glance|octavia|designate|openstack)|ovn|openvswitch|libvirt-daemon|qemu-system-x86|mariadb-server|rabbitmq-server|memcached|apache2|bind9|samba|nfs-kernel-server) ' > "$OUT/packages/openstack-versions.txt" || true
cp /etc/os-release "$OUT/packages/os-release"; uname -a > "$OUT/packages/uname.txt"

say "-- reference dumps (read-only API calls)"
R=$OUT/ref
cmd() { local f=$1; shift; "$@" > "$R/$f" 2>&1 || echo "(failed: $*)" >> "$R/$f"; }
if command -v openstack >/dev/null; then
  cmd catalog.json openstack catalog list -f json
  cmd services.json openstack service list --long -f json
  cmd endpoints.json openstack endpoint list -f json
  cmd projects.json openstack project list --long -f json
  cmd users.json openstack user list --long -f json
  cmd roles.json openstack role assignment list --names -f json
  cmd flavors.json openstack flavor list --all --long -f json
  cmd images.json openstack image list --long -f json
  cmd networks.json openstack network list --long -f json
  cmd subnets.json openstack subnet list --long -f json
  cmd routers.json openstack router list --long -f json
  cmd security-groups.json openstack security group list -f json
  cmd security-group-rules.json openstack security group rule list --long -f json
  cmd floating-ips.json openstack floating ip list --long -f json
  cmd keypairs.json openstack keypair list -f json
  cmd servers.json openstack server list --all-projects --long -f json
  cmd compute-services.json openstack compute service list -f json
  cmd network-agents.json openstack network agent list -f json
  cmd hypervisors.json openstack hypervisor list -f json
  cmd resource-usage.txt openstack resource provider list
  cmd loadbalancers.json openstack loadbalancer list -f json
  cmd lb-listeners.json openstack loadbalancer listener list -f json
  cmd lb-pools.json openstack loadbalancer pool list -f json
  cmd lb-members.json bash -c 'for p in $(openstack loadbalancer pool list -f value -c id); do openstack loadbalancer member list $p -f json; done'
  cmd lb-healthmonitors.json openstack loadbalancer healthmonitor list -f json
  cmd lb-flavors.json openstack loadbalancer flavor list -f json
  cmd lb-flavorprofiles.json openstack loadbalancer flavorprofile list -f json
  cmd amphorae.json openstack loadbalancer amphora list -f json
  cmd dns-zones.json openstack zone list --all-projects -f json
  cmd dns-recordsets.json bash -c 'for z in $(openstack zone list --all-projects -f value -c id); do openstack recordset list $z -f json; done'
  cmd quotas-admin.txt openstack quota show admin
  cmd limits.txt openstack limits show --absolute
fi
cmd ip-addr.txt ip -d addr
cmd ip-route.txt ip route
cmd ovs-show.txt ovs-vsctl show
cmd ovs-open_vswitch.txt ovs-vsctl list open_vswitch
cmd ovs-external-ids.txt ovs-vsctl get open_vswitch . external_ids
cmd ovs-manager.txt ovs-vsctl get-manager
cmd fstab.txt cat /etc/fstab
cmd ovs-bridges.txt bash -c 'for b in $(ovs-vsctl list-br); do echo "bridge $b: ports $(ovs-vsctl list-ports $b | grep -v "^tap" | tr "\n" " ")"; done'
cmd lsblk.txt lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINT
cmd mounts.txt findmnt -A
cmd services-enabled.txt systemctl list-unit-files --state=enabled --no-legend
cmd services-running.txt systemctl list-units --type=service --state=running --no-legend
cmd timers.txt systemctl list-timers --all --no-legend
cmd listening-ports.txt ss -ltnup
cmd samba-shares.txt testparm -s
cmd exports.txt exportfs -v
cmd nft.txt nft list ruleset
cmd free.txt free -m
cmd cpu.txt lscpu
cmd kvm-nested.txt bash -c 'cat /sys/module/kvm_intel/parameters/nested; cat /proc/cmdline'
cmd nova-modified-conf.txt bash -c "grep -v -E '^\s*(#|$)' /etc/nova/nova.conf | sed -E 's/(password|connection|transport_url|secret|key)( *= *).*/\1\2<masked>/I'"

say "-- manifest and checksums"
{
  echo "bundle: c3-dr-$TS"; echo "host: $(hostname -f)"; echo "date: $(date -Is)"; echo "kernel: $(uname -r)"
  echo "files:"; (cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name MANIFEST | sort | xargs -I{} sh -c 'printf "  %s %s\n" "$(stat -c %s "{}")" "{}"')
} > "$OUT/MANIFEST"
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
say "bundle size: $(du -sh "$OUT" | cut -f1)"

if [ "$PUSH" = 1 ]; then
  say "== push to $S3:$S3_DIR"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$S3" "mkdir -p $S3_DIR/bundles $S3_DIR/images $S3_DIR/share && chmod 700 $S3_DIR"
  rsync -a --chmod=D700,F600 "$OUT/" "$S3:$S3_DIR/bundles/c3-dr-$TS/"
  ssh "$S3" "ln -sfn $S3_DIR/bundles/c3-dr-$TS $S3_DIR/bundles/latest; ls -1d $S3_DIR/bundles/c3-dr-2* | head -n -$KEEP_REMOTE | xargs -r rm -rf"
  # large files: only what is not on s3 yet
  rsync -a --ignore-existing /var/lib/glance/images/ "$S3:$S3_DIR/images/glance/"
  for d in /root/amphora-fix /nfsshare/qcow2; do [ -d "$d" ] && rsync -a --ignore-existing --include='*.qcow2' --exclude='*' "$d/" "$S3:$S3_DIR/images/amphora-fix/"; done   # the live amphora image moved from /root/amphora-fix to /nfsshare/qcow2 (the repo host) on 2026-10-22
  rsync -a --delete /share/ "$S3:$S3_DIR/share/"
  say "pushed; latest -> c3-dr-$TS"
fi
ls -1d "$STAGE"/c3-dr-2* 2>/dev/null | head -n -"$KEEP_LOCAL" | xargs -r rm -rf
say "done $(date -Is)"
