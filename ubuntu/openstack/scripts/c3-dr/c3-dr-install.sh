#!/usr/bin/env bash
# Rebuild the platform of `c3` (OpenStack Epoxy on Debian 13, the stack documented in docs/c3-rebuild.md and built originally after
# https://www.server-world.info/en/note?os=Debian_13&p=openstack_epoxy&f=1 with Apache instead of nginx) on a NEW machine from the latest capture bundle
# (scripts/c3-dr/c3-dr-capture.sh). Run ON the new host as root, after a minimal Debian 13 install.
#
#   c3-dr-install.sh --bundle DIR [--images DIR] [--share DIR] [--yes] [--dry-run] [--from N] [--only N]
#     --bundle  a bundle directory, e.g. a copy of s3:/backup/c3-dr/bundles/latest
#     --images  Glance image files (default <bundle>/../../images/glance)
#     --share   a copy of the /share tree (default <bundle>/../../share)
#     --dry-run print every step instead of doing it
#     --from N / --only N   run from phase N / only phase N (phases are numbered below; every phase can be re-run)
#
# Phases:  0 preflight   1 base system   2 database, messaging   3 restore configuration   4 identity, images, placement
#          5 compute, network (OVS/OVN, Neutron)   6 DNS (Designate/BIND), dashboard   7 local software, share, cron   8 verify
# After it: terraform apply in infra/, then scripts/c3-dr/c3-dr-post.sh (Octavia, load balancers), then the environments (docs/c3-rebuild.md).
#
# Design: KEYSTONE and GLANCE are restored from their database dumps (users, projects, roles, endpoints, image records keep their IDs, so the Terraform
# state of images stays valid); every other OpenStack database is created empty and migrated (Nova, Neutron, Placement, Octavia, Designate): the VMs,
# networks, ports and load balancers they describe are rebuilt by Terraform and scripts, because the VM disks are gone with the old host. The
# configuration of every service comes from the captured /etc, so settings (RAM/disk ratios, heartbeat_timeout, ...) are not retyped.
# NOT tested end to end on bare hardware: the capture side and the static checks are; see docs/c3-rebuild.md "Test status". Read a phase before you run it.
set -euo pipefail

BUNDLE=""; IMAGES=""; SHARE=""; YES=0; DRY=0; FROM=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE=$2; shift 2 ;; --images) IMAGES=$2; shift 2 ;; --share) SHARE=$2; shift 2 ;;
    --yes) YES=1; shift ;; --dry-run) DRY=1; shift ;; --from) FROM=$2; shift 2 ;; --only) ONLY=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$BUNDLE" ] || { sed -n 2,18p "$0"; exit 2; }
BUNDLE=$(cd "$BUNDLE" && pwd)
: "${IMAGES:=$BUNDLE/../../images/glance}"; : "${SHARE:=$BUNDLE/../../share}"

HOST_FQDN=c3.rdulinux.com
HOST_IP=192.168.2.2
NIC_LAN=${NIC_LAN:-enp3s0}          # bridged into br0 (192.168.2.2/24)
NIC_EXT=${NIC_EXT:-enp4s0}          # the OVS provider bridge br-enp4s0 (physnet1, the external network)
OVS_EXT_BRIDGE=br-enp4s0
STAGE=/root/dr-etc-stage
export DEBIAN_FRONTEND=noninteractive

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then printf '   [dry-run] %s\n' "$*"; else eval "$@"; fi; }
want() { [ -n "$ONLY" ] && { [ "$ONLY" = "$1" ]; return; }; [ "$1" -ge "$FROM" ]; }
need_file() { [ -e "$1" ] || { echo "missing in bundle: $1" >&2; exit 1; }; }
wait_http() { # wait_http <url> <seconds> [expected code regexp]
  local i; for i in $(seq 1 "$2"); do curl -s -o /dev/null -m 3 -w '%{http_code}' "$1" 2>/dev/null | grep -q -E "${3:-^(200|300|401)$}" && return 0; sleep 2; done
  echo "timeout waiting for $1" >&2; return 1; }
