#!/usr/bin/env bash
# c3-rebuild-all.sh - ONE script for the whole of c3: audit it, or build it from nothing, in the order the runbook (docs/c3-rebuild.md) uses.
# Run ON c3 (or the new host) as root, from a checkout of this repository.
#
#   c3-rebuild-all.sh --dry-run               DRY RUN: changes NOTHING. Every stage reads the live state, compares it with what this lab is
#                                             supposed to look like, and prints OK / DRIFT (would be changed) / WARN / SKIP / WOULD (the command it would run).
#                                             A mode (--dry-run or --apply) is REQUIRED: with no arguments the script only prints this usage and exits.
#   c3-rebuild-all.sh --apply [--bundle DIR]  really does it. Asks you to type 'rebuild' (--yes skips the question). Stops at the first failed step
#                                             (--keep-going continues). Safe to re-run: every step first checks whether it is already done.
#
#   --only a,b   --from STAGE   --skip a,b     choose stages (names below)       --list      print the stages and exit
#   --bundle DIR      a capture bundle (scripts/c3-dr/c3-dr-capture.sh) - needed by the `platform` stage on a blank host
#   --repo DIR        this repository (default: the one this script is in)    --tf-repo DIR   where the Terraform code and secrets are (default --repo)
#   --finance-repo DIR  the finance app repo (for the `apps` stage)           --nova-dev DEV  an already formatted partition to mount at /var/lib/nova
#   --reinstall       let `platform` run the installer even though OpenStack is already there (overwrites configuration!)
#   --offline-cpus    keep CPUs 8-9 offline at boot (c3-offline-cpus.service; docs/c3-hardware-instability.md)
#   --install-capture install the nightly c3 capture timer (not installed today)        --restore-router  restore the router config from the backup host (reboots the router)
#   --log-dir DIR     logs (default /var/log/c3-rebuild)
#
# Stages, in order:  preflight  layout  platform  tuning  tf-infra  octavia  api-lbs  tf-prod  tf-cka  app-lbs  apps  backup-host  router  backups  verify
#   preflight  the machine and what the run needs (hardware, network, tools, bundle)     layout   disks and mounts (/var/lib/nova, /share, /nfsshare), kernels, time
#   platform   OpenStack itself: services, databases, endpoints, images (c3-dr-install.sh on a blank host)    tuning   every setting we changed since the install
#   tf-*       terraform in infra/, environments/prod, environments/cka (dry run = `plan -lock=false`)       octavia / api-lbs / app-lbs   c3-dr-post.sh
#   apps       the finance app layer in Kubernetes (k8s/bootstrap.sh)      backup-host   the backup host (state, router and DR backups; formerly `s3`)     router   the OpenWrt router
#   backups    what keeps the lab recoverable (state pull, DR capture)      verify   a last look at everything
# Logging: every line goes to the screen AND to LOG_DIR/c3-rebuild-<mode>-<time>.log, with the time; LOG_DIR/....summary.tsv has one line per check;
# terraform plan output is kept (without values) next to it. Exit code: 0 = no failed step, 1 = at least one FAIL.
# NOT tested on a blank machine (nothing here has been run with --apply); the dry run is the tested part. Design and the audit: docs/c3-rebuild-all.md.
set -uo pipefail

# ------------------------------------------------------------------------------------------------------------------------------------ options
SELF=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "$0")
MODE=""; BUNDLE=""; ONLY=""; FROM=""; SKIP=""; YES=0; KEEP_GOING=0; REPO=""; TF_REPO=""; FINANCE_REPO=""; NOVA_DEV=""
REINSTALL=0; OFFLINE_CPUS=0; INSTALL_CAPTURE=0; RESTORE_ROUTER=0; LOG_DIR=/var/log/c3-rebuild
STAGES="preflight layout platform tuning tf-infra octavia api-lbs tf-prod tf-cka app-lbs apps backup-host router backups verify"
usage_short() {
  cat >&2 <<USAGE
usage: $(basename "$0") --dry-run | --apply  [options]

  --dry-run            audit only: reads the live state and changes nothing
  --apply              really rebuild (asks you to type 'rebuild'; --yes skips the question)
  --only a,b | --from STAGE | --skip a,b     choose stages        --list   print the stages
  --bundle DIR  --repo DIR  --tf-repo DIR  --finance-repo DIR  --nova-dev DEV  --log-dir DIR
  --reinstall  --offline-cpus  --install-capture  --restore-router  --keep-going  --yes
  -h, --help           the full description

Runs ON c3 (or the new host), as root. Nothing happens until you choose a mode.
USAGE
}
bad() { echo "error: $*" >&2; echo "(see --help)" >&2; exit 2; }
# the value of an option: present, and not another option
val() { [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ] || bad "$1 needs a value"; }
[ $# -gt 0 ] || { usage_short; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) [ "$MODE" = apply ] && bad "--dry-run and --apply are opposites; choose one"; MODE=dry ;;
    --apply)   [ "$MODE" = dry ]   && bad "--dry-run and --apply are opposites; choose one"; MODE=apply ;;
    --yes) YES=1 ;; --keep-going) KEEP_GOING=1 ;;
    --bundle) val "$@"; BUNDLE=$2; shift ;; --only) val "$@"; ONLY=$2; shift ;; --from) val "$@"; FROM=$2; shift ;; --skip) val "$@"; SKIP=$2; shift ;;
    --repo) val "$@"; REPO=$2; shift ;; --tf-repo) val "$@"; TF_REPO=$2; shift ;; --finance-repo) val "$@"; FINANCE_REPO=$2; shift ;; --nova-dev) val "$@"; NOVA_DEV=$2; shift ;;
    --reinstall) REINSTALL=1 ;; --offline-cpus) OFFLINE_CPUS=1 ;; --install-capture) INSTALL_CAPTURE=1 ;; --restore-router) RESTORE_ROUTER=1 ;;
    --log-dir) val "$@"; LOG_DIR=$2; shift ;; --list) echo $STAGES | tr ' ' '\n'; exit 0 ;;
    -h|--help) sed -n 2,30p "$SELF"; exit 0 ;;
    -*) bad "unknown option: $1" ;;
    *)  bad "unexpected argument: $1 (options start with --)" ;;
  esac
  shift
done

