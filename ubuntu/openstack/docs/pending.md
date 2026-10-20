# Pending and open items

What is deliberately not done yet, who decides, and what finishes it. Update this page whenever something is added, decided or finished
(and say so in `../CHANGELOG.md`). Last updated 2026-10-20.

## Waiting for a decision or a moment
| Item | Why it is open | What finishes it |
|---|---|---|
| Two-amphora failover of `finance-lb` | `openstack loadbalancer failover finance-lb` fails about half the time with a Placement "no allocation candidates" error; a retry works. Cause not found | retry; open a deeper investigation only if it blocks a rebuild |


## Accepted limits (no action planned)
- Database replication is synchronous but not strict: a standby outage means about 35 s of paused writes, then asynchronous until it returns (`db-ha-patroni.md`).
- Losing three of the five etcd machines (`dbw1`, `dbw2`, `dbw3`, `db1`, `db2`) stops automatic database failover; any two are survived. Emergency steps: `db-ha-patroni.md`. Everything runs on one host (`c3`), so a host loss still takes everything.
- A really dead amphora is replaced automatically after 5 minutes (`heartbeat_timeout = 300`) or at once with `openstack loadbalancer failover <lb>`; both load balancers have a standby (`amphora-reboot-fix.md`).
- Single control-plane node per Kubernetes cluster (prod, qa, cka).

## Done recently (so nobody redoes it)
Cinder removed from the catalog (2026-10-20; backups in `/root/backups/cinder-removal-20261020` on `c3` and `/root/backups/c3-cinder-removal-20261020.tgz` on `backup`, restore steps inside);
`ram_allocation_ratio` 1.2; `w4`/`w5` retired; `learn` removed; database HA built by Terraform; reboot tests 1 to 8: automatic VM start and a plain `systemctl reboot` that completes by itself in under 2 minutes (`c3-reboot.md`); the slow worker power-off (kubelet graceful shutdown) and the OVN stop order are fixed.
