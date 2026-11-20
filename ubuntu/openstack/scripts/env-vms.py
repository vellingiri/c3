#!/usr/bin/env python3
"""Shut down, start, or show every VM of ONE environment (prod, cka, qa) in a safe order, for maintenance windows.

    scripts/env-vms.py prod status
    scripts/env-vms.py prod stop  [--lbs] [--dry-run] [--confirm]
    scripts/env-vms.py prod start [--all] [--lbs] [--dry-run] [--no-cleanup]

    scripts/env-vms.py prod status worker1            one or more named servers instead of the whole environment
    scripts/env-vms.py prod start  worker1 worker2    starts exactly those (if SHUTOFF), whatever the last `stop` saved
    scripts/env-vms.py prod stop   worker3            stops exactly that one

Run it from your Mac. It reaches OpenStack through `ssh c3` (the admin credentials are in /root/.bashrc there) and the cluster/database
through your usual kubeconfig (~/.kube/<env>, context <env>) and ssh names (db1 ...). Nothing is installed anywhere.

Which VMs: those whose Nova metadata says env=<env> (Terraform sets `env` and `role` on every node). The DR replica `finance` (env=prod, role=app) is
started in the LAST tier by `start`; a plain `stop` leaves it running (stop it by name: `prod stop finance`). The Octavia amphorae (the load balancers) carry no
env, so by default they are not touched: the load balancers stay up and only mark their members down while the VMs are off. With `--lbs` the amphorae of
the environment's load balancers (prod: finance-lb, argo-lb, prod-api; cka: cka-api) are stopped LAST and started FIRST, and the Octavia health manager is
stopped before the first amphora goes down (it rebuilds an amphora that is silent for 5 minutes) and started again after they are back.

Order (graceful stop: an ACPI shutdown, then Nova forces it after its own timeout; the kubelet's graceful-shutdown setting stops the pods first):
    stop :  runner  ->  workers  ->  control planes  ->  databases (the standby first, the leader last)  ->  witness
    start:  the exact reverse: witness -> database leader -> standby -> control planes -> workers -> runner
Between tiers it waits (all VMs of the tier SHUTOFF / ACTIVE). While starting it also waits for what the next tier needs: a Patroni leader
before the control planes, the API server before the workers, every node Ready at the end; then it clears the leftover Error pod records a
graceful shutdown leaves and prints the checks (nodes, Patroni, the finance front door for prod).

`stop` remembers what it stopped in ~/.cache/c3-env-vms/<env>.json, so `start` brings back exactly those VMs and not one that was off on
purpose. Without that file, `start --all` starts every VM of the environment that is SHUTOFF.
`--dry-run` shows the plan and changes nothing. `stop` does NOT ask for confirmation (use `--dry-run` to look first, or `--confirm` to be asked).
With server names, only those VMs are touched (names as `status` prints them, including an amphora-... name); an unknown name stops the script before
anything happens. They still go in the safe order among themselves, an individual `stop` adds to the saved list rather than replacing it, and an
individual `start` waits only for the nodes that are meant to be up, not for ones you left off. Naming a server needs no --all and no earlier `stop`.
Starting the VMs needs no Terraform: this is the OpenStack API directly (a later `terraform apply` simply sees them active).
"""
import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import time

C3 = os.environ.get("C3_HOST", "c3")
STATE_DIR = os.environ.get("ENV_VMS_STATE", os.path.expanduser("~/.cache/c3-env-vms"))
STOP_TIER_TIMEOUT = 360     # seconds to wait for one tier to reach SHUTOFF (Nova forces the power-off itself after its own timeout)
START_TIER_TIMEOUT = 300
FRONT_DOOR = {"prod": "http://qa.rdulinux.com/health"}