# ---- what was asked for must make sense, before anything is touched
[ -n "$MODE" ] || bad "choose a mode: --dry-run (audit, changes nothing) or --apply (rebuild)"
# `s3` was the name of the stage now called backup-host until 2026-11-15: still accepted
ONLY=$(printf '%s' "$ONLY" | sed -E 's/(^|,)s3(,|$)/\1backup-host\2/g'); SKIP=$(printf '%s' "$SKIP" | sed -E 's/(^|,)s3(,|$)/\1backup-host\2/g'); [ "$FROM" = s3 ] && FROM=backup-host
check_stages() {   # check_stages OPTION LIST
  local x; for x in $(printf '%s' "$2" | tr ',' ' '); do
    case " $STAGES " in *" $x "*) ;; *) bad "$1: '$x' is not a stage. Stages: $STAGES" ;; esac
  done
}
check_stages --only "$ONLY"; check_stages --skip "$SKIP"; [ -z "$FROM" ] || check_stages --from "$FROM"
[ -z "$ONLY" ] || { [ -z "$FROM" ] && [ -z "$SKIP" ]; } || bad "--only already says exactly which stages; do not combine it with --from or --skip"
[ "$MODE" = apply ] || { [ "$YES" = 0 ] && [ "$KEEP_GOING" = 0 ]; } || bad "--yes and --keep-going only make sense with --apply"
[ -z "$BUNDLE" ]       || [ -d "$BUNDLE" ]       || bad "--bundle: $BUNDLE is not a directory"
[ -z "$REPO" ]         || [ -d "$REPO/scripts" ] || bad "--repo: $REPO is not a checkout of this repository (no scripts/ in it)"
[ -z "$TF_REPO" ]      || [ -d "$TF_REPO" ]      || bad "--tf-repo: $TF_REPO is not a directory"
[ -z "$FINANCE_REPO" ] || [ -d "$FINANCE_REPO" ] || bad "--finance-repo: $FINANCE_REPO is not a directory"
[ -z "$NOVA_DEV" ]     || [ -b "$NOVA_DEV" ]     || bad "--nova-dev: $NOVA_DEV is not a block device"

# ---- and it has to be the right machine, as the right user (a dry run reads root-only state too)
[ "$(uname -s)" = Linux ] || bad "this runs ON c3 (or the new host), not on $(hostname) ($(uname -s)). From your Mac: ssh c3, then run it there"
[ "$(id -u)" = 0 ]        || bad "run it as root (uid is $(id -u), user $(id -un)) on c3 or the new host"
if [ -z "$REPO" ]; then REPO=$(cd "$(dirname "$SELF")/.." 2>/dev/null && pwd); fi
[ -n "$TF_REPO" ] || TF_REPO=$REPO
DR="$REPO/scripts/c3-dr"

# ------------------------------------------------------------------------------------------------------------------------------------ logging
mkdir -p "$LOG_DIR" 2>/dev/null || { echo "error: cannot create the log directory $LOG_DIR (is the disk writable? or pass --log-dir DIR)" >&2; exit 2; }
RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/c3-rebuild-$MODE-$RUN_ID.log"; SUMMARY="${LOG%.log}.summary.tsv"
: > "$SUMMARY"
exec > >(tee -a "$LOG") 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s [%s] %s\n' "$(ts)" "$1" "$2"; }
CUR=""; N_OK=0; N_DRIFT=0; N_WARN=0; N_SKIP=0; N_FAIL=0; N_WOULD=0; ISSUES=()
rec() { printf '%s\t%s\t%s\t%s\n' "$(ts)" "$CUR" "$1" "$2" >> "$SUMMARY"; }
info()  { log "INFO " "$*"; }
ok()    { N_OK=$((N_OK+1));       log " OK  " "$*"; rec OK "$*"; }
drift() { N_DRIFT=$((N_DRIFT+1)); ISSUES+=("DRIFT [$CUR] $*"); log "DRIFT" "$*"; rec DRIFT "$*"; }
warn()  { N_WARN=$((N_WARN+1));   ISSUES+=("WARN  [$CUR] $*"); log "WARN " "$*"; rec WARN "$*"; }
skip()  { N_SKIP=$((N_SKIP+1));   log "SKIP " "$*"; rec SKIP "$*"; }
fail()  { N_FAIL=$((N_FAIL+1));   ISSUES+=("FAIL  [$CUR] $*"); log "FAIL " "$*"; rec FAIL "$*"
          if [ "$MODE" = apply ] && [ "$KEEP_GOING" != 1 ]; then log "STOP " "apply stops at the first failed step (use --keep-going to continue)"; finish 1; fi; }
stage() { CUR=$1; printf '\n%s\n' "$(ts) ================================================================ stage: $1 - $2"; rec STAGE "$2"; }

# act "what" command args... : in a dry run only says what it WOULD do; with --apply runs it and logs the output
act() {
  local d=$1; shift
  if [ "$MODE" = dry ]; then N_WOULD=$((N_WOULD+1)); log "WOULD" "$d  ::  $*"; rec WOULD "$d :: $*"; return 0; fi
  log " DO  " "$d  ::  $*"
  "$@" 2>&1 | sed 's/^/        | /'
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then fail "$d (exit code $rc)"; return "$rc"; fi
  rec DONE "$d"; return 0
}

