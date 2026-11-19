# DR replica: `dr` (http://dr.rdulinux.com)

Warm standby of production (rdu, 13.140.58.46: docker compose in /opt/finance). One VM `dr` on c3's OpenStack
(192.168.2.80, 2 vCPU / 4 GB / 20 GB), plain http on port 80 (Apache -> nginx 127.0.0.1:8080), no TLS.

| | |
|---|---|
| Data | `finance-dr-pull.timer`, hourly at :17. Pulls config, images (when changed), pg_dump and uploads from rdu over ssh. Last good sync: `/var/lib/finance-dr/last-sync` |
| Prod side | one key line in rdu's `/root/.ssh/authorized_keys`: `restrict`, `from=<this site's public IP>`, forced command with five read verbs (config, imageids, image, dump, uploads). Backup: `authorized_keys.bak-pre-dr*` |
| Standby `.env` | prod's values except EMAIL_ENABLED=false, ALERT_WEBHOOK/ALERT_EMAIL empty, COOKIE_SECURE=0, APP_BASE_URL and CORS_ORIGINS = http://dr.rdulinux.com. Prod's untouched copy: `/opt/finance/.env.prod` |
| Rebuild | terraform apply in environments/dr (c3 tree), then `dr-bootstrap.sh <dr-ip>` |

## Failover (a person runs it; nothing promotes automatically)
1. `ssh root@dr finance-dr-promote` stops the timer, makes a last pull if rdu answers (otherwise uses the last good copy), restores `.env.prod` and recreates the stack.
2. Point whatever name users use at 192.168.2.80 (DNS or LB). Note `.env.prod` has COOKIE_SECURE unset (= Secure cookies): over plain http, set `COOKIE_SECURE=0` in `/opt/finance/.env` and `docker compose up -d backend`, or put TLS in front.
3. Do not re-enable the timer afterwards: it would overwrite the DR copy with prod's data. Reverse the direction first.