# stop order: smaller first. Start is the reverse.
# Roles that are never stopped or started by this script, even though they carry env=<env>. The S3 server (s3) is the Terraform state store: while it
# is off, no `terraform plan` or `apply` in any stack can read or write its state, and the tfstate backups have nothing to copy.
NEVER_STOP_ROLES = {"objstore"}
# Roles that a plain `stop` (no server named) leaves running: the DR replica `finance` (env=prod, role=app, its own Terraform stack environments/dr) is started
# with prod (last tier) but is not part of a prod maintenance stop. Stop it by name: `prod stop finance`.
SPARE_ON_PLAIN_STOP_ROLES = {"app"}
RANK = {"mgmt": 1, "runner": 1, "app": 1, "worker": 2, "controller": 3, "controller_join": 3, "database": 4, "witness": 5, "amphora": 6}
RANK_NAME = {1: "runner / management (rancher) / DR replica (finance)", 2: "workers", 3: "control planes", 4: "databases", 5: "witness", 6: "load balancers (amphorae)"}
# The Octavia load balancers that belong to each environment (their amphorae are the VMs `--lbs` stops and starts). Override: ENV_LBS="prod=finance-lb,argo-lb,prod-api;cka=cka-api"
ENV_LBS = {"prod": ["finance-lb", "argo-lb", "prod-api"], "cka": ["cka-api"]}
if os.environ.get("ENV_LBS"):
    ENV_LBS = {k: v.split(",") for k, v in (x.split("=", 1) for x in os.environ["ENV_LBS"].split(";") if "=" in x)}
LB_SETTLE = int(os.environ.get("LB_SETTLE", "90"))   # seconds the amphorae get to boot and send heartbeats before the health manager is started again
INCLUDE_LBS_FLAG = False
INCLUDE_LBS = False                                  # set in main(): the amphorae are listed with the VMs of the environment when this is on


def say(msg=""):
    print(msg, flush=True)


def die(msg):
    print("STOP: " + msg, file=sys.stderr)
    sys.exit(1)


def run(cmd, timeout=180):
    """Run a command with no stdin (an ssh must never read from ours); return (rc, stdout)."""
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, ""
    return p.returncode, p.stdout


def openstack(*args, timeout=180):
    remote = "source /root/.bashrc >/dev/null 2>&1; openstack " + " ".join(shlex.quote(a) for a in args) + " 2>/dev/null"
    rc, out = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", C3, remote], timeout)
    return rc, out


def parse_props(p):
    if isinstance(p, dict):
        return p
    return {k: v for k, v in re.findall(r"([\w.-]+)='([^']*)'", p or "")}


def list_vms(env):
    rc, out = openstack("server", "list", "--long", "-f", "json", "-c", "ID", "-c", "Name", "-c", "Status", "-c", "Properties")
    if rc != 0:
        die("could not list servers through ssh %s (is c3 up? ssh %s works?)" % (C3, C3))
    try:
        data = json.loads(out)
    except ValueError:
        die("unexpected answer from OpenStack: " + out[:200])
    vms = []
    for v in data:
        props = parse_props(v.get("Properties"))
        if props.get("env") != env:
            continue
        role = props.get("role", "")
        if role in NEVER_STOP_ROLES:
            continue
        rank = RANK.get(role) or guess_rank(v["Name"])
        vms.append({"id": v["ID"], "name": v["Name"], "status": v["Status"], "role": role, "rank": rank, "sub": 0, "props": props})
    if INCLUDE_LBS:
        vms.extend(list_amphorae(env))
    return vms