finish() {
  local rc=${1:-0}
  printf '\n%s\n' "$(ts) ================================================================ summary ($MODE)"
  log "INFO " "ok=$N_OK drift=$N_DRIFT warn=$N_WARN skip=$N_SKIP fail=$N_FAIL would-run=$N_WOULD"
  if [ ${#ISSUES[@]} -gt 0 ]; then log "INFO " "things to look at:"; local i; for i in "${ISSUES[@]}"; do printf '          %s\n' "$i"; done; fi
  [ "$N_FAIL" -gt 0 ] && rc=1
  log "INFO " "log: $LOG   per-check summary: $SUMMARY"
  [ "$MODE" = dry ] && log "INFO " "this was a DRY RUN: nothing was changed (apart from this log). To change things: --apply (see --help)."
  exec >&- 2>&-; wait 2>/dev/null; exit "$rc"
}

in_list() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }
want() {
  local s=$1
  if [ -n "$ONLY" ]; then in_list "$s" "$ONLY"; return; fi
  in_list "$s" "$SKIP" && return 1
  if [ -n "$FROM" ]; then local seen=0 x; for x in $STAGES; do [ "$x" = "$FROM" ] && seen=1; [ "$x" = "$s" ] && { [ $seen = 1 ]; return; }; done; return 1; fi
  return 0
}

# ------------------------------------------------------------------------------------------------------------------------------------ helpers
# every ssh/openstack/mysql call gets /dev/null as stdin: nothing here may eat this script's own input
rssh() { ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$@" </dev/null; }
os() { ( . /etc/keystonerc 2>/dev/null; openstack "$@" ) 2>/dev/null </dev/null; }
ini_get() {      # ini_get FILE SECTION KEY : the value, exit 1 if unset, 2 if the file cannot be read
  python3 - "$@" <<'PY' 2>/dev/null
import sys, configparser
f, sec, key = sys.argv[1:4]
c = configparser.RawConfigParser(strict=False, interpolation=None); c.optionxform = str
if not c.read(f): sys.exit(2)
if sec == "DEFAULT":
    v = c.defaults().get(key)
else:
    v = c.get(sec, key) if c.has_option(sec, key) and sec in c.sections() else None
if v is None: sys.exit(1)
sys.stdout.write(v.strip())
PY
}
NEEDS_RESTART=""
ini_expect() {   # ini_expect FILE SECTION KEY WANT [restart-tag]
  local f=$1 sec=$2 key=$3 want=$4 tag=${5:-} have rc
  have=$(ini_get "$f" "$sec" "$key"); rc=$?
  if [ $rc -eq 2 ]; then skip "$f is not readable here"; return 0; fi
  if [ "$have" = "$want" ]; then ok "$(basename "$f") [$sec] $key = $want"; return 0; fi
  drift "$(basename "$f") [$sec] $key is '${have:-<unset>}', expected '$want'"
  if ! command -v crudini >/dev/null 2>&1 && [ "$MODE" = apply ]; then act "install crudini" apt-get install -y crudini; fi
  act "set $key = $want in $(basename "$f")" crudini --set "$f" "$sec" "$key" "$want" && NEEDS_RESTART="$NEEDS_RESTART $tag"
}
unit_expect() {  # unit_expect UNIT [enabled|-] [active|-]  (a "-" means: do not care)
  local u=$1 en=${2:--} ac=${3:--} e a
  e=$(systemctl is-enabled "$u" 2>/dev/null | head -1); a=$(systemctl is-active "$u" 2>/dev/null | head -1)
  [ -n "$e" ] || e=missing; [ -n "$a" ] || a=missing
  if [ "$e" = missing ] && [ "$a" = missing ]; then drift "unit $u does not exist"; return 1; fi
  local bad=""
  [ "$en" != "-" ] && [ "$e" != "$en" ] && [ "$e" != alias ] && bad="enabled=$e (want $en) "
  [ "$ac" != "-" ] && [ "$a" != "$ac" ] && bad="${bad}active=$a (want $ac)"
  if [ -z "$bad" ]; then ok "unit $u: $e/$a"; return 0; fi
  drift "unit $u: $bad"
  [ "$en" = enabled ] && [ "$e" != enabled ] && act "enable $u" systemctl enable "$u"
  [ "$ac" = active ] && [ "$a" != active ] && act "start $u" systemctl start "$u"
  return 1
}
file_expect() { if [ -e "$1" ]; then ok "$2 ($1)"; else drift "$2 missing: $1"; return 1; fi; }
is_git() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }   # a checkout counts even when the repository root is a parent folder (/nfsshare/c3 holds ubuntu/openstack)
osx() { ( . /etc/keystonerc; openstack "$@" ); }     # openstack with the admin credentials, visible output: for act
os_has() { os "$@" 2>/dev/null | grep -q .; }   # os_has openstack-args : something was returned
flavor_spec() { os flavor show "$1" -f json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["vcpus"], d["ram"], d["disk"])' 2>/dev/null; }

# ------------------------------------------------------------------------------------------------------------------------------------ stages
stage_preflight() {
  stage preflight "the machine and what this run needs"
  if [ "$(id -u)" = 0 ]; then ok "running as root"; else fail "run as root"; fi
  # shellcheck disable=SC1091
  . /etc/os-release; if [ "${VERSION_ID:-}" = 13 ]; then ok "OS: ${PRETTY_NAME}"; else warn "OS is ${PRETTY_NAME:-?}; this lab is built on Debian 13 (trixie)"; fi
  info "kernel $(uname -r), up $(uptime -p)"
  local cpu thr off; cpu=$(lscpu | sed -n 's/^Model name: *//p'); thr=$(cat /sys/devices/system/cpu/online); off=$(cat /sys/devices/system/cpu/offline)
  info "CPU: $cpu; threads online $thr, offline [${off}]"
  case "$cpu" in *"i9-13"*|*"i9-14"*) info "13th/14th gen Intel: if oopses/segfaults appear on one core see docs/c3-hardware-instability.md (RMA, c3-offline-cpus.service)";; esac
  local ram; ram=$(free -m | awk 'NR==2{print $2}')
  if [ "$ram" -ge 60000 ]; then ok "RAM $ram MB"; else warn "RAM only $ram MB (the lab was sized for about 80 GB)"; fi
  if grep -q vmx /proc/cpuinfo; then ok "CPU virtualization (VT-x) is on"; else fail "no VT-x: enable virtualization in the BIOS"; fi
  local nic; for nic in "${NIC_LAN:-enp3s0}" "${NIC_EXT:-enp4s0}"; do if ip link show "$nic" >/dev/null 2>&1; then ok "network interface $nic exists"; else warn "network interface $nic not found (set NIC_LAN / NIC_EXT)"; fi; done
  local bios mc; bios=$(dmidecode -s bios-version 2>/dev/null); mc=$(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')
  if [ "$bios" = "A.C0" ]; then ok "BIOS $bios (MSI 7E25vAC), microcode $mc"; else warn "BIOS is '${bios:-?}'; the lab runs MSI 7E25vAC (A.C0). In the BIOS: Intel default settings, Wi-Fi off, no XMP/EXPO, VT-x and VT-d on"; fi
  local h n; for h in "repo 192.168.2.3" "backup 192.168.2.4" "router 192.168.2.1"; do set -- $h
    if ping -c1 -W2 "$2" >/dev/null 2>&1; then ok "$1 ($2) answers"; else warn "$1 ($2) does not answer ping"; fi; done
  if getent hosts github.com >/dev/null 2>&1; then ok "DNS works (github.com resolves)"; else warn "cannot resolve github.com"; fi
  for n in python3 jq rsync curl ssh git; do command -v $n >/dev/null 2>&1 && ok "tool $n" || warn "tool $n is missing"; done
  command -v crudini >/dev/null 2>&1 && ok "tool crudini" || info "crudini is missing (the platform stage installs it; --apply installs it before editing config files)"
  command -v terraform >/dev/null 2>&1 && ok "terraform $(terraform version 2>/dev/null | head -1)" || warn "terraform is not installed (the tf-* stages need it)"
  [ -r /etc/keystonerc ] && ok "/etc/keystonerc present (admin credentials)" || info "/etc/keystonerc not there yet (comes with the bundle, platform stage)"
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] && ok "AWS_ACCESS_KEY_ID is set (the Terraform state on s3)" || warn "AWS_ACCESS_KEY_ID is not set: the tf-* stages cannot reach the state store on s3"
  if [ -n "$BUNDLE" ]; then
    if [ -r "$BUNDLE/MANIFEST" ] && (cd "$BUNDLE" && sha256sum -c --quiet SHA256SUMS 2>/dev/null); then ok "bundle $BUNDLE: checksums OK, $(grep -m1 '^date:' "$BUNDLE/MANIFEST" | cut -d' ' -f2)"; else fail "bundle $BUNDLE is missing, unreadable or its checksums do not match"; fi
  elif [ "$MODE" = apply ]; then
    os_has server list >/dev/null 2>&1 || warn "no --bundle given: only fine if OpenStack is already installed here"
  fi
  [ -d "$REPO/scripts" ] && ok "repository: $REPO" || fail "repository not found at $REPO (--repo)"
  if is_git "$REPO"; then
    local behind; git -C "$REPO" fetch -q origin 2>/dev/null; behind=$(git -C "$REPO" rev-list --count HEAD..@{u} 2>/dev/null || echo "?")
    if [ "$behind" = 0 ]; then ok "repository is a git checkout and current ($(git -C "$REPO" log --oneline -1 2>/dev/null | cut -c1-70))"
    else warn "repository is $behind commit(s) behind its remote: git pull --ff-only (a stale copy makes Terraform plans misleading)"; fi
    [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null | grep -v '^??')" ] && warn "the repository has uncommitted changes: $(git -C "$REPO" status --porcelain | grep -v '^??' | wc -l) file(s)"
  else warn "$REPO is not a git checkout: cannot tell how current it is"; fi
  if [ "$MODE" = apply ] && [ "$YES" != 1 ]; then
    read -r -p "$(ts) This will change THIS host. Type 'rebuild' to continue: " a || a=""
    [ "$a" = rebuild ] || { log "STOP " "cancelled"; finish 1; }
  fi
}

