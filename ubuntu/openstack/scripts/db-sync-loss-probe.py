# Data-loss probe for the database pair (docs/db-ha-patroni.md, "Synchronous replication"). Run INSIDE a backend pod:
#   kubectl -n finance exec -i deploy/backend -- env PROBE_SECONDS=120 python - < scripts/db-sync-loss-probe.py > /tmp/probe.log
# Inserts numbered rows one commit at a time into the scratch table zz_synctest and prints "ACK <id>" for every commit the database
# acknowledged. After a failover compare the highest ACK in the log with `select max(id) from zz_synctest` on the NEW primary:
# with synchronous replication they must be equal (no acknowledged write lost). Reconnects through every host of DATABASE_URL.
import asyncio, os, sys, time
sys.path.insert(0, "/app")
import db_connect

async def main():
    url = os.environ["DATABASE_URL"]
    seconds = int(os.environ.get("PROBE_SECONDS", "120"))
    end = time.time() + seconds
    conn = None
    nxt = 1
    while time.time() < end:
        try:
            if conn is None:
                conn = await db_connect.connect_any(url, command_timeout=15)
                await conn.execute("select set_config('app.family_id', '2', false)")   # the app's tables get a family_id column (FK to families) filled from this setting; 2 exists
                await conn.execute("create table if not exists zz_synctest (id bigint primary key, ts timestamptz default now())")
                row = await conn.fetchrow("select coalesce(max(id),0)+1 as n from zz_synctest")
                nxt = max(nxt, row["n"])
            await conn.execute("insert into zz_synctest (id) values ($1)", nxt)
            print(f"ACK {nxt} {time.time():.2f}", flush=True)
            nxt += 1
            await asyncio.sleep(0.02)
        except Exception as exc:
            print(f"ERR {type(exc).__name__} at next={nxt} {time.time():.2f}", flush=True)
            try:
                if conn: conn.terminate()      # not close(): on a dead socket close() waits forever
            except Exception:
                pass
            conn = None
            await asyncio.sleep(1)
    print("DONE", flush=True)

asyncio.run(main())
