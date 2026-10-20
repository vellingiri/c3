#!/usr/bin/env bash
# The shared API address of a Kubernetes cluster: an Octavia TCP load balancer on :6443 in front of every control-plane node.
# Run ON c3 with admin credentials:
#   bash scripts/octavia-k8s-api-lb.sh <env> <single|ha> <controller-ip> [<controller-ip>...]     e.g.  prod ha 10.0.1.254 10.0.1.x 10.0.1.y
#   bash scripts/octavia-k8s-api-lb.sh <env> members <controller-ip>...                           replace the member list (after a control-plane node is added or removed)
# Creates (or updates) load balancer `<env>-api`: listener `<env>-api-6443` TCP :6443, pool `<env>-api-pool` (round robin, TCP health monitor),
# one member per control-plane node, and a floating IP. It prints the VIP and floating IP; put the floating IP in infra/infra.yaml as `api.<env>`
# (zone `<env>.rdulinux.com.`), that name is the cluster's controlPlaneEndpoint (docs/k8s-ha-control-plane.md).
# `ha` = ACTIVE_STANDBY (two amphorae, 2 GB each, survives the loss of one); `single` = one amphora (a spare/practice cluster).
# TCP passthrough, so the API server's own certificate is what clients see: its SANs must include the API name and floating IP.
set -euo pipefail

ENV_NAME=${1:?env (prod|qa|cka)}; MODE=${2:?single|ha|members}; shift 2
[ $# -ge 1 ] || { echo "give at least one control-plane address" >&2; exit 2; }
LB="$ENV_NAME-api"; LISTENER="$ENV_NAME-api-6443"; POOL="$ENV_NAME-api-pool"; HM="$ENV_NAME-api-hm"

wait_lb() {
  local i s
  for i in $(seq 1 120); do
    s=$(openstack loadbalancer show "$LB" -c provisioning_status -f value 2>/dev/null || echo gone)
    case "$s" in ACTIVE) return 0 ;; ERROR) echo "$LB went to ERROR" >&2; return 1 ;; esac
    sleep 5
  done
  echo "timeout waiting for $LB ($s)" >&2; return 1
}

set_members() {   # make the pool's members exactly the given addresses
  local have want ip m
  have=$(openstack loadbalancer member list "$POOL" -c id -c address -f value)
  while read -r id addr; do
    [ -n "${id:-}" ] || continue
    case " $* " in *" $addr "*) ;; *) openstack loadbalancer member delete "$POOL" "$id"; wait_lb ;; esac
  done <<< "$have"
  for ip in "$@"; do
    echo "$have" | grep -q " $ip\$" && continue
    openstack loadbalancer member create --name "cp-$ip" --subnet-id private_subnet --address "$ip" --protocol-port 6443 "$POOL" >/dev/null; wait_lb
  done
}

if [ "$MODE" != members ]; then
  case "$MODE" in single) FLAVOR=() ;; ha) FLAVOR=(--flavor ha) ;; *) echo "mode must be single, ha or members" >&2; exit 2 ;; esac
  openstack loadbalancer show "$LB" >/dev/null 2>&1 && { echo "$LB already exists (use the 'members' mode to change its members)" >&2; exit 1; }
  echo "== create $LB ($MODE)"
  openstack loadbalancer create --name "$LB" --vip-subnet-id private_subnet "${FLAVOR[@]}" -f value -c id >/dev/null; wait_lb
  openstack loadbalancer listener create --name "$LISTENER" --protocol TCP --protocol-port 6443 --timeout-client-data 3600000 --timeout-member-data 3600000 "$LB" >/dev/null; wait_lb
  openstack loadbalancer pool create --name "$POOL" --lb-algorithm ROUND_ROBIN --listener "$LISTENER" --protocol TCP >/dev/null; wait_lb
  openstack loadbalancer healthmonitor create --name "$HM" --type TCP --delay 5 --timeout 3 --max-retries 3 "$POOL" >/dev/null; wait_lb
fi

echo "== members: $*"
set_members "$@"

if [ "$MODE" != members ]; then
  FIP=$(openstack floating ip create external_network -c floating_ip_address -f value)
  openstack floating ip set --port "$(openstack loadbalancer show "$LB" -c vip_port_id -f value)" "$FIP"
  echo "FIP=$FIP"
fi
sleep 8
openstack loadbalancer show "$LB" -c vip_address -c provisioning_status -c operating_status -f value | tr '\n' ' '; echo
openstack loadbalancer member list "$POOL" -c name -c address -c operating_status -f value