stage_layout() {
  stage layout "disks, mounts, kernels, time"
  local root_src nova_src; root_src=$(findmnt -no SOURCE /); nova_src=$(findmnt -no SOURCE /var/lib/nova 2>/dev/null)
  if mountpoint -q /var/lib/nova && [ "$nova_src" != "$root_src" ]; then
    ok "/var/lib/nova is its own filesystem: $nova_src ($(df -h /var/lib/nova | awk 'NR==2{print $2" total, "$4" free"}')); the VM disks do not share the root partition"
  else
    drift "/var/lib/nova is on the root filesystem (docs/c3-disk-expansion.md: a partition of its own gives Placement room for the VM disks)"
    if [ -n "$NOVA_DEV" ] && [ -b "$NOVA_DEV" ] && blkid "$NOVA_DEV" >/dev/null 2>&1; then
      local u; u=$(blkid -s UUID -o value "$NOVA_DEV")
      act "add $NOVA_DEV to /etc/fstab" bash -c "grep -q '$u' /etc/fstab || echo 'UUID=$u /var/lib/nova ext4 defaults 0 2' >> /etc/fstab"
      act "mount /var/lib/nova" bash -c "mkdir -p /var/lib/nova && mount /var/lib/nova"
    else
      info "to fix: make a partition from the free space (parted mkpart), mkfs.ext4 it, then rerun with --nova-dev /dev/nvme0n1pN (never done automatically)"
    fi
  fi
  if mountpoint -q /share; then ok "/share is mounted ($(findmnt -no SOURCE /share))"; else drift "/share is not mounted (the 25 GB partition with the finance app tree; create it by hand, docs/c3-rebuild.md step 0)"; fi
  if grep -qE '^[^#]*[[:space:]]/nfsshare[[:space:]]+nfs' /etc/fstab; then ok "/nfsshare is in fstab ($(grep -E '[[:space:]]/nfsshare[[:space:]]' /etc/fstab | awk '{print $1}'))"; else drift "/nfsshare (NFS from the repo host) is not in /etc/fstab"; fi
  mountpoint -q /nfsshare && ok "/nfsshare is mounted" || drift "/nfsshare is not mounted"
  local kn; kn=$(dpkg -l 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/ {print $2}' | sed 's/linux-image-//' | tr '\n' ' ')
  local kc; kc=$(echo $kn | wc -w)
  if [ "$kc" -eq 2 ]; then ok "kernels: N and N-1 kept (${kn% }), running $(uname -r)"; elif [ "$kc" -gt 2 ]; then warn "more than two kernels installed ($kn): keep the newest and the previous only"; else warn "only $kc kernel installed ($kn): the policy keeps N and N-1 for rollback"; fi
  if [ "$OFFLINE_CPUS" = 1 ]; then
    [ -e /etc/systemd/system/c3-offline-cpus.service ] || act "install c3-offline-cpus.service" install -m 644 "$REPO/scripts/c3-offline-cpus.service" /etc/systemd/system/c3-offline-cpus.service
    act "daemon-reload" systemctl daemon-reload; unit_expect c3-offline-cpus.service enabled active
  else
    local e; e=$(systemctl is-enabled c3-offline-cpus.service 2>/dev/null | head -1)
    info "c3-offline-cpus.service: ${e:-not installed} (cores online: $(cat /sys/devices/system/cpu/online)); it keeps CPUs 8-9 offline if the CPU misbehaves, use --offline-cpus"
  fi
  if lspci 2>/dev/null | grep -qi -E "wi-?fi|wireless"; then warn "a Wi-Fi card is present (ath12k logs 'failed to enqueue rx buf'): disable it in the BIOS or blacklist ath12k; c3 does not use it"; else ok "no Wi-Fi card visible (disabled in the BIOS)"; fi
  local ntp tz; ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null); tz=$(timedatectl show -p Timezone --value 2>/dev/null)
  [ "$ntp" = yes ] && ok "clock is NTP synchronised (systemd-timesyncd)" || warn "clock is not NTP synchronised"
  if [ "$tz" = Asia/Kolkata ]; then ok "timezone Asia/Kolkata"; else drift "timezone is ${tz:-?}, expected Asia/Kolkata"; act "set timezone" timedatectl set-timezone Asia/Kolkata; fi
  file_expect /etc/sysctl.d/99-disable-ipv6.conf "IPv6 is switched off by sysctl"
  ip -br addr show br0 2>/dev/null | grep -q '192.168.2.2/24' && ok "br0 has 192.168.2.2/24" || drift "br0 does not have 192.168.2.2/24 (the LAN bridge)"
  dpkg -l task-gnome-desktop 2>/dev/null | grep -q '^ii' && info "a GNOME desktop is installed on c3 (task-gnome-desktop, gdm3): not needed by OpenStack; a rebuilt c3 is a minimal Debian (the installer does not add it)"
}

OS_SERVICES="mariadb rabbitmq-server memcached apache2 glance-api nova-api nova-api-metadata nova-conductor nova-scheduler nova-compute nova-novncproxy nova-serialproxy neutron-api neutron-rpc-server neutron-dhcp-agent neutron-ovn-metadata-agent openvswitch-switch ovn-central ovn-host libvirtd libvirt-guests designate-api designate-central designate-mdns designate-producer designate-worker named octavia-api octavia-health-manager octavia-housekeeping octavia-worker nfs-kernel-server smbd nmbd ssh"
platform_present() { systemctl is-active --quiet nova-api 2>/dev/null && mysql -N -e "show databases like 'keystone'" 2>/dev/null </dev/null | grep -q keystone; }