# the admin credentials: the OS_* exports of root's shell profile (restored from the bundle). Not sourced as a whole, because .bashrc stops early in a non-interactive shell.
load_os_env() { eval "$(grep -E '^export OS_' /root/.bashrc 2>/dev/null)"; }

# ------------------------------------------------------------------------------------------------------------------------------------ packages
PKG_BASE="ifupdown bridge-utils openssh-server rsync curl git jq crudini nftables chrony python3-pymysql ca-certificates gnupg"
PKG_INFRA="mariadb-server rabbitmq-server memcached apache2 libapache2-mod-wsgi-py3"
PKG_IDENTITY="keystone glance placement-api python3-openstackclient python3-keystoneclient python3-glanceclient"
PKG_COMPUTE="nova-api nova-conductor nova-scheduler nova-compute nova-compute-kvm nova-consoleproxy python3-novaclient libvirt-daemon-system libvirt-clients qemu-system-x86 qemu-utils"
PKG_NETWORK="neutron-server neutron-api neutron-rpc-server neutron-dhcp-agent neutron-ovn-metadata-agent python3-neutronclient openvswitch-switch ovn-central ovn-host ovn-common"
PKG_DNS="designate-api designate-central designate-mdns designate-producer designate-worker python3-designateclient bind9 bind9-utils bind9-dnsutils"
PKG_LB="octavia-api octavia-health-manager octavia-housekeeping octavia-worker python3-octaviaclient"
PKG_UI="openstack-dashboard"
PKG_SHARE="nfs-kernel-server samba"
# Cinder (block storage) is NOT installed: it was disabled since 2026-08 and removed from the catalog on 2026-10-20 (docs/c3-reboot.md, CHANGELOG).

DBS_RESTORE="keystone glance"
DBS_FRESH="nova nova_api nova_cell0 neutron_ml2 octavia designate placement"