def list_amphorae(env):
    """The amphora VMs of this environment's load balancers: server `amphora-<amphora id>` ↔ `openstack loadbalancer amphora list` ↔ the LB name."""
    wanted = ENV_LBS.get(env, [])
    if not wanted:
        return []
    remote = ("source /root/.bashrc >/dev/null 2>&1; (openstack server list --all-projects --long -f json -c ID -c Name -c Status -c Properties 2>/dev/null;"
              " echo '@@'; openstack loadbalancer amphora list -f json 2>/dev/null; echo '@@'; openstack loadbalancer list -f json 2>/dev/null)")
    rc, out = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", C3, remote], 240)
    parts = out.split("@@")
    if rc != 0 or len(parts) != 3:
        die("could not list the load balancer VMs through ssh %s" % C3)
    try:
        servers, amps, lbs = (json.loads(x) for x in parts)
    except ValueError:
        die("unexpected answer while listing the load balancer VMs")
    lb_name = {l.get("id") or l.get("ID"): l.get("name") or l.get("Name") for l in lbs}
    amp_lb = {(a.get("id") or a.get("ID")): lb_name.get(a.get("loadbalancer_id") or a.get("Loadbalancer_id")) for a in amps}
    out_vms = []
    for sv in servers:
        if not sv["Name"].startswith("amphora-"):
            continue
        lb = amp_lb.get(sv["Name"][len("amphora-"):])
        if lb in wanted:
            out_vms.append({"id": sv["ID"], "name": sv["Name"], "status": sv["Status"], "role": "amphora", "rank": 6, "sub": 0,
                            "props": parse_props(sv.get("Properties")), "lb": lb})
    return out_vms


def health_manager(action):
    """start | stop | is-active the Octavia health manager on c3. While it runs it rebuilds any amphora silent for heartbeat_timeout (300 s)."""
    rc, out = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", C3, "systemctl %s octavia-health-manager" % action], 90)
    return rc, out.strip()


def lb_summary(env):
    rc, out = openstack("loadbalancer", "list", "-f", "json", "-c", "name", "-c", "operating_status", "-c", "provisioning_status")
    try:
        return ", ".join("%s %s/%s" % (l["name"], l.get("provisioning_status"), l.get("operating_status"))
                         for l in json.loads(out) if l["name"] in ENV_LBS.get(env, []))
    except ValueError:
        return "unknown"


def guess_rank(name):
    if re.match(r"^(ci|runner|rancher)", name):
        return 1
    if re.match(r"^dbw", name):
        return 5
    if re.match(r"^db", name):
        return 4
    if re.match(r"^(c\d|controller)", name):
        return 3
    return 2


def statuses(env):
    return {v["id"]: v["status"] for v in list_vms(env)}


def pick(vms, args, env):
    """Narrow the environment's VMs to the servers named on the command line (all of them when none are named)."""
    names = list(dict.fromkeys(getattr(args, "servers", None) or []))
    if not names:
        return vms
    have = {v["name"]: v for v in vms}
    unknown = [n for n in names if n not in have]
    if unknown:
        die("not a VM of %s: %s. Its VMs are: %s" % (env, " ".join(unknown), " ".join(sorted(have))))
    return [have[n] for n in names]


def wait_status(env, ids, want, timeout):
    """Wait until every id has status `want` ; return the ids that did not make it."""
    end = time.time() + timeout
    pending = set(ids)
    while pending and time.time() < end:
        now = statuses(env)
        pending = {i for i in pending if now.get(i) != want}
        if pending:
            time.sleep(6)
    return pending


# ---- cluster and database checks ------------------------------------------------------------------------------------
def kubectl(env, *args, timeout=60):
    kc = os.path.expanduser("~/.kube/%s" % env)
    return run(["kubectl", "--kubeconfig", kc, "--context", env] + list(args), timeout)


def patroni(vms):
    """Return the Patroni member list from the first database VM that answers, or None."""
    for v in vms:
        if v["rank"] != 4:
            continue
        rc, out = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", v["name"],
                       "patronictl -c /etc/patroni/config.yml list -f json"], 40)
        if rc == 0:
            try:
                return json.loads(out)
            except ValueError:
                pass
    return None


def member_of(vm_name):
    return vm_name.split("-")[0]


def mark_database_order(vms):
    """The Patroni leader is stopped LAST of the databases and started FIRST (sub=1); the standby is the other way round (sub=0)."""
    members = patroni([v for v in vms if v["status"] == "ACTIVE"])
    leader = None
    for m in members or []:
        if m.get("Role") in ("Leader", "leader"):
            leader = m.get("Member")
    for v in vms:
        if v["rank"] == 4 and leader and member_of(v["name"]) == leader:
            v["sub"] = 1
    return leader


