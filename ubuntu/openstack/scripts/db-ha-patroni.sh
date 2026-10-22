#!/usr/bin/env bash
# Put the existing PostgreSQL pair (db1 primary, db2 replica) under Patroni, WITHOUT rebuilding any data.
#   scripts/db-ha-patroni.sh prepare          credentials, hba lines, config backups and /etc/patroni/config.yml on both (nothing restarts)
#   scripts/db-ha-patroni.sh adopt-primary    stop Postgres on the primary and let Patroni take it over (seconds of failed writes)
#   scripts/db-ha-patroni.sh adopt-replica    the same for the replica; it then follows the leader
#   scripts/db-ha-patroni.sh notify           ntfy message on every role change (callback script on both hosts)
#   scripts/db-ha-patroni.sh status           Patroni's view, etcd health, replication
#   scripts/db-ha-patroni.sh rollback <host>  back to plain Postgres on that host (see below)
# Run from your Mac (ssh as root to db1 and db2). etcd must already be up: scripts/db-ha-etcd.sh. Design, drills and operation: docs/db-ha-patroni.md.
#
# Facts learned by rehearsing on a throwaway cluster (they are why this script does what it does):
#  * Patroni overwrites /etc/postgresql/16/main/postgresql.conf with a tiny stub that includes `custom_conf`. So the ORIGINAL file is first
#    copied to postgresql.base.conf and custom_conf points there (pointing it at postgresql.conf itself makes Postgres refuse to start: recursion).
#  * Patroni connects to Postgres over loopback TCP with a password, so the `postgres` role needs one BEFORE Patroni starts, else it cannot even
#    read the node's state and never races for leadership.
#  * Patroni always starts a stopped node as a standby and then promotes it by winning the leader lock; a first adoption therefore bumps the
#    timeline and takes about 4 to 10 s.
#  * Patroni.service uses KillMode=process: stopping Patroni leaves Postgres running (use patronictl or stop Postgres explicitly).
set -euo pipefail

PRIMARY=db1
REPLICA=db2
HOSTS=("$PRIMARY" "$REPLICA")
SCOPE=finance-db
NS=/patroni/
CFG=/etc/patroni/config.yml
PGV=16
CONF=/etc/postgresql/$PGV/main
BACKUP=/root/db-ha-backup-$(date +%Y%m%d)

ip_of() { ssh "$1" "hostname -I | awk '{print \$1}'"; }
pgq() { ssh "$1" "sudo -u postgres psql -X -qAt -v ON_ERROR_STOP=1 -c \"$2\""; }
etcd_eps() { local e="" h; for h in db1 db2 dbw1; do e+="$(ip_of "$h"):2379,"; done; echo "${e%,}"; }
pctl() { ssh "$1" "sudo -u postgres patronictl -c $CFG $2"; }

need_etcd() {
  local out; out=$(ssh db1 "ETCDCTL_API=3 etcdctl --endpoints=$(etcd_eps | sed 's/\([0-9.]*:2379\)/http:\/\/\1/g') endpoint health 2>&1" || true)
  [ "$(echo "$out" | grep -c 'is healthy')" -ge 3 ] || { echo "etcd is not healthy on all three members:" >&2; echo "$out" >&2; exit 1; }
}

secret() { # secret <yaml path as python expr on d>  -> value from the existing config on db1, or empty
  ssh "$PRIMARY" "test -f $CFG && python3 -c \"import yaml; d=yaml.safe_load(open('$CFG')); print($1)\"" 2>/dev/null || true
}

write_config() { # write_config <host> <ip> <pg_pw> <repl_pw> <rest_pw>
  local h=$1 ip=$2 pg=$3 repl=$4 rest=$5 eps
  eps=$(etcd_eps)
  ssh "$h" "umask 077; cat > $CFG; chown postgres:postgres $CFG; chmod 600 $CFG" <<YAML
# managed by scripts/db-ha-patroni.sh (docs/db-ha-patroni.md)
scope: $SCOPE
namespace: $NS
name: $h
log:
  level: INFO
etcd3:
  hosts: $eps
restapi:
  listen: 0.0.0.0:8008
  connect_address: $ip:8008
  authentication:
    username: patroni
    password: $rest
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    primary_start_timeout: 60
    failsafe_mode: true
    synchronous_mode: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"
        hot_standby_feedback: "on"
        max_slot_wal_keep_size: 2GB
postgresql:
  listen: 0.0.0.0:5432
  connect_address: $ip:5432
  data_dir: /var/lib/postgresql/$PGV/main
  config_dir: $CONF
  custom_conf: $CONF/postgresql.base.conf
  bin_dir: /usr/lib/postgresql/$PGV/bin
  pgpass: /var/lib/postgresql/.pgpass-patroni
  authentication:
    superuser:
      username: postgres
      password: $pg
    replication:
      username: replicator
      password: $repl
  parameters:
    unix_socket_directories: /var/run/postgresql
  callbacks:
    on_role_change: /usr/local/bin/patroni-notify
tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
YAML
}

