#!/usr/bin/env python3
"""Keep each Kubernetes API load balancer's members equal to the cluster's control-plane VMs.

Why (docs/k8s-ha-control-plane.md): a cluster's API address is an Octavia load balancer `<env>-api` (TCP 6443) in front of every control-plane
node. Control-plane VMs are created and destroyed by Terraform, which does not manage Octavia here, so without this nobody would add a new
controller to the load balancer (or take a removed one out), and "no manual work when something gets created" would not hold.

Every run (a systemd timer on c3 runs it every 30 s, as root, with the admin credentials from /etc/default/k8s-api-lb-reconciler):
  for each load balancer named `<env>-api` that is ACTIVE, with a pool `<env>-api-pool`:
    wanted  = private addresses of the ACTIVE servers tagged env=<env> and role=controller|controller_join
    add     a member for every wanted address that is missing
    remove  a member only when NO server (in any state) has that address any more (a stopped controller stays a member; the health monitor
            handles it), and never the last member.
  k8s-api-lb-reconciler.py --dry-run   show what it would do, change nothing
"""
import re
import sys

import openstack

DRY = "--dry-run" in sys.argv
ROLES = ("controller", "controller_join")


def log(msg):
    print(msg, flush=True)


def main():
    conn = openstack.connect()
    servers = list(conn.compute.servers(all_projects=True, details=True))

    def ips(server):
        out = []
        for nets in (server.addresses or {}).values():
            out += [a["addr"] for a in nets if a.get("version") == 4 and a["addr"].startswith("10.0.1.")]
        return out

    all_ips = {ip for s in servers for ip in ips(s)}
    subnet = conn.network.find_subnet("private_subnet")
    for lb in conn.load_balancer.load_balancers():
        m = re.fullmatch(r"(.+)-api", lb.name or "")
        if not m or lb.provisioning_status != "ACTIVE":
            continue
        env = m.group(1)
        pool = next((p for p in conn.load_balancer.pools(loadbalancer_id=lb.id) if p.name == f"{env}-api-pool"), None)
        if pool is None:
            continue
        wanted = sorted({ip for s in servers if s.status == "ACTIVE" and (s.metadata or {}).get("env") == env
                         and (s.metadata or {}).get("role") in ROLES for ip in ips(s)})
        members = list(conn.load_balancer.members(pool))
        have = {mm.address: mm for mm in members}
        for ip in wanted:
            if ip not in have:
                log(f"{lb.name}: add member {ip}" + (" (dry run)" if DRY else ""))
                if not DRY:
                    conn.load_balancer.create_member(pool, name=f"cp-{ip}", address=ip, protocol_port=6443, subnet_id=subnet.id)
                    conn.load_balancer.wait_for_load_balancer(lb.id, wait=120)
        for ip, mm in have.items():
            if ip not in all_ips and len(have) > 1:
                log(f"{lb.name}: remove member {ip} (no server has this address any more)" + (" (dry run)" if DRY else ""))
                if not DRY:
                    conn.load_balancer.delete_member(mm, pool)
                    conn.load_balancer.wait_for_load_balancer(lb.id, wait=120)
                    have = {a: b for a, b in have.items() if a != ip}


if __name__ == "__main__":
    main()