def wait_patroni_leader(vms, timeout=240):
    end = time.time() + timeout
    while time.time() < end:
        members = patroni(vms)
        if members and any(m.get("Role") in ("Leader", "leader") and m.get("State") in ("running", "streaming") for m in members):
            return True
        time.sleep(8)
    return False


def wait_api(env, timeout=360):
    end = time.time() + timeout
    while time.time() < end:
        rc, out = kubectl(env, "get", "--raw", "/livez", timeout=20)
        if rc == 0 and out.strip() == "ok":
            return True
        time.sleep(8)
    return False


def nodes_ready(env):
    for attempt in range(3):          # one failed call is not "the API is down" (a load balancer or kubectl hiccup)
        rc, out = kubectl(env, "get", "nodes", "--no-headers")
        if rc == 0:
            break
        time.sleep(3)
    else:
        return None
    lines = [l.split() for l in out.strip().splitlines() if l.strip()]
    return sum(1 for l in lines if l[1].startswith("Ready")), len(lines)


def wait_nodes(env, want, timeout=360):
    end = time.time() + timeout
    while time.time() < end:
        r = nodes_ready(env)
        if r and r[0] >= want:
            return True
        time.sleep(8)
    return False


# ---- state file -----------------------------------------------------------------------------------------------------
def state_path(env):
    return os.path.join(STATE_DIR, env + ".json")


def load_state(env):
    try:
        with open(state_path(env)) as f:
            return json.load(f)
    except (IOError, ValueError):
        return None


def save_state(env, vms):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    old = load_state(env) or {"vms": []}
    merged = {v["id"]: v for v in old.get("vms", [])}     # VMs from an earlier stop that are still off must come back too
    for v in vms:
        merged[v["id"]] = {k: v[k] for k in ("id", "name", "role", "rank", "sub")}
    with open(state_path(env), "w") as f:
        json.dump({"env": env, "stopped_at": datetime.datetime.now().isoformat(timespec="seconds"), "vms": list(merged.values())}, f, indent=1)
    os.chmod(state_path(env), 0o600)


def mark_stopped(vms):
    """Also record the stop in the VMs' own Nova metadata, so `start` works from any machine, not only the one that ran `stop`."""
    stamp = datetime.datetime.now().isoformat(timespec="seconds")
    for v in vms:
        openstack("server", "set", "--property", "maint_stopped=" + stamp, "--property", "maint_sub=%d" % v["sub"], v["id"])


def unmark_stopped(vms):
    for v in vms:
        openstack("server", "unset", "--property", "maint_stopped", "--property", "maint_sub", v["id"])


# ---- commands -------------------------------------------------------------------------------------------------------
def tiers(vms, reverse):
    keys = sorted({(v["rank"], v["sub"]) for v in vms}, reverse=reverse)
    return [(k, sorted([v for v in vms if (v["rank"], v["sub"]) == k], key=lambda x: x["name"])) for k in keys]


def show_plan(title, vms, reverse):
    say(title)
    for i, ((rank, sub), group) in enumerate(tiers(vms, reverse), 1):
        label = RANK_NAME.get(rank, "other")
        if rank == 4:
            label += " (leader)" if sub == 1 else " (standby)"
        say("  %d. %-22s %s" % (i, label, " ".join(v["name"] for v in group)))