prepare() {
  need_etcd
  [ "$(pgq $PRIMARY 'select pg_is_in_recovery()')" = f ] || { echo "$PRIMARY is not the primary; refusing" >&2; exit 1; }
  local pg repl rest P_IP R_IP
  pg=$(secret "d['postgresql']['authentication']['superuser']['password']")
  repl=$(secret "d['postgresql']['authentication']['replication']['password']")
  rest=$(secret "d['restapi']['authentication']['password']")
  [ -n "$pg" ] || pg=$(openssl rand -hex 24)
  [ -n "$repl" ] || repl=$(openssl rand -hex 24)
  [ -n "$rest" ] || rest=$(openssl rand -hex 24)
  P_IP=$(ip_of $PRIMARY); R_IP=$(ip_of $REPLICA)
  echo "== backups of the original Postgres configuration on both hosts: $BACKUP"
  for h in "${HOSTS[@]}"; do
    ssh "$h" "mkdir -p $BACKUP && cp -a $CONF $BACKUP/etc-postgresql-main && cp -a /var/lib/postgresql/$PGV/main/postgresql.auto.conf $BACKUP/ 2>/dev/null || true; ls $BACKUP | tr '\n' ' '; echo"
    ssh "$h" "[ -f $CONF/postgresql.base.conf ] || cp -a $CONF/postgresql.conf $CONF/postgresql.base.conf; wc -c < $CONF/postgresql.base.conf | xargs echo '$h postgresql.base.conf bytes (original, must be large):'"
  done
  echo "== passwords (set on the primary, they replicate; never printed)"
  ssh "$PRIMARY" "sudo -u postgres psql -X -qAt -v ON_ERROR_STOP=1" <<SQL
ALTER ROLE postgres PASSWORD '$pg';
ALTER ROLE replicator PASSWORD '$repl';
SQL
  # the replica's current walreceiver reads this file when it reconnects; keep it valid until Patroni takes over there
  ssh "$REPLICA" "sudo -u postgres tee /var/lib/postgresql/.pgpass >/dev/null && chmod 600 /var/lib/postgresql/.pgpass" <<PGPASS
$P_IP:5432:replication:replicator:$repl
PGPASS
  echo "== pg_hba: the superuser may log in from the two database hosts only (Patroni and pg_rewind need it)"
  for h in "${HOSTS[@]}"; do
    ssh "$h" "for ip in $P_IP $R_IP; do L=\"host all postgres \$ip/32 scram-sha-256\"; grep -qxF \"\$L\" $CONF/pg_hba.conf || echo \"\$L\" | sudo tee -a $CONF/pg_hba.conf >/dev/null; done; sudo -u postgres psql -X -qAt -c 'select pg_reload_conf()' >/dev/null"
  done
  echo "== Patroni config (service kept disabled until adoption)"
  write_config "$PRIMARY" "$P_IP" "$pg" "$repl" "$rest"
  write_config "$REPLICA" "$R_IP" "$pg" "$repl" "$rest"
  for h in "${HOSTS[@]}"; do ssh "$h" "systemctl disable patroni >/dev/null 2>&1; systemctl is-active patroni || true"; done
  echo "prepared. Next: scripts/db-ha-patroni.sh adopt-primary"
}

wait_leader() { # wait_leader <host> <seconds>
  local i st
  for i in $(seq 1 "$2"); do
    st=$(pctl "$1" "list -f json" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(m['Role']+':'+m['State'] for m in d if m['Member']=='$1'))" 2>/dev/null || true)
    case "$st" in "Leader:running") return 0 ;; esac
    sleep 2
  done
  echo "not leader after $(( $2 * 2 )) s (last: ${st:-no answer})" >&2; return 1
}

adopt_primary() {
  need_etcd
  [ "$(pgq $PRIMARY 'select pg_is_in_recovery()')" = f ] || { echo "$PRIMARY is not the primary; refusing" >&2; exit 1; }
  ssh "$PRIMARY" "test -f $CFG" || { echo "run 'prepare' first" >&2; exit 1; }
  local lag; lag=$(pgq $PRIMARY "select coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),-1)::bigint from pg_stat_replication")
  [ "$lag" = 0 ] || { echo "the replica is not caught up (lag $lag); refusing" >&2; exit 1; }
  local T0; T0=$(date +%s)
  echo "== stopping plain Postgres on $PRIMARY (the app's pool reconnects by itself)"
  ssh "$PRIMARY" "systemctl stop postgresql@$PGV-main; systemctl mask postgresql@$PGV-main >/dev/null 2>&1; systemctl enable patroni >/dev/null 2>&1; systemctl start patroni"
  if wait_leader "$PRIMARY" 60; then
    echo "[+$(( $(date +%s) - T0 )) s] $PRIMARY is the Patroni leader"
    pctl "$PRIMARY" "list"
    echo "writable: $(pgq $PRIMARY 'select not pg_is_in_recovery()')   wal_log_hints: $(pgq $PRIMARY 'show wal_log_hints')   timeline: $(pgq $PRIMARY 'select timeline_id from pg_control_checkpoint()')"
  else
    echo "Patroni did not become leader. Run: scripts/db-ha-patroni.sh rollback $PRIMARY" >&2; exit 1
  fi
}

