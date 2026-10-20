#!/usr/bin/env python3
"""Keep OVN's router entry for each Octavia VIP pointing at the amphora that really answers.

Why this exists (docs/c3-reboot.md): the OVN router here has always_learn_from_arp_request=false and no MAC aging, so after an amphora is
rebuilt it keeps the OLD amphora's MAC (or the unbound VIP placeholder port's MAC) for the VIP forever, and the VIP is unreachable although
the load balancer reports ACTIVE/ONLINE. With an active/standby pair it can also point at the standby instead of the amphora keepalived chose.

What it does, every run (a systemd timer runs it every 30 s on c3, as root):
  1. From OVN's northbound DB, find every VIP and the candidate MACs: an IP that a port is allowed to use in addition to its own fixed IPs
     (the Octavia "vrrp" ports carry the VIP as an allowed address pair) maps to that port's MAC.
  2. Probe each VIP (TCP connect to port 80 from c3, which reaches 10.0.1.0/24 through the static route, see docs/c3-host-route.md;
     three tries, and nothing is touched if that route is missing). Assumes the load balancers listen on port 80.
  3. If a VIP does not answer, set the router's MAC_Binding for it to each candidate MAC in turn and keep the first one that makes it answer.
     If none works (for example both amphorae are down) the original value is restored, so a run never makes things worse.
It needs no OpenStack credentials: only ovn-nbctl and ovn-sbctl (root on c3).

  ovn-vip-binding-reconciler.py            one pass, repair what is broken
  ovn-vip-binding-reconciler.py --dry-run  show what it would do, change nothing
"""
import json
import re
import socket
import subprocess
import sys
import time

PORT = 80
CONNECT_TIMEOUT = 3
SETTLE = 2          # seconds to wait after changing an entry before probing again
DRY = "--dry-run" in sys.argv


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=True).stdout


def plain(v):
    """OVSDB JSON values: a set is ["set", [...]], a single element is the bare value."""
    if isinstance(v, list) and len(v) == 2 and v[0] == "set":
        return list(v[1])
    return [v]


def table(cmd, *args):
    d = json.loads(run(cmd, "--format=json", *args))
    heads = d["headings"]
    return [dict(zip(heads, row)) for row in d["data"]]


def vip_candidates():
    """{vip: [mac, ...]} from the northbound DB."""
    out = {}
    for p in table("ovn-nbctl", "--columns=name,addresses,port_security", "list", "Logical_Switch_Port"):
        own = set()
        for a in plain(p["addresses"]):
            if isinstance(a, str):
                own.update(re.findall(r"\d+\.\d+\.\d+\.\d+", a))
        for s in plain(p["port_security"]):
            if not isinstance(s, str):
                continue
            tok = s.split()
            if len(tok) < 3:
                continue
            mac = tok[0]
            for ip in tok[1:]:
                if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", ip) and ip not in own:
                    out.setdefault(ip, [])
                    if mac not in out[ip]:
                        out[ip].append(mac)
    return out


def answers(ip, tries=3):
    """True if the VIP accepts a TCP connection; a few tries, so one lost packet is not mistaken for an outage."""
    for n in range(tries):
        try:
            with socket.create_connection((ip, PORT), timeout=CONNECT_TIMEOUT):
                return True
        except OSError:
            if n < tries - 1:
                time.sleep(1)
    return False


def have_private_route():
    """c3 reaches 10.0.1.0/24 through a static route (docs/c3-host-route.md). Without it every VIP looks down and this script
    would change entries for nothing, so do nothing at all."""
    return bool(run("ip", "route", "show", "10.0.1.0/24").strip())


def bindings(ip):
    return table("ovn-sbctl", "--columns=_uuid,ip,mac,logical_port", "find", "MAC_Binding", f"ip={ip}")


def set_mac(row, mac):
    uuid = row["_uuid"][1]
    run("ovn-sbctl", "set", "MAC_Binding", uuid, f'mac="{mac}"')


def main():
    if not have_private_route():
        print("c3 has no route to 10.0.1.0/24; cannot probe the VIPs, not touching anything")
        return 0
    cands = vip_candidates()
    if not cands:
        print("no VIPs (no ports with allowed address pairs) found")
        return 0
    for vip, macs in sorted(cands.items()):
        if answers(vip):
            continue
        rows = bindings(vip)
        if not rows:
            print(f"{vip}: not answering, no router entry to correct (candidates {macs})")
            continue
        for row in rows:
            original = row["mac"]
            fixed = False
            for mac in macs:
                if mac == original:
                    continue
                print(f"{vip}: not answering with {original}; trying {mac}{' (dry run)' if DRY else ''}")
                if DRY:
                    continue
                set_mac(row, mac)
                time.sleep(SETTLE)
                if answers(vip):
                    print(f"{vip}: answers again with {mac} (was {original})")
                    fixed = True
                    break
            if not fixed and not DRY:
                set_mac(row, original)
                print(f"{vip}: no candidate worked, restored {original} (candidates {macs}); will retry")
    return 0     # nothing to fix is not a failure; a VIP nobody answers is retried on the next run


if __name__ == "__main__":
    sys.exit(main())
