#!/usr/bin/env bash
# The parts of a c3 rebuild that need the Terraform-created network and the VMs (docs/c3-rebuild.md, steps 3 to 6). Run ON the rebuilt c3 as root,
# from a checkout of the repository (/opt/c3), AFTER c3-dr-install.sh and AFTER `terraform apply` in infra/ (and later in each environment).
#
#   c3-dr-post.sh octavia     after infra: security group, octavia.conf ids (network, security group), load balancer flavor, start Octavia
#   c3-dr-post.sh api-lbs     BEFORE the prod and cka environments: the Kubernetes API load balancers prod-api (.61) and cka-api (.75), with no members yet
#                             (their control planes initialise through them; the reconciler timer k8s-api-lb adds each control-plane VM by itself)
#   c3-dr-post.sh app-lbs     AFTER the prod workers exist: finance-lb (.5) and argo-lb (.113) with the workers as members
#   c3-dr-post.sh lbs         both of the above
#   c3-dr-post.sh check       print what is there (no changes)
#
# Why the ids: octavia.conf names the external network (amphora management network) and the amphora security group by UUID, and both are new after a
# rebuild; `amp_flavor_id = 100` (flavor m1.octavia) and the image tag `Amphora` are stable and were put back by c3-dr-install.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"            # .../scripts
eval "$(grep -E '^export OS_' /root/.bashrc)"
say() { printf '\n== %s\n' "$*"; }