# the parts of the captured /etc that are put back; everything else is only reported (see phase 3)
ETC_RESTORE="keystonerc ovn nftables.conf modules hosts.allow hosts.deny apache2 bind designate glance keystone libvirt memcached.conf mysql neutron nova octavia openstack-dashboard placement rabbitmq rndc.conf samba exports hosts default sysctl.d sysctl.conf network systemd/system apparmor.d/local modprobe.d modules-load.d environment profile.d ssh/sshd_config ssh/sshd_config.d chrony logrotate.d security/limits.d udev/rules.d"
ETC_IGNORE_REGEX='^(adjtime|anacrontab|apparmor|bash_completion|binfmt.d|bogofilter.cf|castellan|chatscripts|chromium|cinder|cracklib|credstore.*|cupshelpers|dbconfig-common|depmod.d|dhcpcd.conf|dictionaries-common|emacs|firefox-esr|fuse.conf|fwupd|glvnd|gnome-remote-desktop|gprofng.rc|grub.d|ifplugd|ipp-usb|kernel-img.conf|keyutils|ldap|libao.conf|libblockdev|libguestfs-tools.conf|libreoffice|lighttpd|lynx|matplotlibrc|mdevctl.d|mtools.conf|netconfig|ODBCDataSources|openni2|openvswitch|os-brick|PackageKit|paperspecs|pki|plymouth|policy.d|.pwd.lock|pycadf|qemu-ifdown|qemu-ifup|reportbug.conf|resolv.conf.bak-.*|rtslib-fb-target|runit|rygel.conf|sasl2|snmp|sudo.*|sv|swtpm.*|target|tgt|timidity|udisks2|.updated|UPower|vdpau_wrapper.cfg|virt-builder|vulkan|xattr.conf|adduser.conf|alternatives|apparmor.d|apt|bash.bashrc|bash_completion.d|bindresvport.blacklist|ca-certificates|ca-certificates.conf|cloud|console-setup|cron.*|dbus-1|debconf.conf|debian_version|deluser.conf|dhcp|dpkg|e2scrub.conf|environment.d|ethertypes|fonts|fstab|gdm3|groff|group.*|gshadow.*|gss|host.conf|hostname|init.d|initramfs-tools|inputrc|insserv.conf.d|issue.*|kernel|ld.so.*|libaudit.conf|locale.*|localtime|login.defs|logcheck|lsb-release|machine-id|magic.*|mailcap.*|manpath.config|mime.types|mke2fs.conf|modprobe.d|motd|mtab|nanorc|networks|nsswitch.conf|opt|os-release|pam.*|passwd.*|perl|polkit-1|ppp|profile|protocols|python3.*|rc.*.d|rcS.d|resolv.conf|rmt|rpc|runlevel.*|security|selinux|services|shadow.*|shells|skel|ssl|subgid.*|subuid.*|sudoers.*|sysstat|terminfo|timezone|tmpfiles.d|ucf.conf|udev|ufw|update-motd.d|usb_modeswitch.*|vconsole.conf|vim|wgetrc|X11|xdg|xml|zsh_command_not_found|acpi|avahi|bluetooth|colord|cups|geoclue|ModemManager|NetworkManager|pipewire|pulse|speech-dispatcher|wpa_supplicant|sane.d|alsa|brltty|libnl-3|lvm|mdadm|multipath.conf|open-iscsi|iscsi|nvme|ceph|nfs.conf|nfs.conf.d|nfsmount.conf|idmapd.conf|request-key.*|sgml|python3|openal|odbc.*|opt|java.*|ImageMagick-.*|papersize|pnm2ppa.conf|resolvconf|rsyslog.*|ssh|sensors.*|texmf|ghostscript|gnome|dconf|gtk-.*|ld.so.conf.d|logrotate.conf|libaccountsservice|gai.conf|rc.local|ntpsec|libibverbs.d|mailname|aliases|exim4|postfix|mariadb|my.cnf|rabbitmq|haproxy|containers|podman|subuid|cni|netavark)$'

