# Pending and open items

What is deliberately not done yet, who decides, and what finishes it. Update this page whenever something is added, decided or finished
(and say so in `../CHANGELOG.md`). Last updated 2026-10-20.

## Waiting for a decision or a moment
| Item | Why it is open | What finishes it |
|---|---|---|
| Two-amphora failover of `finance-lb` | `openstack loadbalancer failover finance-lb` fails about half the time with a Placement "no allocation candidates" error; a retry works. Cause not found | retry; open a deeper investigation only if it blocks a rebuild |


## Accepted limits (no action planned)
- Database replication is asynchronous: in a hard failure the last seconds (up to the 1 MB lag guard; about 20 s in a partition) can be lost. `synchronous_mode` would remove that at the price of writes stalling when the replica is unreachable (`db-ha-patroni.md`).
- Losing two of the three etcd machines (`dbw` and one database) stops automatic database failover until one is back.
- A really dead amphora is replaced automatically only after 15 minutes (`heartbeat_timeout = 900`, `amphora-reboot-fix.md`).
- Single control-plane node per Kubernetes cluster (prod, qa, cka).

## Done recently (so nobody redoes it)
Cinder removed from the catalog (2026-10-20; backups in `/root/backups/cinder-removal-20261020` on `c3` and `/root/backups/c3-cinder-removal-20261020.tgz` on `backup`, restore steps inside);
`ram_allocation_ratio` 1.2; `w4`/`w5` retired; `learn` removed; database HA built by Terraform; reboot tests 1 to 8: automatic VM start and a plain `systemctl reboot` that completes by itself in under 2 minutes (`c3-reboot.md`); the slow worker power-off (kubelet graceful shutdown) and the OVN stop order are fixed.
