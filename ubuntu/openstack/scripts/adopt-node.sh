#!/usr/bin/env bash
# Adopt an EXISTING OpenStack VM into an environment without recreating it.
#
#   scripts/adopt-node.sh <env-dir> <vm-name>          # show IDs + the import commands (changes nothing)
#   scripts/adopt-node.sh <env-dir> <vm-name> --run    # run the imports
#
# DOMAIN=<zone without dot> selects the node's DNS zone (default rdulinux.com; prod k8s nodes use
# prod.rdulinux.com). NO_DNS=1 skips the A/PTR records (use with manage_dns: false when another
# stack, e.g. infra, owns them).
#
# Needs: openstack CLI + OS_* creds, jq, terraform (with S3 backend creds), and
# the node already listed in <env-dir>/nodes.yaml.
set -euo pipefail

ENV_DIR=${1:?env dir, e.g. environments/prod}
NAME=${2:?vm name, e.g. db}
RUN=${3:-}
DOMAIN=${DOMAIN:-rdulinux.com}
REVERSE_ZONE=${REVERSE_ZONE:-2.168.192.in-addr.arpa.}

os() { openstack "$@"; }

# VM names are not unique across environments (c1 exists in prod and qa); pass
# SERVER_ID=<uuid> when the name matches more than one server.
if [ -z "${SERVER_ID:-}" ]; then
  MATCHES=$(os server list --name "^${NAME}\$" -f value -c ID)
  [ "$(wc -w <<<"$MATCHES")" -eq 1 ] || { echo "'$NAME' matches: ${MATCHES:-nothing}. Re-run with SERVER_ID=<uuid>." >&2; exit 1; }
  SERVER_ID=$MATCHES
fi
PORT_IDS=$(os port list --server "$SERVER_ID" -f value -c ID)
[ "$(wc -w <<<"$PORT_IDS")" -eq 1 ] || { echo "expected exactly 1 port on $NAME, got: $PORT_IDS" >&2; exit 1; }
PORT_ID=$PORT_IDS
FIP_JSON=$(os floating ip list --port "$PORT_ID" -f json)
FIP_ID=$(jq -r '.[0].ID' <<<"$FIP_JSON")
FIP_ADDR=$(jq -r '.[0]["Floating IP Address"]' <<<"$FIP_JSON")
[ "$FIP_ID" != null ] || { echo "no floating IP on $NAME" >&2; exit 1; }

FWD_ZONE_ID=$(os zone show "$DOMAIN." -f value -c id)
REV_ZONE_ID=$(os zone show "$REVERSE_ZONE" -f value -c id)
A_ID=$(os recordset list "$FWD_ZONE_ID" --name "$NAME.$DOMAIN." -f value -c id || true)
PTR_NAME="${FIP_ADDR##*.}.$REVERSE_ZONE"
PTR_ID=$(os recordset list "$REV_ZONE_ID" --name "$PTR_NAME" -f value -c id || true)

echo "== $NAME =="
echo "server      $SERVER_ID"
echo "port        $PORT_ID"
echo "floating ip $FIP_ADDR ($FIP_ID)"
echo "A record    ${A_ID:-<none, will be created>}"
echo "PTR record  ${PTR_ID:-<none, will be created>} ($PTR_NAME)"
echo
echo "== Put these in nodes.yaml for $NAME (must match reality or plan will change/replace the VM) =="
echo "flavor:             $(os server show "$SERVER_ID" -f value -c flavor)"
echo "keypair:            $(os server show "$SERVER_ID" -f value -c key_name)"
echo "security_group_ids: $(os port show "$PORT_ID" -f json | jq -c '.security_group_ids')"
echo

M="module.node[\"$NAME\"]"
CMDS=(
  "$M.openstack_networking_port_v2.this|$PORT_ID"
  "$M.openstack_compute_instance_v2.this|$SERVER_ID"
  "$M.openstack_networking_floatingip_v2.this|$FIP_ID"
  "$M.openstack_networking_floatingip_associate_v2.this|$FIP_ID"
)
[ -z "${NO_DNS:-}" ] && [ -n "$A_ID" ]   && CMDS+=("$M.openstack_dns_recordset_v2.a[0]|$FWD_ZONE_ID/$A_ID")
[ -z "${NO_DNS:-}" ] && [ -n "$PTR_ID" ] && CMDS+=("$M.openstack_dns_recordset_v2.ptr[0]|$REV_ZONE_ID/$PTR_ID")

cd "$ENV_DIR"
IN_STATE=$(terraform state list 2>/dev/null || true)   # makes re-runs safe: skip what is already imported
for c in "${CMDS[@]}"; do
  addr=${c%%|*}; id=${c##*|}
  if grep -Fxq -- "$addr" <<<"$IN_STATE"; then echo "# already in state, skipping: $addr"; continue; fi
  if [ "$RUN" = "--run" ]; then terraform import "$addr" "$id"; else echo "terraform import '$addr' $id"; fi
done

[ "$RUN" = "--run" ] && echo && echo "Now run: terraform plan   (must show NO destroy/replace on the instance)"
exit 0