def cmd_status(env, args):
    vms = pick(list_vms(env), args, env)
    if not vms:
        say("no VMs with env=%s" % env)
        return
    say("VMs of %s%s:" % (env, " (selected)" if args.servers else ""))
    for v in sorted(vms, key=lambda x: (x["rank"], x["name"])):
        say("  %-12s %-9s %s" % (v["name"], v["status"], v["role"]))
    st = load_state(env)
    if st:
        say("\nsaved by the last stop (%s): %s" % (st.get("stopped_at"), " ".join(sorted(v["name"] for v in st["vms"]))))
    if any(v["status"] == "ACTIVE" and v["role"] in ("controller", "controller_join") for v in vms):
        r = nodes_ready(env)
        say("\nKubernetes nodes Ready: %s" % ("%d of %d" % r if r else "API not answering"))
    members = patroni([v for v in vms if v["status"] == "ACTIVE"])
    if members:
        say("Patroni: " + ", ".join("%s %s" % (m.get("Member"), m.get("Role")) for m in members))
    if ENV_LBS.get(env):
        say("load balancers: " + lb_summary(env))
        say("Octavia health manager: %s" % (health_manager("is-active")[1] or "unknown"))


def cmd_stop(env, args):
    vms = pick(list_vms(env), args, env)
    if not vms:
        die("no VMs with env=%s found" % env)
    if not args.servers:
        spared = [v["name"] for v in vms if v["role"] in SPARE_ON_PLAIN_STOP_ROLES and v["status"] == "ACTIVE"]
        vms = [v for v in vms if v["role"] not in SPARE_ON_PLAIN_STOP_ROLES]
        if spared:
            say("left running on purpose (DR replica; stop it by name): " + " ".join(spared))
    running = [v for v in vms if v["status"] == "ACTIVE"]
    other = [v for v in vms if v["status"] != "ACTIVE"]
    if other:
        say("not running already (left as they are): " + " ".join("%s=%s" % (v["name"], v["status"]) for v in other))
    if not running:
        say("nothing to stop")
        return
    leader = mark_database_order(running)
    if any(v["rank"] == 4 for v in running):
        say("Patroni leader: %s (stopped last of the databases)" % (leader or "unknown (stopped in name order)"))
    show_plan("Stop plan for %s (%d VMs):" % (env, len(running)), running, reverse=False)
    if any(v["rank"] == 6 for v in running):
        say("\nThe Octavia health manager is stopped first and the load balancers (amphorae) go last; `start` brings them back FIRST and the health manager after them.")
    else:
        say("\nThe load balancers and their amphorae are not touched (add --lbs to stop them too); the app is down from the first tier on.")
    if args.dry_run:
        say("(dry run: nothing stopped)")
        return
    if args.confirm:                                  # asking is opt-in: a maintenance window should not need an extra answer
        ans = input("Type the environment name (%s) to stop these %d VMs: " % (env, len(running)))
        if ans.strip() != env:
            die("cancelled")
    if any(v["rank"] == 6 for v in running):
        rc, out = health_manager("stop")
        say("Octavia health manager stopped first (otherwise it rebuilds the amphorae that go quiet): rc=%d" % rc)
        if rc != 0:
            die("could not stop octavia-health-manager on %s; nothing was stopped" % C3)
    save_state(env, running)
    mark_stopped(running)
    say("saved the list to %s and marked the VMs in OpenStack (maint_stopped), so any machine can start them" % state_path(env))
    for i, ((rank, sub), group) in enumerate(tiers(running, reverse=False), 1):
        names = " ".join(v["name"] for v in group)
        say("\n== %d. stop %s: %s" % (i, RANK_NAME.get(rank, "other"), names))
        openstack("server", "stop", *[v["id"] for v in group])
        left = wait_status(env, [v["id"] for v in group], "SHUTOFF", STOP_TIER_TIMEOUT)
        if left:
            die("still running after %ds: %s (look at them; nothing further was stopped; `start` brings back what was stopped)"
                % (STOP_TIER_TIMEOUT, " ".join(v["name"] for v in group if v["id"] in left)))
        say("   all SHUTOFF")
    say("\nAll %d VMs of %s are off. Bring them back with: scripts/env-vms.py %s start" % (len(running), env, env))


