# The `c3` host route to the private network

Added **2026-10-20**. This page explains the problem, what was done step by step (so you can repeat or undo it), why it works, and what can go wrong.

## The problem
VMs have two addresses: a **private** one (`10.0.1.x`, on the OpenStack tenant network) and a **floating** one (`192.168.2.x`, on the lab LAN). `c3`, the host that runs OpenStack,
sits on the lab LAN (`br0`, `192.168.2.2/24`) and had only two routes: the LAN itself and a default route to `192.168.2.1`. So `c3` had **no way to reach `10.0.1.x`**:
every check run on `c3` had to use a floating IP, and a probe of a private address just timed out. That caused wrong conclusions once: a worker's NodePort looked dead
from `c3` when it was only the wrong address.

Things that talk over the private network (pods, the load balancers, the VMs among themselves, the app's `DATABASE_URL = 10.0.1.191`) were never affected; this was only about `c3`.

## What was done
1. **Look at what `c3` knows** (on `c3`): `ip route` showed only `default via 192.168.2.1` and `192.168.2.0/24 dev br0`. Nothing for `10.0.1.0/24`.
2. **Find the OpenStack router's address on the LAN.** The tenant network `10.0.1.0/24` hangs off the Neutron router `main_router`; its private side is `10.0.1.1` and its **external side
   is a normal address on the lab LAN**:
   ```bash
   openstack router list
   openstack router show main_router -c external_gateway_info -c interfaces_info
   #   external: 192.168.2.174        internal: 10.0.1.1
   ```
3. **Add the route at runtime** (instant, lost on reboot, harmless to try):
   ```bash
   ip route add 10.0.1.0/24 via 192.168.2.174
   ip route | grep 10.0.1        # 10.0.1.0/24 via 192.168.2.174 dev br0
   ```
   `192.168.2.174` is on the directly connected `192.168.2.0/24`, so the kernel accepts it as a next hop.
4. **Test before making it permanent**, from `c3`: SSH (port 22) to `w1` `10.0.1.67`, `w2` `10.0.1.197` and `db1` `10.0.1.191` open; Postgres `10.0.1.191:5432` open;
   `w1` NodePort `10.0.1.67:30080` open; `ping 10.0.1.67` answers. And the old paths still worked: `http://192.168.2.5/health` returned 200 and SSH to `w1`'s floating IP was open.
5. **Make it permanent.** `c3` is Debian 13 with classic `ifupdown` (`/etc/network/interfaces`; there is no netplan). After a backup
   (`cp -p /etc/network/interfaces /etc/network/interfaces.bak-20261020`), two lines were added to the `br0` stanza, right after `hwaddress`:
   ```
   up ip route add 10.0.1.0/24 via 192.168.2.174 || true
   down ip route del 10.0.1.0/24 via 192.168.2.174 || true
   ```
   `ifquery br0` shows them as `up:` and `down:`. The `|| true` means that if the route already exists (as it does right now) bringing the interface up does not fail.

## Why it works
A packet from `c3` (`192.168.2.2`) to `10.0.1.67` now goes to the router's external address. A Neutron router forwards between its gateway interface and its tenant subnets, so it passes the
packet on to the VM. The VM answers to `192.168.2.2` through its default route (`10.0.1.1`, the same router), and the router sends the reply back out the gateway interface to `c3`.
The security groups apply as usual: the packet reaches the VM with source `192.168.2.2`, the same source as when `c3` uses the floating IP, so anything `c3` was already allowed to reach by
floating IP is allowed by private IP too (SSH, 5432, the NodePorts all answered; this is what was observed, not a change to any rule). The router itself is not changed.

## Verify at any time
```bash
ssh c3 'ip route | grep 10.0.1'                                  # the route is there
ssh c3 'ping -c1 -W2 10.0.1.67'                                  # a worker answers on its private IP
ssh c3 'curl -s -o /dev/null -w "%{http_code}\n" http://10.0.1.67:30080/health'    # 200
```

## Undo it
```bash
ssh c3 'ip route del 10.0.1.0/24 via 192.168.2.174'              # immediately, until the next ifup/boot
ssh c3 'cp -p /etc/network/interfaces.bak-20261020 /etc/network/interfaces'   # permanently (restores the file as it was)
```
Nothing else depends on the route: the cloud, the app and the load balancers do not use it.

## Things that can go wrong
- **The router's external address changes.** `192.168.2.174` was allocated by Neutron when the router's gateway was set. If the gateway is cleared and set again it may get another address, and the route
  then points at nothing (private addresses time out again). Fix: read the new address (`openstack router show main_router -c external_gateway_info`) and update the route at runtime
  and in `/etc/network/interfaces`. A fixed address can be requested when the gateway is set, if you want it to stay the same.
- **Not tested at boot.** `c3` was not rebooted for this change, so the permanent version has only been checked by reading it back (`ifquery`), not by a real boot. At boot the router may not be
  up yet when the route is added; that is fine for the route (only the next hop's subnet must exist), but the private addresses answer only after the router is up.
- **It is a change to the host, not to Terraform.** It is listed in `ARCHITECTURE.md` under "What Terraform does not manage" and in `../CHANGELOG.md`. If `c3` is ever reinstalled, add the route again.
- **Not for other machines.** Only `c3` has the route. Your Mac (`192.168.1.x`) is on another subnet and cannot reach `10.0.1.x` or the worker NodePorts. Giving it that would need a route on the Mac
  (or on the LAN gateway) toward `192.168.2.174`, and the LAN gateway forwarding between the two subnets; that was not tried.

## Related
`operations-cheatsheet.md` (Reachability) and `ARCHITECTURE.md` (addresses and names).
