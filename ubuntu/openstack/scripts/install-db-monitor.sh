#!/usr/bin/env bash
# Install the database replication monitor on the runner VM (run from your Mac; re-runnable).
#   scripts/install-db-monitor.sh [runner-host]                 default: runner
#   NTFY_TOPIC=my-topic scripts/install-db-monitor.sh           use a topic you already subscribed to
#
# What it does: creates the read-only login role `monitor` (pg_monitor) on whichever DB is primary
# (it replicates to the other), lets 10.0.1.0/24 use it on BOTH hosts, installs postgresql-client and curl on
# the runner, installs the script plus a systemd timer (every 2 minutes), and writes /etc/default/db-monitor
# (mode 0600) with the password and the ntfy topic. A new password is generated on every run and never printed.
# The ntfy topic IS printed once at the end: subscribe to https://ntfy.sh/<topic> (anyone who knows it can read or post).
set -euo pipefail

RUNNER=${1:-runner}
DB_HOSTS=("db1" "db2")
HERE="$(cd "$(dirname "$0")" && pwd)"
CONF=/etc/postgresql/16/main

# 1. role on the primary
PRIMARY=""
for h in "${DB_HOSTS[@]}"; do
  [ "$(ssh "$h" "sudo -u postgres psql -qAt -c 'select pg_is_in_recovery()'")" = f ] && PRIMARY=$h
done
[ -n "$PRIMARY" ] || { echo "no writable primary found" >&2; exit 1; }
PW=$(openssl rand -hex 24)
ssh "$PRIMARY" "sudo -u postgres psql -X -qAt -v ON_ERROR_STOP=1" <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitor') THEN CREATE ROLE monitor LOGIN; END IF;
END \$\$;
ALTER ROLE monitor PASSWORD '$PW';
GRANT pg_monitor TO monitor;
SQL
echo "role monitor ready on $PRIMARY"

# 2. access rule on both hosts (only the postgres database, only this role)
HBA='host postgres monitor 10.0.1.0/24 scram-sha-256'
for h in "${DB_HOSTS[@]}"; do
  ssh "$h" "grep -qxF '$HBA' $CONF/pg_hba.conf || echo '$HBA' | sudo tee -a $CONF/pg_hba.conf >/dev/null; sudo -u postgres psql -qAt -c 'select pg_reload_conf()' >/dev/null"
done

# 3. runner: tools, script, units, config
scp -q "$HERE/db-replication-monitor.sh" "root@$RUNNER:/tmp/db-replication-monitor.sh"
# The password and topic go through stdin (first two lines), never on a command line.
{ printf '%s\n%s\n' "$PW" "${NTFY_TOPIC:-}"; cat <<'REMOTE'
set -euo pipefail
command -v psql >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client curl; }
install -m 0755 /tmp/db-replication-monitor.sh /usr/local/sbin/db-replication-monitor
rm -f /tmp/db-replication-monitor.sh
CFG=/etc/default/db-monitor
TOPIC=$NTFY_TOPIC
[ -n "$TOPIC" ] || TOPIC=$(sed -n 's#^NTFY_URL=https://ntfy.sh/##p' "$CFG" 2>/dev/null || true)
[ -n "$TOPIC" ] || TOPIC="rdulinux-db-$(openssl rand -hex 8)"
umask 077
cat > "$CFG" <<EOF
# written by scripts/install-db-monitor.sh; defaults for everything else are in /usr/local/sbin/db-replication-monitor
PGUSER=monitor
PGPASSWORD=$NEW_PW
NTFY_URL=https://ntfy.sh/$TOPIC
EOF
chmod 600 "$CFG"
cat > /etc/systemd/system/db-monitor.service <<'EOF'
[Unit]
Description=Check the Postgres primary/replica pair and alert on changes
After=network-online.target

[Service]
Type=oneshot
StateDirectory=db-monitor
ExecStart=/usr/local/sbin/db-replication-monitor
EOF
cat > /etc/systemd/system/db-monitor.timer <<'EOF'
[Unit]
Description=Run the database replication check every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now db-monitor.timer >/dev/null
echo "TOPIC=$TOPIC"
REMOTE
} | ssh "root@$RUNNER" 'read -r NEW_PW; read -r NTFY_TOPIC; export NEW_PW NTFY_TOPIC; bash -s'
echo
echo "First run:"
ssh "root@$RUNNER" "/usr/local/sbin/db-replication-monitor --dry-run"
