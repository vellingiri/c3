#!/usr/bin/env bash
# Show whether the replica is following the primary. Read-only.
#   scripts/db-replication-status.sh [primary-host] [replica-host]       default: db1 db2
# Exit code is 0 only when the replica is streaming with under 1 MB of lag.
set -euo pipefail
PRIMARY=${1:-db1}
REPLICA=${2:-db2}
q() { ssh "$1" "sudo -u postgres psql -X -qAt -F ' | ' -c \"$2\""; }

echo "== $PRIMARY (primary?)   in recovery: $(q "$PRIMARY" 'select pg_is_in_recovery()')"
echo "-- walsenders: client, state, sync, bytes behind"
q "$PRIMARY" "select client_addr, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) from pg_stat_replication"
echo "-- slots: name, active, retained WAL"
q "$PRIMARY" "select slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) from pg_replication_slots"
echo "== $REPLICA (replica?)   in recovery: $(q "$REPLICA" 'select pg_is_in_recovery()')"
LAG=$(q "$REPLICA" "select coalesce(extract(epoch from now() - pg_last_xact_replay_timestamp())::int, 0)")
echo "-- seconds since the last replayed transaction (idle primary shows growth): $LAG"
BYTES=$(q "$PRIMARY" "select coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), -1)::bigint from pg_stat_replication")
STATE=$(q "$PRIMARY" "select coalesce(max(state), 'none') from pg_stat_replication")
echo "== state: $STATE, behind: $BYTES bytes"
[ "$STATE" = streaming ] && [ "$BYTES" -ge 0 ] && [ "$BYTES" -lt 1048576 ]