def cmd_start(env, args):
    everything = list_vms(env)
    if not everything:
        die("no VMs with env=%s found" % env)
    vms = pick(everything, args, env)                 # the named servers, or all of them
    st = load_state(env)
    if args.servers:
        # Naming a server is the instruction: start it if it is off, whatever the last `stop` saved. Its tier position (database leader,
        # standby) comes from the saved list when it has one.
        saved = {s_["id"]: s_ for s_ in (st or {}).get("vms", [])}
        todo = []
        for v in vms:
            if v["status"] == "SHUTOFF":
                v["sub"] = int(saved[v["id"]].get("sub", 0)) if v["id"] in saved else int(v.get("props", {}).get("maint_sub", 0) or 0)
                todo.append(v)
    elif args.all:
        todo = [v for v in vms if v["status"] == "SHUTOFF" and (v["rank"] != 6 or INCLUDE_LBS_FLAG)]
    else:
        todo = []
        saved = {s_["id"]: s_ for s_ in (st or {}).get("vms", [])}
        for v in vms:
            marked = "maint_stopped" in v.get("props", {})
            if v["status"] == "SHUTOFF" and (v["id"] in saved or marked):
                v["sub"] = int(saved[v["id"]].get("sub", 0)) if v["id"] in saved else int(v["props"].get("maint_sub", 0) or 0)
                todo.append(v)
        if not todo and not st and not any("maint_stopped" in v.get("props", {}) for v in vms):
            die("nothing was stopped by `stop` for %s (no saved list here and no maint_stopped mark on any VM). To start every VM that is off: scripts/env-vms.py %s start --all" % (env, env))
    already = [v["name"] for v in vms if v["status"] == "ACTIVE"]
    if already:
        say("already running: " + " ".join(already))
    odd = [v["name"] for v in vms if v["status"] not in ("ACTIVE", "SHUTOFF")]
    if odd:
        say("WARNING, in another state (not touched): " + " ".join(odd))
    if not todo:
        say("nothing to start")
        return
    show_plan("Start plan for %s (%d VMs):" % (env, len(todo)), todo, reverse=True)
    if args.dry_run:
        say("(dry run: nothing started)")
        return
    all_vms = everything                              # the checks (Patroni, nodes) look at the whole environment, not only the selection
    plan = tiers(todo, reverse=True)
    for i, ((rank, sub), group) in enumerate(plan):
        names = " ".join(v["name"] for v in group)
        say("\n== %d. start %s: %s" % (i + 1, RANK_NAME.get(rank, "other"), names))
        openstack("server", "start", *[v["id"] for v in group])
        left = wait_status(env, [v["id"] for v in group], "ACTIVE", START_TIER_TIMEOUT)
        if left:
            die("not ACTIVE after %ds: %s" % (START_TIER_TIMEOUT, " ".join(v["name"] for v in group if v["id"] in left)))
        say("   all ACTIVE")
        if rank == 6:
            say("   waiting %ds for the amphorae to boot and send heartbeats, then starting the Octavia health manager ..." % LB_SETTLE)
            time.sleep(LB_SETTLE)
            rc, out = health_manager("start")
            say("   Octavia health manager: %s" % ("started" if rc == 0 else "COULD NOT START (start it: ssh %s systemctl start octavia-health-manager)" % C3))
        # what the NEXT tier needs, once the last tier of this kind is up
        next_rank = plan[i + 1][0][0] if i + 1 < len(plan) else None
        if rank == 4 and next_rank != 4:
            say("   waiting for a Patroni leader ...")
            say("   Patroni leader: " + ("yes" if wait_patroni_leader(all_vms) else "NOT yet (continuing; check patronictl list)"))
        if rank == 3 and next_rank != 3:
            say("   waiting for the Kubernetes API ...")
            say("   API: " + ("ok" if wait_api(env) else "NOT answering yet (continuing; check the control planes)"))
    # end of start: nodes, cleanup, checks
    # Only the nodes that are meant to be up: running now, or started just now. One left off on purpose is not waited for.
    meant_up = {v["id"] for v in everything if v["status"] == "ACTIVE"} | {v["id"] for v in todo}
    workers_cp = [v for v in everything if v["rank"] in (2, 3) and v["id"] in meant_up]
    if workers_cp:
        say("\n== waiting for every node Ready ...")
        ok = wait_nodes(env, len(workers_cp))
        r = nodes_ready(env)
        say("   nodes Ready: %s%s" % ("%d of %d" % r if r else "API not answering", "" if ok else "  (not all yet; give it a few minutes)"))
        if ok and not args.no_cleanup:
            rc, out = kubectl(env, "delete", "pod", "-A", "--field-selector=status.phase=Failed", timeout=120)
            n = len([l for l in out.splitlines() if l.startswith("pod ")])
            say("   cleared %d leftover Error pod record(s) from the graceful shutdown" % n)
    rc, st_hm = health_manager("is-active")
    if st_hm != "active":
        rc, _ = health_manager("start")
        say("Octavia health manager was %s: started again (rc=%d)" % (st_hm or "not running", rc))
    if ENV_LBS.get(env):
        say("load balancers: " + lb_summary(env))
    members = patroni(all_vms)
    if members:
        say("Patroni: " + ", ".join("%s %s %s" % (m.get("Member"), m.get("Role"), m.get("State")) for m in members))
    if env in FRONT_DOOR:
        rc, out = run(["curl", "-s", "-o", "/dev/null", "-m", "8", "-w", "%{http_code}", FRONT_DOOR[env]], 15)
        say("front door %s: %s" % (FRONT_DOOR[env], out.strip() or "no answer yet"))
    unmark_stopped(todo)
    if st and args.servers:
        # Some of the saved VMs may still be off: keep the list, minus the ones just started.
        left = [s_ for s_ in st.get("vms", []) if s_["id"] not in {v["id"] for v in todo}]
        try:
            if left:
                st["vms"] = left
                with open(state_path(env), "w") as f:
                    json.dump(st, f, indent=1)
            else:
                os.replace(state_path(env), state_path(env) + ".last")
        except OSError:
            pass
    elif st:
        try:
            os.replace(state_path(env), state_path(env) + ".last")
        except OSError:
            pass
    say("\nDone. If the front door or a node is not ready yet, wait a minute and run: scripts/env-vms.py %s status" % env)


