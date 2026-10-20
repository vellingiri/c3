#!/usr/bin/env bash
# Make REPLICA a streaming replica of PRIMARY (PostgreSQL 16, Ubuntu packages).
#
#   scripts/db-replica-setup.sh [primary-host] [replica-host]       default: db1 db2
#   REBUILD=1 scripts/db-replica-setup.sh                           replace a replica that already holds data
#
# Run from your Mac (needs ssh to both hosts as root). Safe to re-run: the replica's data
# directory is thrown away and copied again from the primary. It refuses to touch a host
# that holds a user database unless REBUILD=1, and never touches the primary's data.
# The replication password is generated here and never printed.
set -euo pipefail

PRIMARY=${1:-db1}
REPLICA=${2:-db2}
PGV=16
SLOT="slot_${REPLICA//[^a-z0-9]/_}"
DATA=/var/lib/postgresql/$PGV/main
CONF=/etc/postgresql/$PGV/main

psql_on() { ssh "$1" "sudo -u postgres psql -X -qAt -v ON_ERROR_STOP=1 ${2:-}"; }
say() { printf '\n== %s\n' "$*"; }

[ "$PRIMARY" != "$REPLICA" ] || { echo "primary and replica must differ" >&2; exit 1; }

say "Checks"
P_IP=$(ssh "$PRIMARY" "hostname -I | awk '{print \$1}'")
R_IP=$(ssh "$REPLICA" "hostname -I | awk '{print \$1}'")
[ -n "$P_IP" ] && [ -n "$R_IP" ] && [ "$P_IP" != "$R_IP" ] || { echo "could not tell the two hosts apart ($P_IP / $R_IP)" >&2; exit 1; }
echo "primary $PRIMARY $P_IP    replica $REPLICA $R_IP"
[ "$(echo 'select pg_is_in_recovery()' | psql_on "$PRIMARY")" = f ] || { echo "$PRIMARY is itself a standby; refusing" >&2; exit 1; }
USER_DBS=$(echo "select count(*) from pg_database where not datistemplate and datname <> 'postgres'" | psql_on "$REPLICA" || echo 0)
if [ "$USER_DBS" != 0 ] && [ "${REBUILD:-0}" != 1 ]; then
  echo "$REPLICA already holds $USER_DBS user database(s). Re-run with REBUILD=1 to replace it with a copy of $PRIMARY." >&2
  exit 1
fi

say "Primary: replication role, slot, access, WAL limit"
PW=$(openssl rand -hex 24)
psql_on "$PRIMARY" <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator LOGIN REPLICATION;
  END IF;
END \$\$;
ALTER ROLE replicator PASSWORD '$PW';
SELECT pg_drop_replication_slot('$SLOT') WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '$SLOT' AND NOT active);
SELECT pg_create_physical_replication_slot('$SLOT') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '$SLOT');
SQL
# A slot keeps WAL for a replica that is down; cap it so the primary's disk can never fill.
ssh "$PRIMARY" "sudo tee $CONF/conf.d/20-replication.conf >/dev/null" <<'CONF'
# managed by scripts/db-replica-setup.sh
listen_addresses = '*'
hot_standby_feedback = on
max_slot_wal_keep_size = 2GB
CONF
HBA='host replication replicator 10.0.1.0/24 scram-sha-256'
ssh "$PRIMARY" "grep -qxF '$HBA' $CONF/pg_hba.conf || echo '$HBA' | sudo tee -a $CONF/pg_hba.conf >/dev/null; sudo -u postgres psql -qAtc 'select pg_reload_conf()' >/dev/null"

say "Replica: stop, replace the data directory with a copy of the primary"
# Stop the instance itself: stopping the umbrella "postgresql" unit returns before the server has exited.
ssh "$REPLICA" "sudo systemctl stop postgresql@$PGV-main; ! pgrep -u postgres -x postgres >/dev/null; sudo find $DATA -mindepth 1 -delete"
printf '%s:5432:replication:replicator:%s\n' "$P_IP" "$PW" |
  ssh "$REPLICA" "sudo -u postgres tee /var/lib/postgresql/.pgpass >/dev/null; sudo chmod 600 /var/lib/postgresql/.pgpass"
ssh "$REPLICA" "sudo -u postgres pg_basebackup -h $P_IP -U replicator -D $DATA -R -X stream -S $SLOT -c fast"
ssh "$REPLICA" "sudo tee $CONF/conf.d/20-replication.conf >/dev/null" <<'CONF'
# managed by scripts/db-replica-setup.sh
listen_addresses = '*'
hot_standby_feedback = on
max_slot_wal_keep_size = 2GB
CONF
# Same client rules as the primary, so this host can take over without touching pg_hba.conf.
RULES=$(ssh "$PRIMARY" "grep -E '^host +(financedb|replication) ' $CONF/pg_hba.conf")
ssh "$REPLICA" "sudo tee -a $CONF/pg_hba.conf >/dev/null" <<<"# copied from $PRIMARY by scripts/db-replica-setup.sh
$RULES"
ssh "$REPLICA" "sudo systemctl start postgresql"

say "Wait for streaming"
for i in $(seq 1 30); do
  S=$(echo "select state from pg_stat_replication where client_addr = '$R_IP'" | psql_on "$PRIMARY")
  [ "$S" = streaming ] && break
  sleep 2
done
echo "state on primary: ${S:-none}"
[ "${S:-}" = streaming ] || { echo "replica is not streaming; check: ssh $REPLICA journalctl -u postgresql@$PGV-main -n 50" >&2; exit 1; }
echo "replica in recovery: $(echo 'select pg_is_in_recovery()' | psql_on "$REPLICA")"
echo "Done. Check any time with: scripts/db-replication-status.sh $PRIMARY $REPLICA"