# ================================================================================================================================ phase 0
phase0() {
  say "0. preflight"
  [ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
  . /etc/os-release; [ "${VERSION_ID:-}" = 13 ] || { echo "this is for Debian 13 (found ${PRETTY_NAME:-?})" >&2; exit 1; }
  for f in etc.tgz root.tgz usr-local.tgz varlib.tgz db/users.sql rabbitmq-definitions.json SHA256SUMS packages/manual.txt; do need_file "$BUNDLE/$f"; done
  for d in $DBS_RESTORE $DBS_FRESH; do [ -e "$BUNDLE/db/$d.sql.gz" ] || note "no dump for $d (only needed for $DBS_RESTORE)"; done
  (cd "$BUNDLE" && sha256sum -c --quiet SHA256SUMS) && note "bundle checksums OK"
  note "bundle: $(grep '^bundle:' "$BUNDLE/MANIFEST") from $(grep '^host:' "$BUNDLE/MANIFEST" | cut -d' ' -f2), $(grep '^date:' "$BUNDLE/MANIFEST" | cut -d' ' -f2)"
  ip link show "$NIC_LAN" >/dev/null 2>&1 || { echo "network interface $NIC_LAN not found (set NIC_LAN=...)" >&2; exit 1; }
  ip link show "$NIC_EXT" >/dev/null 2>&1 || { echo "network interface $NIC_EXT not found (set NIC_EXT=...)" >&2; exit 1; }
  [ -d "$IMAGES" ] && note "glance images: $(ls "$IMAGES" | wc -l) files in $IMAGES" || note "WARNING: no image directory $IMAGES (Glance will have records without files)"
  grep -q -E '^[^#]\S*[[:space:]]+/share[[:space:]]' "$BUNDLE/ref/fstab.txt" 2>/dev/null && { mountpoint -q /share && note "/share is mounted" || note "WARNING: /share is not mounted: create the partition and mount it first (docs/c3-rebuild.md, 'Disk layout')"; }
  grep -q vmx /proc/cpuinfo && note "CPU has VT-x" || note "WARNING: no VT-x (enable virtualization in the BIOS)"
  note "free disk on /: $(df -h / | awk 'NR==2{print $4}')   (the old host kept VM disks in /var/lib/nova, 70 GB in use)"
  if [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then read -r -p "This will install packages and overwrite OpenStack configuration on THIS host. Type 'rebuild' to continue: " a; [ "$a" = rebuild ] || exit 1; fi
}

# ================================================================================================================================ phase 1
phase1() {
  say "1. base system: hostname, network files, packages"
  run "hostnamectl set-hostname $HOST_FQDN"
  run "apt-get update -y"
  # no questions from the OpenStack packages: do not let dbconfig-common create databases or register endpoints, everything comes from the bundle
  local pre=/tmp/dr-preseed.txt; : > $pre
  for p in keystone glance-common glance nova-common nova-api neutron-common placement-common placement-api octavia-common designate-common openstack-dashboard; do
    for q in configure_db register-endpoint create-admin-tenant configure_rabbit; do echo "$p $p/$q boolean false"; done
  done >> $pre
  echo "keystone keystone/configure_db boolean false" >> $pre
  run "debconf-set-selections $pre"
  run "apt-get install -y $PKG_BASE"
  run "apt-get install -y $PKG_INFRA"
  run "apt-get install -y $PKG_IDENTITY $PKG_COMPUTE $PKG_NETWORK $PKG_DNS $PKG_LB $PKG_UI $PKG_SHARE"
  # every OpenStack service was started by its package with a default configuration: stop them until the real configuration is in place
  run "systemctl stop apache2 glance-api nova-api nova-conductor nova-scheduler nova-compute nova-novncproxy nova-serialproxy neutron-api neutron-rpc-server neutron-dhcp-agent neutron-ovn-metadata-agent designate-api designate-central designate-mdns designate-producer designate-worker octavia-api octavia-health-manager octavia-housekeeping octavia-worker 2>/dev/null || true"
  note "base install done; the OpenStack services are stopped until phase 3 has put the configuration back"
}

# ================================================================================================================================ phase 2
phase2() {
  say "2. MariaDB, RabbitMQ, Memcached: configuration, users, keystone + glance data"
  extract_etc
  for p in mysql memcached.conf rabbitmq; do restore_etc_path "$p"; done
  run "systemctl restart mariadb rabbitmq-server memcached"
  run "mariadb -e 'select 1' >/dev/null"
  for d in $DBS_RESTORE $DBS_FRESH; do run "mariadb -e 'CREATE DATABASE IF NOT EXISTS \`$d\` CHARACTER SET utf8mb3'"; done
  # users with their password hashes and grants (the passwords inside the restored service configs keep working)
  if [ "$DRY" = 1 ]; then note "[dry-run] load users.sql (CREATE USER -> CREATE OR REPLACE USER) and the keystone/glance dumps"; else
    sed 's/^CREATE USER /CREATE OR REPLACE USER /' "$BUNDLE/db/users.sql" | grep -E '^(CREATE OR REPLACE USER|GRANT)' | mariadb
    for d in $DBS_RESTORE; do
      note "restoring database $d"; mariadb -e "DROP DATABASE IF EXISTS \`$d\`; CREATE DATABASE \`$d\` CHARACTER SET utf8mb3"
      zcat "$BUNDLE/db/$d.sql.gz" | mariadb "$d"
    done
  fi
  # RabbitMQ: the openstack user and its permissions
  run "rabbitmqctl import_definitions $BUNDLE/rabbitmq-definitions.json"
  run "rabbitmqctl list_users"
}

# ================================================================================================================================ phase 3
extract_etc() {
  [ -d "$STAGE/etc" ] && return 0
  run "mkdir -p $STAGE && tar -xzf $BUNDLE/etc.tgz -C $STAGE"
}
restore_etc_path() { # restore_etc_path <path under /etc>
  local p=$1
  [ "$DRY" = 1 ] && { note "[dry-run] restore /etc/$p"; return 0; }
  if [ -e "$STAGE/etc/$p" ]; then
    mkdir -p "$(dirname "/etc/$p")"
    rsync -a "$STAGE/etc/$p" "$(dirname "/etc/$p")/"
  else note "(not in the bundle: /etc/$p)"; fi
}
phase3() {
  say "3. restore the captured configuration (/etc), /usr/local, /root, small state"
  extract_etc
  for p in $ETC_RESTORE; do restore_etc_path "$p"; done
  [ "$DRY" = 1 ] || { [ -e "$STAGE/etc/ssh" ] && rsync -a --include='ssh_host_*' --exclude='*' "$STAGE/etc/ssh/" /etc/ssh/ ; }
  run "tar -xzf $BUNDLE/usr-local.tgz -C /"
  run "tar -xzf $BUNDLE/varlib.tgz -C /"
  run "tar -xzf $BUNDLE/root.tgz -C /"
  # file permissions the services insist on
  run "chown -R keystone:keystone /etc/keystone/fernet-keys /etc/keystone/credential-keys 2>/dev/null; chmod 700 /etc/keystone/fernet-keys /etc/keystone/credential-keys 2>/dev/null || true"
  run "chgrp -R octavia /etc/octavia 2>/dev/null; true"
  run "systemctl daemon-reload"
  say "3b. audit: what is in the captured /etc but was NOT restored (decide each; nothing is dropped silently)"
  if [ "$DRY" != 1 ]; then
    local t
    for t in $(ls -A "$STAGE/etc"); do
      case " $ETC_RESTORE " in *" $t "*|*" $t/"*) continue ;; esac
      echo "$t" | grep -q -E "$ETC_IGNORE_REGEX" && continue
      case " $ETC_RESTORE " in *" $t/"*) continue ;; esac
      note "unclassified: /etc/$t"
    done
    note "(the rest is operating-system or package default and comes from the fresh install; see ETC_IGNORE_REGEX in this script)"
  fi
  say "3c. fstab: network mounts from the old host"
  if [ -r "$BUNDLE/ref/fstab.txt" ]; then
    grep -E '[[:space:]]nfs4?[[:space:]]' "$BUNDLE/ref/fstab.txt" | while read -r l; do grep -qF "$l" /etc/fstab || { note "adding to /etc/fstab: $l"; run "echo '$l' >> /etc/fstab"; }; done
    grep -E '[[:space:]]/share[[:space:]]' "$BUNDLE/ref/fstab.txt" | sed 's/^/   old host had: /'
  fi
  run "update-grub >/dev/null 2>&1 || true"
}

