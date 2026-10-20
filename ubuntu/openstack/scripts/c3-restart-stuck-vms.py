#!/usr/bin/env python3
# Run ON c3 (admin credentials in the environment). Starts VMs that are stuck in task_state "powering-on" (SHUTOFF in Nova, shut off in libvirt) after a host
# reboot: clears the stale task state, stops and starts them, db1/dbw1 first, then the controllers, then the rest. Found 2026-10-20: docs/c3-reboot.md "Test 5".
import openstack, time
c=openstack.connect()
S=[s for s in c.compute.servers(all_projects=True, details=True) if s.task_state=="powering-on"]
order=lambda s:(0 if s.name in("db1","dbw1") else 1 if s.name=="c1" else 2)
for s in sorted(S,key=order):
    c.compute.reset_server_state(s,"active")   # clears the stale task_state
    s=c.compute.get_server(s.id)
    c.compute.stop_server(s)
    c.compute.wait_for_server(s,status="SHUTOFF",wait=120)
    c.compute.start_server(s)
    print("started",s.name,flush=True)
for s in S:
    c.compute.wait_for_server(c.compute.get_server(s.id),status="ACTIVE",wait=300)
print("all ACTIVE")
