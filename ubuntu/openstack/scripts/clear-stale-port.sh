#!/usr/bin/env bash
# Clear a stale device_id/device_owner on Neutron ports after a VM replace, when the new VM fails with
# "409 Port <id> is still in use". Keeps the port, its fixed IP and its floating IP.
#   scripts/clear-stale-port.sh <port-id> [<port-id> ...]
# (`openstack port set --device ''` ignores empty values, so this calls the Neutron API directly.)
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <port-id> [...]" >&2; exit 1; }
NEUTRON=${NEUTRON_URL:-$(openstack endpoint list --service network --interface public -f value -c URL | head -1)}
NEUTRON=${NEUTRON%/}
TOKEN=$(openstack token issue -f value -c id)
for p in "$@"; do
  curl -fsS -X PUT "$NEUTRON/v2.0/ports/$p" \
    -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
    -d '{"port": {"device_id": "", "device_owner": ""}}' |
    python3 -c 'import sys,json; p=json.load(sys.stdin)["port"]; print("%s  device_id=%r device_owner=%r" % (p["name"], p["device_id"], p["device_owner"]))'
done
