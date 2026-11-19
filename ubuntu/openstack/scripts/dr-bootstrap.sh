#!/bin/bash
# One-time steps after `terraform apply` of environments/dr (run from a machine that can ssh to both
# `rdu` (prod) and `dr`). Nothing secret is printed. Done once on 2026-11-19; kept so a rebuilt VM can be redone.
set -euo pipefail
DRIP=${1:?dr VM address}
PUB=$(ssh root@$DRIP 'cat /root/.ssh/dr-pull.pub')
# 1. read-only pull key on prod: five fixed read verbs, no shell, source-limited to this site's public address
SRC=$(ssh root@$DRIP 'curl -s4 -m5 ifconfig.me')
ssh rdu 'cp -p /root/.ssh/authorized_keys /root/.ssh/authorized_keys.bak-pre-dr-$(date +%s)'
echo "command=\"case \$SSH_ORIGINAL_COMMAND in dump) docker exec finance-db-1 sh -c 'pg_dump -U \$POSTGRES_USER -Fc \$POSTGRES_DB';; uploads) tar -C /var/lib/docker/volumes/finance_uploads/_data --numeric-owner -cf - .;; imageids) docker image inspect -f '{{.Id}}' backend:latest frontend:latest docs:latest nginx:alpine postgres:16-alpine;; image) docker save backend:latest frontend:latest docs:latest nginx:alpine postgres:16-alpine;; config) tar -C /opt/finance --numeric-owner -cf - docker-compose.yml nginx.conf;; *) echo denied >&2; exit 1;; esac\",restrict,from=\"$SRC\" $PUB" | ssh rdu 'cat >> /root/.ssh/authorized_keys'
# 2. prod's secrets -> the VM (never echoed)
ssh rdu 'cat /opt/finance/.env' | ssh root@$DRIP 'install -d -m 0700 /opt/finance; umask 277; cat > /opt/finance/.env.prod'
ssh rdu 'cat /opt/finance/.backup-key' | ssh root@$DRIP 'umask 077; cat > /opt/finance/.backup-key'
# 3. standby .env = prod values, but: no mail/alerts, plain http at dr.rdulinux.com (cookie not Secure)
ssh root@$DRIP 'cd /opt/finance
grep -v -E "^(EMAIL_ENABLED|ALERT_WEBHOOK|ALERT_EMAIL|COOKIE_SECURE|APP_BASE_URL|CORS_ORIGINS)=" .env.prod > .env.tmp
printf "EMAIL_ENABLED=false\nALERT_WEBHOOK=\nALERT_EMAIL=\nCOOKIE_SECURE=0\nAPP_BASE_URL=http://dr.rdulinux.com\nCORS_ORIGINS=http://dr.rdulinux.com\n" >> .env.tmp
install -m 0400 .env.tmp .env; rm .env.tmp
systemctl start finance-dr-pull.service && systemctl enable --now finance-dr-pull.timer'
