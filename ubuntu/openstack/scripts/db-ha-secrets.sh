#!/usr/bin/env bash
# Create environments/prod/secrets.auto.tfvars: the passwords the database HA group (Patroni, replication) and its notifications use.
# Terraform puts them into the cloud-init of db1, db2 and dbw, so a rebuilt node needs nothing typed by hand.
#   scripts/db-ha-secrets.sh            write the file if it does not exist yet (does nothing if it does)
#   scripts/db-ha-secrets.sh --check    only say whether it exists
# Values: the ones the RUNNING cluster already uses (read from /etc/patroni/config.yml on db1 / db2 over ssh), so nothing has to be rotated;
# if there is no cluster yet, new random ones. The ntfy topic URL is read from the runner. Nothing is printed. The file is git-ignored (mode 600);
# if you lose it, run this again while the cluster is up and you get the same values back.
set -euo pipefail
OUT="$(cd "$(dirname "$0")/.." && pwd)/environments/prod/secrets.auto.tfvars"
if [ -e "$OUT" ]; then echo "exists: $OUT"; exit 0; fi
[ "${1:-}" != --check ] || { echo "missing: $OUT"; exit 1; }

get() { # get <python expr on d> : from the first of db1/db2 that has the config, empty if none
  local h v
  for h in db1 db2; do
    v=$(ssh -o ConnectTimeout=8 "$h" "test -f /etc/patroni/config.yml && python3 -c \"import yaml; d=yaml.safe_load(open('/etc/patroni/config.yml')); print($1)\"" 2>/dev/null || true)
    [ -z "$v" ] || { printf '%s' "$v"; return; }
  done
}
rand() { openssl rand -hex 24; }

PG=$(get "d['postgresql']['authentication']['superuser']['password']");    [ -n "$PG" ] || PG=$(rand)
REPL=$(get "d['postgresql']['authentication']['replication']['password']"); [ -n "$REPL" ] || REPL=$(rand)
REST=$(get "d['restapi']['authentication']['password']");                   [ -n "$REST" ] || REST=$(rand)
NTFY=$(ssh -o ConnectTimeout=8 runner "sed -n 's/^NTFY_URL=//p' /etc/default/db-monitor" 2>/dev/null || true)

umask 077
cat > "$OUT" <<TFVARS
# written by scripts/db-ha-secrets.sh; git-ignored. Do not commit.
db_ha_postgres_password    = "$PG"
db_ha_replication_password = "$REPL"
db_ha_rest_password        = "$REST"
db_ha_ntfy_url             = "$NTFY"
TFVARS
echo "written: $OUT (mode 600, values not shown; ntfy url $([ -n "$NTFY" ] && echo set || echo empty))"