ext_net_id()  { openstack network show external_network -f value -c id; }
prod_workers() { openstack server list --all-projects --long -f json | python3 -c "
import json,sys,re
for s in json.load(sys.stdin):
    p=s.get('Properties') or {}
    if isinstance(p,str): p=dict(x.split('=',1) for x in p.replace(\"'\",'').split(', ') if '=' in x)
    if p.get('env')=='prod' and p.get('role')=='worker' and s['Status']=='ACTIVE':
        m=re.search(r'10\.0\.1\.\d+', str(s['Networks']))
        if m: print(s['Name'], m.group(0))"; }
controllers() { # controllers <env>: private addresses of the control-plane VMs
  openstack server list --all-projects --long -f json | python3 -c "
import json,sys,re
env=sys.argv[1]
for s in json.load(sys.stdin):
    p=s.get('Properties') or {}
    if isinstance(p,str): p=dict(x.split('=',1) for x in p.replace(\"'\",'').split(', ') if '=' in x)
    if p.get('env')==env and p.get('role') in ('controller','controller_join') and s['Status']=='ACTIVE':
        m=re.search(r'10\.0\.1\.\d+', str(s['Networks']))
        if m: print(m.group(0))" "$1"; }

wait_lb() { local i s; for i in $(seq 1 120); do s=$(openstack loadbalancer show "$1" -c provisioning_status -f value 2>/dev/null || echo gone); [ "$s" = ACTIVE ] && return 0; [ "$s" = ERROR ] && { echo "$1 ERROR" >&2; return 1; }; sleep 5; done; return 1; }

octavia() {
  say "Octavia: security group, configuration ids, load balancer flavor"
  local ext svc sg
  ext=$(ext_net_id); svc=$(openstack project show service -f value -c id)
  sg=$(openstack security group list --project "$svc" -f value -c ID -c Name | awk '$2=="lb-mgmt-sec-group"{print $1}')
  if [ -z "$sg" ]; then
    sg=$(openstack security group create lb-mgmt-sec-group --project "$svc" --description "Octavia amphora management" -f value -c id)
    openstack security group rule create --project "$svc" --protocol icmp --ingress "$sg" >/dev/null
    for p in 22 80 443 9443; do openstack security group rule create --project "$svc" --protocol tcp --dst-port "$p" --ingress "$sg" >/dev/null; done
    echo "created security group lb-mgmt-sec-group ($sg)"
  fi
  crudini --set /etc/octavia/octavia.conf controller_worker amp_secgroup_list "$sg"
  crudini --set /etc/octavia/octavia.conf controller_worker amp_boot_network_list "$ext"
  echo "amp_secgroup_list=$sg  amp_boot_network_list=$ext  amp_flavor_id=$(crudini --get /etc/octavia/octavia.conf controller_worker amp_flavor_id)"
  openstack flavor show 100 >/dev/null || { echo "flavor with id 100 (m1.octavia) missing: re-run c3-dr-install.sh phase 5" >&2; exit 1; }
  [ "$(openstack image list --tag Amphora -f value -c ID | wc -l)" = 1 ] || { echo "exactly one image must carry the tag Amphora (the patched one, docs/amphora-reboot-fix.md)" >&2; openstack image list --long -c Name -c Tags; exit 1; }
  openstack loadbalancer flavorprofile list -f value -c name | grep -qx active-standby || \
    openstack loadbalancer flavorprofile create --name active-standby --provider amphora --flavor-data '{"loadbalancer_topology": "ACTIVE_STANDBY"}' >/dev/null
  openstack loadbalancer flavor list -f value -c name | grep -qx ha || openstack loadbalancer flavor create --name ha --flavorprofile active-standby --enable >/dev/null
  systemctl enable --now octavia-api octavia-health-manager octavia-housekeeping octavia-worker
  systemctl restart octavia-worker octavia-health-manager octavia-housekeeping
  echo "Octavia started. Health manager listens on $(crudini --get /etc/octavia/octavia.conf health_manager bind_ip):5555"
}

app_lb() { # app_lb <name> <floating ip> <listener> <pool> <backend port> <monitor path> <monitor name> <listener-name> ...
  local name=$1 fip=$2 listener=$3 pool=$4 port=$5 path=$6 hm=$7
  if openstack loadbalancer show "$name" >/dev/null 2>&1; then echo "$name exists; skipping"; return 0; fi
  say "load balancer $name (ACTIVE_STANDBY), floating IP $fip, workers on :$port"
  local workers; workers=$(prod_workers)
  [ -n "$workers" ] || { echo "no ACTIVE prod workers found: create environments/prod first" >&2; return 1; }
  openstack loadbalancer create --name "$name" --vip-subnet-id private_subnet --flavor ha -f value -c id >/dev/null; wait_lb "$name"
  openstack loadbalancer listener create --name "$listener" --protocol HTTP --protocol-port 80 --insert-headers X-Forwarded-For=true "$name" >/dev/null; wait_lb "$name"
  openstack loadbalancer pool create --name "$pool" --lb-algorithm ROUND_ROBIN --listener "$listener" --protocol HTTP >/dev/null; wait_lb "$name"
  while read -r wn wip; do
    openstack loadbalancer member create --name "$wn" --subnet-id private_subnet --address "$wip" --protocol-port "$port" "$pool" >/dev/null; wait_lb "$name"
  done <<< "$workers"
  openstack loadbalancer healthmonitor create --name "$hm" --type HTTP --url-path "$path" --expected-codes 200 --delay 5 --timeout 3 --max-retries 3 "$pool" >/dev/null; wait_lb "$name"
  openstack floating ip create --floating-ip-address "$fip" external_network >/dev/null
  openstack floating ip set --port "$(openstack loadbalancer show "$name" -c vip_port_id -f value)" "$fip"
  echo "$name ready: $(openstack loadbalancer show "$name" -c vip_address -f value) / $fip"
}

api_lbs() {
  say "Kubernetes API load balancers (api.prod -> .61, api.cka -> .75 in infra/infra.yaml); control planes are added by the reconciler k8s-api-lb.timer"
  openstack loadbalancer show prod-api >/dev/null 2>&1 || FIP=192.168.2.61 bash "$HERE/octavia-k8s-api-lb.sh" prod ha
  openstack loadbalancer show cka-api  >/dev/null 2>&1 || FIP=192.168.2.75 bash "$HERE/octavia-k8s-api-lb.sh" cka single
  systemctl start ovn-vip-binding.service 2>/dev/null || true
}

app_lbs() {
  say "application load balancers (addresses as in infra/infra.yaml: finance .5, argo .113)"
  app_lb finance-lb 192.168.2.5   finance-http finance-pool 30080 /health  finance-hm
  app_lb argo-lb    192.168.2.113 argo-http    argo-backend 30443 /healthz argo-backend-hm
  systemctl start ovn-vip-binding.service 2>/dev/null || true
  check
}

check() {
  say "state"
  openstack loadbalancer list -c name -c vip_address -c provisioning_status -c operating_status
  openstack loadbalancer amphora list -c id -c role -c status
  openstack floating ip list -c "Floating IP Address" -c "Fixed IP Address" -c Status | head -20
  for u in http://finance.rdulinux.com/health http://argo.rdulinux.com/; do printf '%s -> %s\n' "$u" "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$u")"; done
}

case "${1:-}" in
  octavia) octavia ;;
  api-lbs) api_lbs ;;
  app-lbs) app_lbs ;;
  lbs) api_lbs; app_lbs ;;
  check) check ;;
  *) sed -n 2,12p "$0"; exit 2 ;;
esac