stage_platform() {
  stage platform "OpenStack itself (Keystone, Glance, Placement, Nova, Neutron/OVN, Designate, Octavia, Horizon)"
  if platform_present; then
    ok "OpenStack is installed here (nova-api active, keystone database exists)"
    local s bad=0; for s in $OS_SERVICES; do systemctl is-active --quiet "$s" 2>/dev/null || { drift "service $s is not active"; bad=1; act "start $s" systemctl start "$s"; }; done
    [ $bad = 0 ] && ok "all $(echo $OS_SERVICES | wc -w) platform services are active"
    local d; for d in designate glance keystone neutron_ml2 nova nova_api nova_cell0 octavia placement; do mysql -N -e "show databases like '$d'" 2>/dev/null </dev/null | grep -q "^$d$" && true || drift "database $d is missing"; done
    ok "databases present: $(mysql -N -e 'show databases' 2>/dev/null </dev/null | grep -E '^(designate|glance|keystone|neutron_ml2|nova|nova_api|nova_cell0|octavia|placement)$' | tr '\n' ' ')"
    local ep; ep=$(os endpoint list -f value -c "Service Name" | sort -u | tr '\n' ' ')
    for s in designate glance keystone neutron nova octavia placement; do case " $ep " in *" $s "*) ;; *) drift "no $s endpoint in the catalog";; esac; done; ok "catalog: $ep"
    local cs; cs=$(os compute service list -f value -c Binary -c State | tr '\n' ';'); info "compute services: $cs"
    local dead; dead=$(os network agent list -f json | python3 -c '
import json,sys
print("; ".join("%s on host %s" % (a["Binary"], a["Host"]) for a in json.load(sys.stdin) if not a.get("Alive")))' 2>/dev/null)
    if [ -z "$dead" ]; then ok "all network agents are alive"
    else warn "stale network agent record(s), not alive: $dead (left over from the hostname change c3 -> c3.rdulinux.com; harmless; remove with: openstack network agent delete <id>)"; fi
    local im; for im in ubuntu2404 debian13 Amphora-netns-fix-v2-20261020; do os image show "$im" -c status -f value | grep -q active && ok "image $im is active" || drift "image $im is missing (Glance records and files come from the bundle)"; done
    local tagged; tagged=$(os image list --tag Amphora -f value -c Name | wc -l); [ "$tagged" = 1 ] && ok "exactly one image carries the tag Amphora" || drift "$tagged images carry the tag Amphora (must be exactly one, docs/amphora-reboot-fix.md)"
    if [ "$REINSTALL" = 1 ]; then act "re-run the platform installer over this host (overwrites configuration)" "$DR/c3-dr-install.sh" --bundle "$BUNDLE" --yes
    else info "c3-dr-install.sh is NOT run: the platform is already here (pass --reinstall to overwrite it)"; fi
  else
    drift "OpenStack is not installed on this host"
    if [ -z "$BUNDLE" ]; then fail "a capture bundle is needed to install it (--bundle DIR; capture: scripts/c3-dr/c3-dr-capture.sh, copy from backup:/backup/c3-dr/bundles/latest)"; return; fi
    if [ "$MODE" = dry ]; then act "installer plan (its own dry run)" "$DR/c3-dr-install.sh" --bundle "$BUNDLE" --dry-run
    else act "install the platform from the bundle (phases 0 to 8)" "$DR/c3-dr-install.sh" --bundle "$BUNDLE" --yes; info "the installer asks for a reboot at the end (network files, OVS bridge): reboot, then continue with --from tuning"; fi
  fi
}

stage_tuning() {
  stage tuning "every setting we changed since the first install (nova, octavia, libvirt, OVN, timers, flavors)"
  NEEDS_RESTART=""
  ini_expect /etc/nova/nova.conf DEFAULT ram_allocation_ratio 1.2 nova
  ini_expect /etc/nova/nova.conf DEFAULT disk_allocation_ratio 2.5 nova
  ini_expect /etc/nova/nova.conf DEFAULT allow_resize_to_same_host true nova
  ini_expect /etc/nova/nova.conf DEFAULT resume_guests_state_on_host_boot true nova
  ini_expect /etc/nova/nova.conf DEFAULT state_path /var/lib/nova nova
  ini_expect /etc/octavia/octavia.conf health_manager heartbeat_timeout 300 octavia
  ini_expect /etc/octavia/octavia.conf health_manager failover_threshold 2 octavia
  ini_expect /etc/octavia/octavia.conf controller_worker amp_flavor_id 100 octavia
  ini_expect /etc/octavia/octavia.conf controller_worker amp_image_tag Amphora octavia
  local k v; for kv in ON_SHUTDOWN=shutdown SHUTDOWN_TIMEOUT=300 PARALLEL_SHUTDOWN=20 ON_BOOT=ignore; do k=${kv%%=*}; v=${kv#*=}
    if grep -qE "^$k=$v\$" /etc/default/libvirt-guests 2>/dev/null; then ok "libvirt-guests $k=$v"; else drift "libvirt-guests $k is not $v"; act "set $k=$v" sed -i -E "s/^#?$k=.*/$k=$v/" /etc/default/libvirt-guests; fi; done
  if grep -q 'After=libvirt-guests.service' /etc/systemd/system/nova-compute.service.d/10-order-after-libvirt-guests.conf 2>/dev/null; then ok "drop-in: nova-compute starts after libvirt-guests"; else drift "drop-in nova-compute.service.d/10-order-after-libvirt-guests.conf is missing (comes with the bundle)"; fi
  if grep -q 'ovn-controller' /etc/systemd/system/libvirt-guests.service.d/20-order-after-ovn.conf 2>/dev/null; then ok "drop-in: libvirt-guests starts after OVN (a clean reboot needs it, docs/c3-reboot.md)"; else drift "drop-in libvirt-guests.service.d/20-order-after-ovn.conf is missing (comes with the bundle)"; fi
  local ex; for ex in "bridge-mappings:physnet1:br-enp4s0" "ovn-encap-ip:192.168.2.2" "ovn-encap-type:geneve" "ovn-remote:tcp:192.168.2.2:6642"; do
    k=${ex%%:*}; v=${ex#*:}; have=$(ovs-vsctl get Open_vSwitch . external_ids:${k/bridge-mappings/ovn-bridge-mappings} 2>/dev/null | tr -d '"')
    [ "$have" = "$v" ] && ok "OVS external_ids $k = $v" || drift "OVS external_ids $k is '${have:-<unset>}', expected '$v'"; done
  grep -qE '^/share +192\.168\.2\.0/24' /etc/exports 2>/dev/null && ok "NFS exports /share to 192.168.2.0/24" || drift "/etc/exports does not export /share to 192.168.2.0/24"
  grep -q '^\[share\]' /etc/samba/smb.conf 2>/dev/null && ok "Samba share [share]" || drift "Samba has no [share]"
  local t; for t in ovn-vip-binding.timer k8s-api-lb.timer tfstate-pull.timer; do unit_expect $t enabled active; done
  for t in ovn-vip-binding-reconciler k8s-api-lb-reconciler; do file_expect /usr/local/sbin/$t "reconciler script $t"; done
  # OpenStack objects: flavors (the m1.octavia flavor, id 100, is private: it is only in `flavor list --all`)
  if os_has flavor list; then
    local f spec have id
    for f in "m1.tiny 1 2048 10" "m1.small 2 4096 10" "m1.medium 4 8192 10" "m1.large 8 16384 10" "m1.octavia 1 2048 10" "k8s.worker 2 4096 20" "m1.small-20g 2 4096 20" "m1.medium-20g 4 8192 20"; do
      set -- $f; have=$(flavor_spec "$1")
      if [ -z "$have" ]; then drift "flavor $1 does not exist"; act "create flavor $1" osx flavor create --vcpus "$2" --ram "$3" --disk "$4" $([ "$1" = m1.octavia ] && echo "--id 100 --private" || echo --public) "$1"
      elif [ "$have" = "$2 $3 $4" ]; then ok "flavor $1 ($2 vCPU, $3 MB, $4 GB)"; else drift "flavor $1 is '$have', expected '$2 $3 $4'"; fi
    done
    os loadbalancer flavorprofile list -f value -c name | grep -q '^active-standby$' && ok "Octavia flavor profile active-standby" || drift "Octavia flavor profile active-standby is missing (c3-dr-post.sh octavia creates it)"
    os loadbalancer flavor list -f value -c name | grep -q '^ha$' && ok "Octavia flavor ha (ACTIVE_STANDBY)" || drift "Octavia flavor ha is missing (c3-dr-post.sh octavia creates it)"
  else skip "OpenStack API not answering: flavors not checked"; fi
  if [ "$MODE" = apply ] && [ -n "${NEEDS_RESTART// /}" ]; then
    case "$NEEDS_RESTART" in *nova*) act "restart nova" systemctl restart nova-api nova-conductor nova-scheduler nova-compute ;; esac
    case "$NEEDS_RESTART" in *octavia*) act "restart octavia (worker AND health manager, docs/octavia-finance-lb.md)" systemctl restart octavia-worker octavia-health-manager ;; esac
  fi
}