adopt_replica() {
  need_etcd
  pctl "$PRIMARY" "list" | grep -q "Leader" || { echo "no Patroni leader yet: run adopt-primary first" >&2; exit 1; }
  local T0 i st; T0=$(date +%s)
  echo "== stopping plain Postgres on $REPLICA"
  ssh "$REPLICA" "systemctl stop postgresql@$PGV-main; systemctl mask postgresql@$PGV-main >/dev/null 2>&1; systemctl enable patroni >/dev/null 2>&1; systemctl start patroni"
  for i in $(seq 1 60); do
    st=$(pctl "$PRIMARY" "list -f json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(m['Member']+'='+m['Role']+':'+m['State'] for m in d))")
    echo "$st" | grep -q "$REPLICA=Replica:streaming" && break
    sleep 3
  done
  echo "[+$(( $(date +%s) - T0 )) s] $st"
  pctl "$PRIMARY" "list"
}

status() {
  pctl "$PRIMARY" "list" || true
  echo "-- etcd"; ssh db1 "ETCDCTL_API=3 etcdctl --endpoints=$(etcd_eps | sed 's/\([0-9.]*:2379\)/http:\/\/\1/g') endpoint health 2>&1 | head -4"
  echo "-- replication slots on the leader"; pgq "$(pctl "$PRIMARY" 'list -f json' | python3 -c "import sys,json; print([m['Member'] for m in json.load(sys.stdin) if m['Role']=='Leader'][0])")" "select slot_name, active from pg_replication_slots" || true
}

notify() {
  # A message on the ntfy topic (the same one scripts/install-db-monitor.sh uses; its URL is read from the runner and never printed)
  # whenever a database changes role. Patroni calls the script on every role change.
  local h
  for h in "${HOSTS[@]}"; do
    ssh ci1 "sed -n 's/^NTFY_URL=//p' /etc/default/db-monitor" | ssh "$h" "umask 077; printf 'NTFY_URL=%s\n' \"\$(cat)\" > /etc/default/patroni-notify; chown postgres:postgres /etc/default/patroni-notify"
    ssh "$h" "cat > /usr/local/bin/patroni-notify && chmod 755 /usr/local/bin/patroni-notify" <<'NOTIFY'
#!/bin/sh
# Patroni callback (scripts/db-ha-patroni.sh notify): $1 = action, $2 = role, $3 = cluster. Tells the ntfy topic when this node changes role.
[ "$1" = on_role_change ] || exit 0
. /etc/default/patroni-notify 2>/dev/null || exit 0
curl -fsS -m 10 -H "Title: database role change" -H "Priority: high" -H "Tags: twisted_rightwards_arrows" \
  -d "$(hostname) is now $2 (cluster $3)" "$NTFY_URL" >/dev/null 2>&1 &
exit 0
NOTIFY
    ssh "$h" "python3 - <<'PY'
import yaml
p='$CFG'; d=yaml.safe_load(open(p))
d.setdefault('postgresql',{}).setdefault('callbacks',{})['on_role_change']='/usr/local/bin/patroni-notify'
open(p,'w').write(yaml.safe_dump(d, sort_keys=False))
PY
chown postgres:postgres $CFG; chmod 600 $CFG; systemctl kill --kill-whom=main -s HUP patroni; sleep 2; grep -A1 callbacks $CFG | tr '\n' ' '; echo"
  done
  echo "test: a manual message through the same path"; ssh "$PRIMARY" "sudo -u postgres /usr/local/bin/patroni-notify on_role_change test-run $SCOPE; echo sent"
}

rollback() {
  local h=${1:?host}
  echo "== rolling $h back to plain Postgres (this stops it for a moment)"
  ssh "$h" "systemctl stop patroni; systemctl disable patroni >/dev/null 2>&1; sudo -u postgres /usr/lib/postgresql/$PGV/bin/pg_ctl -D /var/lib/postgresql/$PGV/main stop -m fast 2>/dev/null || true
    systemctl unmask postgresql@$PGV-main >/dev/null 2>&1
    cp -a $BACKUP/etc-postgresql-main/postgresql.conf $CONF/postgresql.conf 2>/dev/null || cp -a $CONF/postgresql.base.conf $CONF/postgresql.conf
    echo 'standby.signal present: '\$(test -f /var/lib/postgresql/$PGV/main/standby.signal && echo yes || echo no)"
  echo "If $h was the PRIMARY: make sure standby.signal is absent (it is removed by promotion), then: ssh $h systemctl start postgresql@$PGV-main"
  echo "If $h was the REPLICA: rebuild it with scripts/db-replica-setup.sh (REBUILD=1) rather than trusting its data."
  echo "Also clear Patroni's keys when going back for good: ETCDCTL_API=3 etcdctl del --prefix $NS$SCOPE/"
}

case "${1:-}" in
  prepare) prepare ;;
  adopt-primary) adopt_primary ;;
  adopt-replica) adopt_replica ;;
  status) status ;;
  notify) notify ;;
  rollback) rollback "${2:-}" ;;
  *) sed -n 2,10p "$0"; exit 2 ;;
esac
