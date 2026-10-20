#!/usr/bin/env bash
# Check the Postgres pair: exactly one writable primary, a streaming replica, small lag, no runaway replication slot.
# Notifies through ntfy when the answer CHANGES (ok -> problem, problem changes, problem -> ok) and reminds every 6 h while broken.
#
# Runs on the runner VM every 2 minutes (systemd timer, installed by scripts/install-db-monitor.sh).
# Config: /etc/default/db-monitor   (DB_HOSTS, PGUSER, PGPASSWORD, NTFY_URL, LAG_BYTES, SLOT_BYTES, REMIND_SECONDS)
#   db-replication-monitor.sh            normal run; exit 0 healthy, 1 problem
#   db-replication-monitor.sh --dry-run  print only; no notification, no state change
#   db-replication-monitor.sh --test     send one test notification and exit
set -uo pipefail

CONFIG=${DB_MONITOR_CONFIG:-/etc/default/db-monitor}
# shellcheck disable=SC1090
[ -r "$CONFIG" ] && . "$CONFIG"
: "${DB_HOSTS:=db1=10.0.1.191 db2=10.0.1.69}"      # name=private-ip pairs; the app uses private IPs too
: "${PGUSER:=monitor}"
: "${LAG_BYTES:=16777216}"                          # 16 MB of WAL not yet replayed
: "${SLOT_BYTES:=1610612736}"                       # slot keeps 1.5 GB (the cap is 2 GB, then the replica must be rebuilt)
: "${REMIND_SECONDS:=21600}"
: "${WITNESS:=db-witness=10.0.1.120}"                   # name=ip of the etcd tie-breaker VM
: "${PATRONI_PORT:=8008}"
: "${STATE_FILE:=/var/lib/db-monitor/state}"
: "${NTFY_URL:=}"
export PGUSER PGPASSWORD PGCONNECT_TIMEOUT=5

MODE=run
case "${1:-}" in --dry-run) MODE=dry ;; --test) MODE=test ;; "") ;; *) echo "unknown option $1" >&2; exit 2 ;; esac

notify() {   # title priority tags message
  [ -n "$NTFY_URL" ] || { echo "(no NTFY_URL set; not sending: $1)"; return 0; }
  curl -fsS -m 10 -H "Title: $1" -H "Priority: $2" -H "Tags: $3" -d "$4" "$NTFY_URL" >/dev/null || echo "ntfy send failed" >&2
}

if [ "$MODE" = test ]; then
  notify "TEST: db replication monitor" default "white_check_mark" "This is a test from $(hostname). Real alerts look like this."
  echo "test notification sent"; exit 0
fi

q() { psql -X -qAt -h "$1" -d postgres -c "$2" 2>/dev/null; }