# ================================================================================================================================ phase 4
phase4() {
  say "4. identity (Keystone), images (Glance), placement"
  run "systemctl enable --now apache2"
  run "keystone-manage db_sync"                      # no-op: the restored schema is current
  run "systemctl restart apache2"
  [ "$DRY" = 1 ] || wait_http http://$HOST_IP:5000/v3 60
  mkdir -p /var/lib/glance/images
  if [ -d "$IMAGES" ] && [ "$DRY" != 1 ]; then rsync -a "$IMAGES/" /var/lib/glance/images/; fi
  run "chown -R glance:glance /var/lib/glance/images"
  run "glance-manage db_sync"
  run "systemctl enable --now glance-api"
  run "placement-manage db sync"
  run "systemctl restart apache2"
  [ "$DRY" = 1 ] || { wait_http http://$HOST_IP:9292 60 '^(200|300)$'; load_os_env; openstack token issue -f value -c expires >/dev/null && note "keystone authentication works (admin password from the restored shell profile)"; }
}

# ================================================================================================================================ phase 5
phase5() {
  say "5. network (Open vSwitch, OVN, Neutron) and compute (libvirt, Nova)"
  # Open vSwitch / OVN: bridge for the provider network and the chassis settings captured from the old host
  run "systemctl enable --now openvswitch-switch"
  run "ip link set $NIC_EXT up"
  run "ovs-vsctl --may-exist add-br $OVS_EXT_BRIDGE -- --may-exist add-port $OVS_EXT_BRIDGE $NIC_EXT"
  if [ -r "$BUNDLE/ref/ovs-external-ids.txt" ]; then
    local pairs
    pairs=$(python3 - "$BUNDLE/ref/ovs-external-ids.txt" <<'PY'
import re, sys
t = open(sys.argv[1]).read().strip().strip('{}')
for m in re.finditer(r'([\w.-]+)=("[^"]*"|[^,]+)', t):
    k, v = m.group(1), m.group(2).strip().strip('"')
    if k in ('hostname', 'rundir', 'system-id'): continue      # these belong to the new machine
    print(f'{k}={v}')
PY
)
    while read -r kv; do [ -n "$kv" ] && run "ovs-vsctl set open_vswitch . external_ids:'$kv'"; done <<< "$pairs"
  else note "WARNING: ref/ovs-external-ids.txt missing: set ovn-remote, ovn-encap-ip, ovn-encap-type, ovn-bridge-mappings=physnet1:$OVS_EXT_BRIDGE by hand"; fi
  run "ovs-vsctl set-manager ptcp:6640:127.0.0.1"
  run "systemctl enable --now ovn-central ovn-host"
  run "systemctl restart ovn-ovsdb-server-nb ovn-ovsdb-server-sb 2>/dev/null || true"
  # Neutron
  run "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade heads"
  run "systemctl enable --now neutron-api neutron-rpc-server neutron-dhcp-agent neutron-ovn-metadata-agent"
  # libvirt and Nova (cells: api database, cell0, cell1)
  run "systemctl enable --now libvirtd virtlogd virtlockd libvirt-guests"
  run "nova-manage api_db sync"
  run "nova-manage cell_v2 map_cell0"
  run "nova-manage cell_v2 list_cells | grep -q ' cell1 ' || nova-manage cell_v2 create_cell --name=cell1 --verbose"
  run "nova-manage db sync"
  run "systemctl enable --now nova-api nova-api-metadata nova-conductor nova-scheduler nova-compute nova-novncproxy nova-serialproxy"
  [ "$DRY" = 1 ] || { wait_http http://$HOST_IP:8774 90 '^(200|300|401)$'; for i in $(seq 1 30); do openstack compute service list -f value -c Binary -c State 2>/dev/null | grep -q 'nova-compute up' && break; sleep 5; done; }
  run "nova-manage cell_v2 discover_hosts --verbose"
  # flavors (Terraform refers to them by name). m1.octavia has the fixed id 100 that octavia.conf (amp_flavor_id) names.
  [ "$DRY" = 1 ] || {
    for f in "m1.tiny 2048 10 1" "m1.small 4096 10 2" "m1.medium 8192 10 4" "m1.large 16384 10 8"; do set -- $f; openstack flavor show "$1" >/dev/null 2>&1 || openstack flavor create "$1" --ram "$2" --disk "$3" --vcpus "$4" --public; done
    openstack flavor show m1.octavia >/dev/null 2>&1 || openstack flavor create m1.octavia --id 100 --ram 2048 --disk 10 --vcpus 1 --private
  }
}

# ================================================================================================================================ phase 6
phase6() {
  say "6. DNS (BIND + Designate) and the dashboard"
  run "systemctl enable --now named"
  run "designate-manage database sync"
  run "systemctl enable --now designate-central designate-api designate-mdns designate-producer designate-worker"
  run "designate-manage pool update --file /etc/designate/pools.yaml"
  run "systemctl restart apache2"
  note "Octavia is configured and started by c3-dr-post.sh, AFTER 'terraform apply' in infra/ (it needs the external network and the security group ids)."
  run "octavia-db-manage upgrade head"
}

# ================================================================================================================================ phase 7
phase7() {
  say "7. local software, share, cron, resolver"
  # reconcilers and their timers (units and scripts came back with /etc/systemd/system and /usr/local)
  run "systemctl daemon-reload"
  run "systemctl enable --now ovn-vip-binding.timer k8s-api-lb.timer tfstate-pull.timer 2>/dev/null || true"
  # share: NFS export and Samba
  if [ -d "$SHARE" ] && mountpoint -q /share 2>/dev/null; then run "rsync -a $SHARE/ /share/"; else note "/share not restored (no copy at $SHARE or /share not mounted)"; fi
  run "exportfs -ra"
  run "systemctl enable --now nfs-server smbd nmbd"
  # root's crontab (hourly/daily/weekly/monthly pull of the website data; the scripts are on the NFS share /nfsshare)
  run "crontab $BUNDLE/cron/root.crontab"
  run "mount -a || true"
  # DNS for this host is its own BIND
  [ "$DRY" = 1 ] || { [ -e "$STAGE/etc/resolv.conf" ] && cp "$STAGE/etc/resolv.conf" /etc/resolv.conf; }
  note "network: /etc/network/interfaces (br0 with $NIC_LAN, the route 10.0.1.0/24 via 192.168.2.174) is in place; it takes effect at the next boot: reboot when everything else is done."
}

# ================================================================================================================================ phase 8
phase8() {
  say "8. verify"
  [ "$DRY" = 1 ] && { note "[dry-run] skipped"; return 0; }
  load_os_env
  local bad=0
  chk() { if eval "$2" >/dev/null 2>&1; then printf '   ok   %s\n' "$1"; else printf '   FAIL %s\n' "$1"; bad=1; fi; }
  chk "mariadb"                 "mariadb -e 'select 1'"
  chk "rabbitmq user openstack" "rabbitmqctl list_users | grep -q ^openstack"
  chk "keystone token"          "openstack token issue"
  chk "service catalog"         "openstack catalog list | grep -q nova"
  chk "glance images"           "openstack image list | grep -q ."
  chk "placement"               "openstack resource provider list"
  chk "nova compute up"         "openstack compute service list | grep -q 'nova-compute.*up'"
  chk "neutron agents"          "openstack network agent list | grep -q True"
  chk "OVN southbound chassis"  "ovn-sbctl show | grep -q Chassis"
  chk "designate pool"          "openstack dns service list || openstack zone list"
  chk "flavors"                 "openstack flavor list | grep -q m1.small"
  chk "horizon"                 "curl -s -o /dev/null -m 5 -w '%{http_code}' http://$HOST_IP/horizon/ | grep -q -E '200|302'"
  chk "libvirt"                 "virsh -c qemu:///system list"
  chk "named answers"           "dig +short @$HOST_IP c3.rdulinux.com >/dev/null"
  chk "nfs export /share"       "exportfs -v | grep -q /share"
  chk "samba"                   "testparm -s >/dev/null"
  [ "$bad" = 0 ] && say "platform is up. Next: terraform apply in infra/, then scripts/c3-dr/c3-dr-post.sh (docs/c3-rebuild.md, step 3)" || say "some checks failed: read the FAIL lines, fix, re-run the phase (they are re-runnable)"
}

for n in 0 1 2 3 4 5 6 7 8; do want "$n" && "phase$n"; done
say "finished phases${ONLY:+ (only $ONLY)} ${ONLY:-from $FROM}"