# --- terraform
tf_stage() {   # tf_stage NAME DIR
  local name=$1 dir=$2 d="$TF_REPO/$2"
  stage "$name" "terraform in $dir (dry run = plan without a lock, nothing is written)"
  [ -d "$d" ] || { skip "no $d (--tf-repo)"; return; }
  command -v terraform >/dev/null 2>&1 || { skip "terraform is not installed"; return; }
  grep -Eq '^[^#]*[[:space:]]s3\.rdulinux\.com' /etc/hosts 2>/dev/null && warn "/etc/hosts overrides s3.rdulinux.com: Terraform here uses a TEMPORARY state store (scripts/s3-temp-store.sh status)"
  is_git "$TF_REPO" || info "no git metadata in $TF_REPO: newest file in $dir is from $(ls -t "$d"/*.tf "$d"/nodes.yaml 2>/dev/null | head -1 | xargs -r stat -c %y | cut -c1-10); a plan from an old copy can show changes that are not real (run Terraform from the Mac, or sync the repo first)"
  if [ "$dir" = environments/prod ] && [ ! -e "$d/secrets.auto.tfvars" ]; then
    skip "$dir needs $d/secrets.auto.tfvars (git-ignored; scripts/db-ha-secrets.sh makes it from the live Patroni config): not planning (terraform would ask for the database password)"; return; fi
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] || { skip "AWS_ACCESS_KEY_ID is not set: cannot read the state on s3"; return; }
  if [ ! -d "$d/.terraform" ]; then drift "$dir is not initialised"; act "terraform init" terraform -chdir="$d" init -input=false; [ "$MODE" = dry ] && { info "plan skipped in a dry run until the directory is initialised"; return; }; fi
  if [ "$MODE" = dry ]; then
    local out rc planlog="$LOG_DIR/plan-$name-$RUN_ID.txt"
    out=$(timeout 600 terraform -chdir="$d" plan -input=false -lock=false -detailed-exitcode -no-color 2>&1 </dev/null); rc=$?
    # keep only the resource lines and the summary: the full text can contain values
    printf '%s\n' "$out" | grep -E '^\s*# .*(will be|must be)|^Plan:|^No changes|Error|power_state' > "$planlog"
    case $rc in
      0) ok "$dir: no changes, the live infrastructure matches the code" ;;
      2) drift "$dir: the plan shows changes: $(grep -m1 '^Plan:' "$planlog") (resource lines in $planlog)"
         grep -E '^\s*# .*(will be|must be)' "$planlog" | head -12 | sed 's/^/          /'
         if grep -q 'power_state' "$planlog"; then info "$dir: the changes include power_state: VMs that are SHUTOFF (a maintenance stop); an apply would start them"; fi ;;
      *) fail "$dir: terraform plan failed: $(grep -m2 -E 'Error' "$planlog" | tr '\n' ' ' | cut -c1-200)" ;;
    esac
  else
    act "terraform apply in $dir" terraform -chdir="$d" apply -input=false -auto-approve || act "terraform apply again (a first apply of a VM can stop on 'IP already allocated', docs/c3-rebuild.md)" terraform -chdir="$d" apply -input=false -auto-approve
  fi
}
stage_tf_infra() { tf_stage tf-infra infra; }
stage_tf_prod()  { tf_stage tf-prod environments/prod; }
stage_tf_cka()   { tf_stage tf-cka environments/cka; }