def main():
    ap = argparse.ArgumentParser(description="Stop, start or show all the VMs of one environment in a safe order.")
    ap.add_argument("env", help="prod | cka | qa")
    ap.add_argument("command", choices=["stop", "start", "status"])
    ap.add_argument("servers", nargs="*", metavar="server", help="only these VMs, by name as `status` prints them (default: the whole environment)")
    ap.add_argument("--confirm", action="store_true", help="stop: ask for the environment name first (by default it does not ask)")
    ap.add_argument("--yes", action="store_true", help=argparse.SUPPRESS)   # old option, now the default; accepted and ignored
    ap.add_argument("--dry-run", action="store_true", help="show the plan only")
    ap.add_argument("--all", action="store_true", help="start: every VM of the environment that is SHUTOFF, not just what the last stop saved")
    ap.add_argument("--lbs", action="store_true", help="also stop (or, with --all, start) the load-balancer VMs of this environment (the Octavia amphorae); the health manager is handled")
    ap.add_argument("--no-cleanup", action="store_true", help="start: keep the leftover Error pod records")
    argv = sys.argv[1:]
    if len(argv) >= 2 and argv[0] in ("stop", "start", "status"):   # the old order (command first) still works
        argv[0], argv[1] = argv[1], argv[0]
    args = ap.parse_args(argv)
    global INCLUDE_LBS, INCLUDE_LBS_FLAG
    INCLUDE_LBS_FLAG = args.lbs
    INCLUDE_LBS = args.lbs or args.command in ("start", "status") or bool(args.servers)   # start finds amphorae that `stop --lbs` marked; status shows them; a named amphora must be findable
    {"stop": cmd_stop, "start": cmd_start, "status": cmd_status}[args.command](args.env, args)


if __name__ == "__main__":
    main()
