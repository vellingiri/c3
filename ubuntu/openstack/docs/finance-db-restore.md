# Finance database: backups and a verified restore

Backups: the `db-backup-hourly` / `db-backup-daily` CronJobs (finance namespace) write
`finance-*.sql.gz` (plain SQL) to the NFS share `repo:/exports/finance-qa/backups/finance/{hourly,daily,weekly,manual}`
(24 hourly, 7 daily, 4 weekly kept). The database itself runs on `db1` (PostgreSQL 16) with a streaming replica on `db2`; see `db-replication.md`. `ssh db` follows the DNS alias
`db.rdulinux.com`, i.e. the current primary, which is where the restore tests below must run (a replica is read only).

## Fixed: dumps now restore with plain psql (2026-10-20)
The backup job used to run a PostgreSQL 17 `pg_dump` against the 16 server, so every dump contained
`SET transaction_timeout = 0;` and a plain `psql -v ON_ERROR_STOP=1` restore stopped on line 13. The backend image now
installs the 16 client (`ARG PG_CLIENT_MAJOR=16` in the finance repo's `app/backend/Dockerfile`), so dumps are written by
`pg_dump` 16.15 and have no such line. Verified on the 03:30 IST dump of 2026-10-20: plain restore, exit 0, 85/85 tables,
114,669 rows identical to the live database.

**Older dumps** (written before 2026-10-20 ~01:00 IST, header `Dumped by pg_dump version 17.x`) still need the line removed:
```bash
zcat dump.sql.gz | sed '/^SET transaction_timeout/d' | psql -v ON_ERROR_STOP=1 -d <target-db>
```
Keep `PG_CLIENT_MAJOR` equal to the server's major version; change them together.

## Verified restore test (2026-10-19)
Fresh dump `finance-20261019_170719.sql.gz` (939 KB) restored into a scratch database on `db`:
85 of 85 tables, **97,304 rows, every table's row count identical to the live database**. Scratch DB dropped afterwards.
The dump has no `\connect` / `CREATE DATABASE` lines, so it can only restore into the database you point psql at.

Procedure used (the `db` VM has no NFS mount, so the dump is streamed in; nothing is stored elsewhere):
```bash
DUMP=/exports/finance-qa/backups/finance/hourly/<file>.sql.gz
ssh db 'sudo install -d -m 700 -o postgres /var/tmp/restore-test; sudo -u postgres createdb restore_test'
ssh repo "cat $DUMP" | ssh db 'sudo -u postgres tee /var/tmp/restore-test/dump.sql.gz >/dev/null'
ssh db 'sudo -u postgres bash -c "zcat /var/tmp/restore-test/dump.sql.gz | sed \"/^SET transaction_timeout/d\" | psql -q -v ON_ERROR_STOP=1 -d restore_test"'
# compare per-table counts against financedb, then ALWAYS clean up:
ssh db 'sudo -u postgres dropdb restore_test; sudo rm -rf /var/tmp/restore-test'
```

## Restoring for real (sketch, NOT yet rehearsed on the live database)
Stop writers first (`kubectl -n finance scale deploy/backend --replicas=0`), restore into a new database, check counts,
then swap names (or restore over `financedb` after dropping it), and scale the backend back up.

## Data that is not in the database
`repo:/exports/finance-qa/{uploads,logs,backups}` (NFS, single copy). A tarball safety copy of `uploads` and `backups`
was taken before the 2026-10-19 prod rebuild: `backup:/backup/finance-qa/pre-rebuild-20261019/` (root only).