# --- load balancers
lb_status() { os loadbalancer show "$1" -f json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s/%s" % (d["provisioning_status"], d["operating_status"]))' 2>/dev/null; }   # PROVISIONING/OPERATING
fip_attached() { os floating ip list -f json | python3 -c '
import json,sys
want=sys.argv[1]
sys.exit(0 if any(x.get("Floating IP Address")==want and x.get("Port") for x in json.load(sys.stdin)) else 1)' "$1" 2>/dev/null; }
lb_expect() {   # lb_expect NAME FLOATING_IP
  local n=$1 fip=$2 st
  st=$(lb_status "$n")
  if [ -z "$st" ]; then drift "load balancer $n does not exist"; return 1; fi
  case "$st" in
    ACTIVE/ONLINE) ok "load balancer $n $st" ;;
    ACTIVE/*)      warn "load balancer $n is $st: its backend VMs are down (normal while that environment is shut down)" ;;
    *)             drift "load balancer $n is $st (provisioning/operating)" ;;
  esac
  fip_attached "$fip" && ok "floating IP $fip is attached ($n)" || drift "floating IP $fip is not attached to a port"
}
stage_octavia() {
  stage octavia "Octavia: security group, ids in octavia.conf, load balancer flavor"
  os_has security group show lb-mgmt-sec-group && ok "security group lb-mgmt-sec-group exists" || drift "security group lb-mgmt-sec-group is missing"
  local sg net; sg=$(os security group show lb-mgmt-sec-group -f value -c id); net=$(os network show external_network -f value -c id)
  [ -n "$sg" ] && ini_expect /etc/octavia/octavia.conf controller_worker amp_secgroup_list "$sg" octavia
  [ -n "$net" ] && ini_expect /etc/octavia/octavia.conf controller_worker amp_boot_network_list "$net" octavia
  os loadbalancer flavorprofile list -f value -c name | grep -q '^active-standby$' && os loadbalancer flavor list -f value -c name | grep -q '^ha$' && ok "Octavia flavor ha / profile active-standby present" || { drift "Octavia flavor/profile for ACTIVE_STANDBY is missing"; act "c3-dr-post.sh octavia" "$DR/c3-dr-post.sh" octavia; }
}
stage_api_lbs() { stage api-lbs "Kubernetes API load balancers (prod-api .61, cka-api .75)"; lb_expect prod-api 192.168.2.61 || act "c3-dr-post.sh api-lbs" "$DR/c3-dr-post.sh" api-lbs; lb_expect cka-api 192.168.2.75; }
stage_app_lbs() { stage app-lbs "application load balancers (finance-lb .5, argo-lb .113)"; lb_expect finance-lb 192.168.2.5 || act "c3-dr-post.sh app-lbs" "$DR/c3-dr-post.sh" app-lbs; lb_expect argo-lb 192.168.2.113; }

stage_apps() {
  stage apps "the finance app layer in Kubernetes"
  if [ -n "$FINANCE_REPO" ] && [ -x "$FINANCE_REPO/k8s/bootstrap.sh" ] && [ -r "$HOME/.kube/prod" ]; then
    if [ "$MODE" = dry ]; then act "bootstrap --check (read-only)" env KUBECONFIG="$HOME/.kube/prod" KCTX=prod "$FINANCE_REPO/k8s/bootstrap.sh" --check
    else act "k8s/bootstrap.sh (needs DB_PASSWORD, GHCR_TOKEN, GH_TOKEN in the environment)" env KUBECONFIG="$HOME/.kube/prod" KCTX=prod "$FINANCE_REPO/k8s/bootstrap.sh"; fi
  else skip "no finance repo / ~/.kube/prod here (--finance-repo DIR); run k8s/bootstrap.sh from the machine that has them"; fi
  info "by hand, after a REBUILD: restore the finance database from the NFS dump (docs/finance-db-restore.md), register the GitHub runner (new token), copy the new kubeconfigs to your Mac"
}

stage_backup_host() {
  stage backup-host "the backup host: state and router backups, the pull of the s3 store (formerly the s3 host)"
  if ! rssh root@192.168.2.4 true 2>/dev/null; then warn "cannot ssh to root@192.168.2.4 (backup)"; return; fi
  ok "ssh to backup works"
  # RustFS (the Terraform state store) runs on the s3 VM since 2026-11-15; this host keeps the backups and the timers (docs/s3-state-store.md)
  rssh root@s3.rdulinux.com 'docker ps --format "{{.Names}} {{.Status}}" | grep -q "^rustfs "' && ok "RustFS container is running on s3" || drift "RustFS container is not running on s3 (scripts/s3-vm-restore.sh)"
  [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://s3.rdulinux.com:9000/health)" = 200 ] && ok "RustFS health 200" || drift "RustFS health is not 200"
  local t; for t in tfstate-backup.timer rustfs-vm-pull.timer openwrt-backup.timer; do
    if rssh root@192.168.2.4 "systemctl is-active $t" | grep -q '^active$'; then ok "backup timer $t is active"
    else drift "backup timer $t is not active"; act "install on backup" "$REPO/scripts/install-$(case $t in tfstate-backup.timer) echo s3-tfstate-backup;; rustfs-vm-pull.timer) echo rustfs-vm-pull;; *) echo s3-openwrt-backup;; esac).sh"; fi; done
  local age; age=$(rssh root@192.168.2.4 'echo $(( ($(date +%s) - $(stat -c %Y /backup/terraform-state/last-ok)) / 60 ))' 2>/dev/null)
  [ -n "$age" ] && { [ "$age" -lt 150 ] && ok "state snapshot job ran $age min ago" || drift "state snapshot job last ran $age min ago (should be under 2 hours)"; }
  age=$(rssh root@192.168.2.4 'echo $(( ($(date +%s) - $(stat -c %Y /backup/openwrt/last-ok)) / 3600 ))' 2>/dev/null)
  [ -n "$age" ] && { [ "$age" -lt 50 ] && ok "router backup job ran $age h ago" || drift "router backup job last ran $age h ago (should be under 2 days)"; }
  age=$(rssh root@192.168.2.4 'echo $(( ($(date +%s) - $(stat -c %Y /backup/rustfs-vm/last-ok)) / 60 ))' 2>/dev/null)
  [ -n "$age" ] && { [ "$age" -lt 150 ] && ok "whole-store pull of s3 ran $age min ago" || drift "whole-store pull of s3 last ran $age min ago (should be under 2 hours)"; }
  # The recovery kit for "the state store is gone too" (scripts/s3-temp-store.sh, docs/c3-rebuild.md): everything a temporary RustFS on this host needs
  local kit; kit=$(rssh root@192.168.2.4 'L=$(readlink /backup/rustfs-vm/latest 2>/dev/null); [ -n "$L" ] && [ -d "/backup/rustfs-vm/$L/terraform-state" ] && echo snap=$L; cd /backup/rustfs-vm-config 2>/dev/null && [ -s rustfs-1.0.2-image.tar ] && sha256sum -c --quiet rustfs-1.0.2-image.tar.sha256 2>/dev/null && echo image; [ -s /backup/rustfs-vm-config/rustfs.env ] && echo env; command -v docker >/dev/null && echo docker; ss -tln | grep -q "192.168.2.4:9000 " && echo portbusy; [ -e /opt/rustfs-temp/data ] && echo oldtemp' 2>/dev/null)
  case "$kit" in *snap=*) ok "recovery kit: newest whole-store snapshot has terraform-state ($(echo "$kit" | sed -n 's/^snap=//p'))" ;; *) drift "recovery kit: no usable /backup/rustfs-vm/latest with terraform-state (the hourly pull: rustfs-vm-pull.timer)" ;; esac
  case "$kit" in *image*) ok "recovery kit: RustFS image tarball present and its checksum matches" ;; *) drift "recovery kit: /backup/rustfs-vm-config/rustfs-1.0.2-image.tar missing or checksum wrong" ;; esac
  case "$kit" in *env*) ok "recovery kit: rustfs.env (the store's keys) present" ;; *) drift "recovery kit: /backup/rustfs-vm-config/rustfs.env missing" ;; esac
  case "$kit" in *docker*) ok "recovery kit: docker is installed on the backup host" ;; *) drift "recovery kit: docker is not installed on the backup host (a temporary RustFS needs it)" ;; esac
  case "$kit" in *portbusy*) info "192.168.2.4:9000 is in use on the backup host (a temporary store running? scripts/s3-temp-store.sh status)" ;; *) ok "192.168.2.4:9000 is free for a temporary store" ;; esac
  case "$kit" in *oldtemp*) warn "/opt/rustfs-temp/data exists on the backup host: an earlier temporary store (look at it before the next start)" ;; esac
  [ -x "$REPO/scripts/s3-temp-store.sh" ] && ok "scripts/s3-temp-store.sh is present" || drift "scripts/s3-temp-store.sh is missing or not executable"
  info "free space on backup: $(rssh root@192.168.2.4 'df -h /backup | tail -1 | awk "{print \$4\" free of \"\$2}"')"
}

stage_router() {
  stage router "the OpenWrt router (192.168.2.1)"
  local before=$N_DRIFT
  ping -c1 -W2 192.168.2.1 >/dev/null 2>&1 && ok "router answers" || { warn "router does not answer"; return; }
  if ! rssh root@192.168.2.1 true 2>/dev/null; then skip "no ssh key for root@192.168.2.1 on this host (the router backup on the backup host uses its own key): config not compared"; return; fi
  local k v have; for kv in "dhcp.lan.start=25" "dhcp.lan.limit=35" "system.@system[0].zonename=Asia/Kolkata"; do k=${kv%%=*}; v=${kv#*=}
    have=$(rssh root@192.168.2.1 "uci get '$k'" 2>/dev/null); [ "$have" = "$v" ] && ok "router $k = $v" || drift "router $k is '${have:-<unset>}', expected '$v' (docs/openwrt-router.md)"; done
  rssh root@192.168.2.1 "uci get 'dhcp.@dnsmasq[0].rebind_domain'" 2>/dev/null | grep -q rdulinux.com && ok "router rebind_domain rdulinux.com" || drift "router rebind_domain rdulinux.com is missing"
  [ "$RESTORE_ROUTER" = 1 ] && [ "$N_DRIFT" -gt "$before" ] && act "restore the router from the backup host (reboots it)" "$REPO/scripts/openwrt-restore.sh" --yes
}

stage_backups() {
  stage backups "what keeps the lab recoverable"
  local age; age=$(( ( $(date +%s) - $(stat -c %Y /root/backups/terraform-state/last-ok 2>/dev/null || echo 0) ) / 60 ))
  [ "$age" -lt 150 ] && ok "state snapshots pulled to c3 $age min ago (/root/backups/terraform-state)" || drift "the pull of the state snapshots to c3 last ran $age min ago"
  if [ -e /root/dr-staging ] || rssh root@192.168.2.4 'ls -d /backup/c3-dr/bundles/c3-dr-2* >/dev/null 2>&1'; then ok "a c3 capture bundle exists"; else warn "there is NO c3 capture bundle anywhere (/root/dr-staging, backup:/backup/c3-dr): without one the platform cannot be rebuilt. Install the nightly capture: --install-capture"; fi
  if systemctl list-timers --no-pager 2>/dev/null | grep -q c3-dr-capture; then ok "the nightly capture timer is installed"; else
    drift "the nightly capture timer is not installed"; [ "$INSTALL_CAPTURE" = 1 ] && act "install the capture timer" "$REPO/scripts/install-c3-dr-capture.sh"; fi
  [ -e /root/.ssh/id_ed25519 ] && ok "root has an ssh key (for the backup host, the capture push)" || warn "root has no ssh key"
}

stage_verify() {
  stage verify "a last look"
  local n=0 bad=""; for s in $OS_SERVICES; do systemctl is-active --quiet "$s" 2>/dev/null && n=$((n+1)) || bad="$bad $s"; done
  [ -z "$bad" ] && ok "all $n platform services active" || drift "not active:$bad"
  local cs; cs=$(os compute service list -f value -c State)
  if [ -z "$cs" ]; then warn "the Nova API did not answer"; elif echo "$cs" | grep -qv '^up$'; then drift "a Nova service is down"; else ok "Nova services up ($(echo "$cs" | wc -l) of them)"; fi
  info "servers by environment: $(os server list --long -f json -c Status -c Properties | python3 -c "
import json,sys,collections
c=collections.Counter()
for s in json.load(sys.stdin):
    p=s.get('Properties') or {}
    c[(p.get('env','amphora') if isinstance(p,dict) else '?', s['Status'])]+=1
print(dict(c))" 2>/dev/null)"
  info "load balancers: $(os loadbalancer list -f value -c name -c operating_status | tr '\n' ';')"
  local door; for door in finance.rdulinux.com/health argo.rdulinux.com/; do
    [ "$(curl -s -o /dev/null -m 6 -w '%{http_code}' "http://$door")" = 200 ] && ok "front door http://$door answers 200" || warn "front door http://$door does not answer 200 (normal while prod is shut down)"; done
  local ev; ev=$(journalctl -k -b --no-pager 2>/dev/null | grep -c -E 'Oops|segfault|BUG:|Machine check')
  [ "$ev" = 0 ] && ok "no kernel oops/segfault/machine-check since boot" || warn "$ev kernel oops/segfault lines since boot (docs/c3-hardware-instability.md)"
  info "timers: $(systemctl list-timers --no-pager 2>/dev/null | grep -E 'ovn|k8s|tfstate' | awk '{print $(NF-1)}' | tr '\n' ' ')"
}

# ------------------------------------------------------------------------------------------------------------------------------------ run
SEL="all stages"; [ -n "$FROM" ] && SEL="from $FROM"; [ -n "$ONLY" ] && SEL="only $ONLY"; [ -n "$SKIP" ] && SEL="$SEL, skipping $SKIP"
log "INFO " "c3-rebuild-all.sh  mode=$MODE  host=$(hostname)  repo=$REPO  stages: $SEL"
log "INFO " "log file: $LOG"
[ "$MODE" = dry ] && log "INFO " "DRY RUN: nothing will be changed; every WOULD line is what --apply would run"
for s in $STAGES; do
  want "$s" || { CUR=$s; skip "stage $s not selected"; continue; }
  case "$s" in
    preflight) stage_preflight ;; layout) stage_layout ;; platform) stage_platform ;; tuning) stage_tuning ;;
    tf-infra) stage_tf_infra ;; octavia) stage_octavia ;; api-lbs) stage_api_lbs ;; tf-prod) stage_tf_prod ;; tf-cka) stage_tf_cka ;;
    app-lbs) stage_app_lbs ;; apps) stage_apps ;; backup-host) stage_backup_host ;; router) stage_router ;; backups) stage_backups ;; verify) stage_verify ;;
  esac
done
finish 0
