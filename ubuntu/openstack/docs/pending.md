# Pending and open items

What is deliberately not done yet, who decides, and what finishes it. Update this page whenever something is added, decided or finished
(and say so in `../CHANGELOG.md`). Last updated 2026-10-20.

## Waiting for a decision or a moment
| Item | Why it is open | What finishes it |
|---|---|---|
| **A 4th prod worker** | Prod has 3 workers and no spare node, so draining one blocks until it is back (`k8s-operations.md`). Ignored on purpose for now; there is also not enough capacity while the CKA cluster runs | add `w4` to `environments/prod/nodes.yaml` (2 vCPU, 4 GB), apply, add its private address to `finance-pool` and `argo-backend` (`octavia-finance-lb.md`). Needs about 4 GB RAM and 10 GB disk |
| **Destroy the CKA cluster when you are done practising** | it holds 16 GB RAM and 40 GB disk of the host's headroom (finance-lb's two-amphora rebuild needs about 4 GB) | `cd environments/cka && terraform destroy` (`cka-cluster.md`) |
| Runner kernel oops | the `runner` guest crashed once in the `.NET` GitHub runner process, 72 s after boot (reboot test 5); a similar `segfault at 0 ip 0` of an `openstack` client was logged on the host. Did not recur after a stop/start. Cause unknown | if it recurs: note the time, capture `openstack console log show runner` and `dmesg` on `c3`, check the host kernel (6.12.95) and the nested-KVM setting |
| Two-amphora failover of `finance-lb` | `openstack loadbalancer failover finance-lb` fails about half the time with a Placement "no allocation candidates" error; a retry works. Cause not found | retry; open a deeper investigation only if it blocks a rebuild |

## Accepted limits (no action planned)
- Database replication is asynchronous: in a hard failure the last seconds (up to the 1 MB lag guard; about 20 s in a partition) can be lost. `synchronous_mode` would remove that at the price of writes stalling when the replica is unreachable (`db-ha-patroni.md`).
- Losing two of the three etcd machines (`dbw` and one database) stops automatic database failover until one is back.
- A really dead amphora is replaced automatically only after 15 minutes (`heartbeat_timeout = 900`, `amphora-reboot-fix.md`).
- Single control-plane node per Kubernetes cluster (prod, qa, cka).

## Done recently (so nobody redoes it)
Cinder removed from the catalog (2026-10-20; backups in `/root/backups/cinder-removal-20261020` on `c3` and `/root/backups/c3-cinder-removal-20261020.tgz` on `backup`, restore steps inside);
`ram_allocation_ratio` 1.2; `w4`/`w5` retired; `learn` removed; database HA built by Terraform; reboot tests 1 to 5 (`c3-reboot.md`).
