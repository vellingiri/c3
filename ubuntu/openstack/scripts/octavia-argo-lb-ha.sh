#!/usr/bin/env bash
# Rebuild Argo CD's load balancer as ACTIVE_STANDBY (two amphorae) with the same listener, pool, members, health monitor and floating IP.
# Run ON c3 with admin credentials:   bash scripts/octavia-argo-lb-ha.sh
# A load balancer's topology cannot be changed in place, so a new one is built next to the old one, the floating IP (192.168.2.113, argo.rdulinux.com)
# is moved to it (a few seconds without Argo's web address, nothing else is affected: Argo's own sync does not use it), then the old one is deleted
# and the new one takes its name. Octavia objects are hand-made here (docs/octavia-finance-lb.md), so this script is the record of how.
set -euo pipefail

OLD=argo-lb
NEW=argo-lb-ha
FIP=192.168.2.113
MEMBERS="w1=10.0.1.67 w2=10.0.1.197 w3=10.0.1.45"      # prod workers, Argo CD NodePort 30443
PORT=30443

wait_lb() {  # wait_lb <lb> : ACTIVE (or gone with "gone")
  local i s
  for i in $(seq 1 120); do
    s=$(openstack loadbalancer show "$1" -c provisioning_status -f value 2>/dev/null || echo gone)
    case "$s" in ACTIVE) return 0 ;; ERROR) echo "$1 went to ERROR" >&2; return 1 ;; gone) [ "${2:-}" = gone ] && return 0 ;; esac
    sleep 5
  done
  echo "timeout waiting for $1 ($s)" >&2; return 1
}

[ "$(openstack loadbalancer show $OLD -c provisioning_status -f value)" = ACTIVE ] || { echo "$OLD is not ACTIVE" >&2; exit 1; }
if openstack loadbalancer show "$NEW" >/dev/null 2>&1; then echo "$NEW already exists; remove it first or continue by hand" >&2; exit 1; fi

echo "== build $NEW (ACTIVE_STANDBY)"
openstack loadbalancer create --name "$NEW" --vip-subnet-id private_subnet --flavor ha -f value -c id >/dev/null; wait_lb "$NEW"
openstack loadbalancer listener create --name argo-http-ha --protocol HTTP --protocol-port 80 --insert-headers X-Forwarded-For=true "$NEW" >/dev/null; wait_lb "$NEW"
openstack loadbalancer pool create --name argo-backend-ha --lb-algorithm ROUND_ROBIN --listener argo-http-ha --protocol HTTP >/dev/null; wait_lb "$NEW"
for m in $MEMBERS; do
  openstack loadbalancer member create --name "${m%%=*}" --subnet-id private_subnet --address "${m##*=}" --protocol-port $PORT argo-backend-ha >/dev/null; wait_lb "$NEW"
done
openstack loadbalancer healthmonitor create --name argo-backend-ha-hm --type HTTP --url-path /healthz --expected-codes 200 --delay 5 --timeout 3 --max-retries 3 argo-backend-ha >/dev/null; wait_lb "$NEW"

echo "== wait for the members to be ONLINE"
for i in $(seq 1 60); do
  n=$(openstack loadbalancer member list argo-backend-ha -c operating_status -f value | grep -c ONLINE || true)
  [ "$n" = 3 ] && break; sleep 5
done
echo "members ONLINE: $n of 3"; [ "$n" = 3 ] || { echo "not all members are ONLINE; stopping before the switch" >&2; exit 1; }

echo "== move the floating IP $FIP to $NEW"
NEWPORT=$(openstack loadbalancer show "$NEW" -c vip_port_id -f value)
openstack floating ip set --port "$NEWPORT" "$FIP"
sleep 5
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://$FIP/ -H 'Host: argo.rdulinux.com' || true)
echo "argo via the new load balancer: HTTP $code"
[ "$code" = 200 ] || { echo "not 200: putting the floating IP back on $OLD" >&2; openstack floating ip set --port "$(openstack loadbalancer show $OLD -c vip_port_id -f value)" "$FIP"; exit 1; }

echo "== delete the old $OLD and give its name to $NEW"
openstack loadbalancer delete --cascade "$OLD"; wait_lb "$OLD" gone
openstack loadbalancer set --name "$OLD" "$NEW"; wait_lb "$OLD"
openstack loadbalancer listener set --name argo-http argo-http-ha; wait_lb "$OLD"
openstack loadbalancer pool set --name argo-backend argo-backend-ha; wait_lb "$OLD"
openstack loadbalancer healthmonitor set --name argo-backend-hm argo-backend-ha-hm; wait_lb "$OLD"
openstack loadbalancer show "$OLD" -c name -c provisioning_status -c operating_status -f value | tr '\n' ' '; echo
openstack loadbalancer amphora list --loadbalancer "$(openstack loadbalancer show $OLD -c id -f value)" -c id -c role -c status -f value