problems=(); primaries=(); replicas=(); summary=()
for pair in $DB_HOSTS; do
  name=${pair%%=*}; ip=${pair#*=}
  if ! rec=$(q "$ip" "select pg_is_in_recovery()") || [ -z "$rec" ]; then
    problems+=("$name ($ip) is unreachable or refused the monitor login"); summary+=("$name unreachable"); continue
  fi
  if [ "$rec" = f ]; then primaries+=("$name=$ip"); summary+=("$name primary"); else replicas+=("$name=$ip"); summary+=("$name replica"); fi
done

if [ ${#primaries[@]} -gt 1 ]; then problems+=("TWO writable primaries (${primaries[*]%%=*}): split brain, stop one now")
elif [ ${#primaries[@]} -eq 0 ]; then problems+=("no writable primary: the database is read only or down"); fi

if [ ${#primaries[@]} -eq 1 ]; then
  pname=${primaries[0]%%=*}; pip=${primaries[0]#*=}
  n=$(q "$pip" "select count(*) from pg_stat_replication where state = 'streaming'" || echo 0)
  [ "${n:-0}" -ge 1 ] || problems+=("primary $pname has no streaming replica (redundancy lost)")
  lag=$(q "$pip" "select coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), 0)::bigint from pg_stat_replication" || echo 0)
  [ "${lag:-0}" -le "$LAG_BYTES" ] || problems+=("replica is $((lag / 1048576)) MB behind $pname")
  summary+=("lag ${lag:-?} bytes")
  inactive=$(q "$pip" "select string_agg(slot_name, ',') from pg_replication_slots where slot_type = 'physical' and not active")
  [ -z "$inactive" ] || problems+=("replication slot(s) inactive on $pname: $inactive (WAL is piling up)")
  big=$(q "$pip" "select string_agg(slot_name || ' ' || pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)), ',') from pg_replication_slots where pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > $SLOT_BYTES")
  [ -z "$big" ] || problems+=("slot holding too much WAL on $pname: $big")
fi
for r in "${replicas[@]:-}"; do
  [ -n "$r" ] || continue
  rname=${r%%=*}; rip=${r#*=}
  st=$(q "$rip" "select coalesce((select status from pg_stat_wal_receiver), 'none')")
  [ "$st" = streaming ] || problems+=("replica $rname receiver status is '${st:-unknown}', not streaming")
done

# --- Patroni (automatic failover): each node's own view, the cluster view, and the witness VM -------------------------------------------
# Needs the private subnet (Patroni's REST port is firewalled to 10.0.1.0/24).
cluster_json=""
for pair in $DB_HOSTS; do
  name=${pair%%=*}; ip=${pair#*=}
  pj=$(curl -s -m 5 "http://$ip:$PATRONI_PORT/patroni" 2>/dev/null)
  if [ -z "$pj" ]; then problems+=("Patroni on $name is not answering: automatic failover is not protecting the database"); continue; fi
  msg=$(echo "$pj" | python3 -c '
import sys, json, time
d = json.load(sys.stdin)
out = []
if d.get("state") not in ("running", "streaming"): out.append("state is %s" % d.get("state"))
seen = d.get("dcs_last_seen")
if seen and time.time() - seen > 60: out.append("has not reached etcd for %d s" % (time.time() - seen))
if d.get("pause"): out.append("Patroni is PAUSED, there is no automatic failover")
if d.get("pending_restart"): out.append("has a pending restart")
print("; ".join(out))' 2>/dev/null)
  [ -z "$msg" ] || problems+=("Patroni on $name: $msg")
  [ -n "$cluster_json" ] || cluster_json=$(curl -s -m 5 "http://$ip:$PATRONI_PORT/cluster" 2>/dev/null)
done
if [ -n "$cluster_json" ]; then
  want=$(echo $DB_HOSTS | wc -w)
  cmsg=$(echo "$cluster_json" | python3 -c '
import sys, json
want, lag_limit = int(sys.argv[1]), int(sys.argv[2])
m = json.load(sys.stdin).get("members", [])
out = []
leaders = [x["name"] for x in m if x.get("role") in ("leader", "master")]
if len(leaders) != 1: out.append("Patroni sees %d leaders (%s)" % (len(leaders), ",".join(leaders) or "none"))
if len(m) != want: out.append("Patroni sees %d of %d members" % (len(m), want))
for x in m:
    if x.get("state") not in ("running", "streaming"): out.append("%s is %s" % (x["name"], x.get("state")))
    lag = x.get("lag")
    if isinstance(lag, int) and lag > lag_limit: out.append("%s is %d MB behind" % (x["name"], lag // 1048576))
print("; ".join(out))' "$want" "$LAG_BYTES" 2>/dev/null)
  [ -z "$cmsg" ] || problems+=("Patroni cluster: $cmsg")
fi
wname=${WITNESS%%=*}; wip=${WITNESS#*=}
timeout 4 bash -c "echo > /dev/tcp/$wip/22" 2>/dev/null || problems+=("the witness VM $wname ($wip) is not answering: if one more machine fails there is no quorum and no automatic failover")
line=$(IFS=,; echo "${summary[*]}"); line=${line//,/, }   # "db1 primary, db2 replica, lag 0 bytes"
echo "$(date -Is) $line"
for p in "${problems[@]:-}"; do [ -n "$p" ] && echo "PROBLEM: $p"; done
[ "$MODE" = dry ] && { [ ${#problems[@]} -eq 0 ]; exit $?; }

mkdir -p "$(dirname "$STATE_FILE")"
prev=$(cat "$STATE_FILE" 2>/dev/null || echo ok)
now=$(date +%s)
if [ ${#problems[@]} -eq 0 ]; then
  if [ "${prev%% *}" = fail ]; then notify "db replication recovered" default "white_check_mark" "$line"; fi
  echo ok > "$STATE_FILE"; exit 0
fi

sig=$(printf '%s\n' "${problems[@]}" | cksum | cut -d' ' -f1)
body=$(printf '%s\n' "${problems[@]}"; echo "$line")
if [ "${prev%% *}" != fail ] || [ "$(echo "$prev" | cut -d' ' -f2)" != "$sig" ]; then
  notify "db replication PROBLEM" urgent "rotating_light" "$body"; echo "fail $sig $now" > "$STATE_FILE"
elif [ $((now - $(echo "$prev" | cut -d' ' -f3))) -ge "$REMIND_SECONDS" ]; then
  notify "db replication still broken" high "warning" "$body"; echo "fail $sig $now" > "$STATE_FILE"
fi
exit 1
