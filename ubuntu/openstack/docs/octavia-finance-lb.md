# Octavia load balancers for prod: `finance-lb` (finance app) and `argo-lb` (Argo CD)

> Current as of 2026-10-20. Overall picture: `ARCHITECTURE.md`. Adding or retiring workers: `k8s-operations.md`. Both load balancers are created by hand (not Terraform).

Goal: put the prod finance app behind an Octavia load balancer that health-checks the workers and survives the loss
of one of its own nodes, instead of the single `haproxy` VM that used to own `192.168.2.5`. Built 2026-10-20 with the OpenStack CLI
on `c3` (not Terraform-managed). The old haproxy VM was destroyed afterwards (see "Old haproxy VM" below).

## What exists
| Object | Value |
|---|---|
| Load balancer | `finance-lb`, flavor `ha` (**ACTIVE_STANDBY**: two amphorae, VRRP failover) |
| VIP / floating IP | `10.0.1.89` on `private_subnet` / **`192.168.2.5`** (finance app only, after the cutover below) |
| Listener | `finance-http` HTTP :80, inserts `X-Forwarded-For` |
| Pool `finance-pool` | workers `w1 10.0.1.67`, `w2 10.0.1.197`, `w3 10.0.1.45`, `w4 10.0.1.206`, `w5 10.0.1.33` : **30080** (nginx NodePort), HTTP monitor `GET /health` = 200 |
| L7 policies | none; every request goes to `finance-pool` |
| **`argo-lb`** | separate load balancer (SINGLE topology: one amphora), VIP `10.0.1.56` / floating IP **`192.168.2.113`** (`argo.rdulinux.com`). Listener `argo-http` HTTP :80 -> pool `argo-backend`: workers w1-w5 : **30443** (Argo CD), HTTP monitor `GET /healthz` = 200 |

## Verified
- Same status + content hash as the live haproxy on 8 public paths; Argo host answers 200.
- **Failover test:** with steady requests, the MASTER amphora VM was powered off and left off. 485 requests, 0 failed;
  Octavia rebuilt the lost amphora by itself in ~95 s and ended `ACTIVE` with two healthy amphorae.

## How it was built (commands)
```bash
# per-LB topology via a flavor (no change to the global octavia.conf)
openstack loadbalancer flavorprofile create --name active-standby --provider amphora --flavor-data '{"loadbalancer_topology": "ACTIVE_STANDBY"}'
openstack loadbalancer flavor create --name ha --flavorprofile active-standby --enable
openstack loadbalancer create --name finance-lb --vip-subnet-id private_subnet --flavor ha
openstack loadbalancer listener create --name finance-http --protocol HTTP --protocol-port 80 --insert-headers X-Forwarded-For=true finance-lb
openstack loadbalancer pool create --name finance-pool --lb-algorithm ROUND_ROBIN --listener finance-http --protocol HTTP
openstack loadbalancer member create --name wN --subnet-id private_subnet --address <worker private IP> --protocol-port 30080 finance-pool   # once per worker (today w1 to w5)
openstack loadbalancer healthmonitor create --name finance-hm --type HTTP --url-path /health --expected-codes 200 --delay 5 --timeout 3 --max-retries 3 finance-pool
FIP=$(openstack floating ip create external_network -c floating_ip_address -f value)
openstack floating ip set --port $(openstack loadbalancer show finance-lb -c vip_port_id -f value) $FIP
```

### `argo-lb` (Argo CD, its own load balancer)
Argo used to be a second pool on `finance-lb`, selected by Host header (L7 policies `argo` / `argo-host`). On 2026-10-20 it moved
to a load balancer of its own, so a problem or change on one never touches the other. The policies and `argo-pool` were deleted
from `finance-lb` after DNS pointed at the new address.
```bash
openstack loadbalancer create --name argo-lb --vip-subnet-id private_subnet     # no flavor = SINGLE (one amphora); add --flavor ha for ACTIVE_STANDBY
openstack loadbalancer listener create --name argo-http --protocol HTTP --protocol-port 80 --insert-headers X-Forwarded-For=true argo-lb
openstack loadbalancer pool create --name argo-backend --lb-algorithm ROUND_ROBIN --listener argo-http --protocol HTTP
openstack loadbalancer member create --name wN --subnet-id private_subnet --address <private ip> --protocol-port 30443 argo-backend   # per worker
openstack loadbalancer healthmonitor create --name argo-backend-hm --type HTTP --url-path /healthz --expected-codes 200 --delay 5 --timeout 3 --max-retries 3 argo-backend
FIP=$(openstack floating ip create external_network -c floating_ip_address -f value)
openstack floating ip set --port $(openstack loadbalancer show argo-lb -c vip_port_id -f value) $FIP    # 192.168.2.113
```
DNS (`infra/infra.yaml`): `argo` -> 192.168.2.113 with PTR. Wait for each step to leave `PENDING_*` before the next.

## Pitfalls we hit (all fixed)
- **Host reboot, stale router entry, health manager**: all three are fixed, see `amphora-reboot-fix.md` (patched amphora image, `ovn-vip-binding` watcher, `heartbeat_timeout = 900`). Never run `openstack image set --tag` so that two images carry `Amphora`: Octavia silently takes the newest. A rebuilt amphora has a new MAC; if a front door is down while the load balancer is `ACTIVE`, check `journalctl -u ovn-vip-binding.service`.
- **Health manager and a host reboot (history).** Heartbeats are received by the health manager, so after it was off (or the host was rebooted) every amphora looks dead for the first seconds and it starts
  failovers; with little free memory they can fail (`No valid host`, `ComputeWaitTimeoutException`) and leave a load balancer `ERROR`. Fix: `openstack loadbalancer failover <lb>` (retry on `409`).
  Details and the safe procedure: `c3-reboot.md`.
- **VIP network must not be the amphora management network.** Putting the VIP on `external_network` (also `amp_boot_network_list`)
  makes Octavia's `CalculateAmphoraDelta` raise `KeyError`, and every member goes to ERROR. Keep the VIP on the private subnet and
  reach it through a floating IP.
- **Health-manager settings are required:** `[health_manager] controller_ip_port_list`, `heartbeat_key`.
- **Do not set `amp_ssh_key_name` to an admin keypair:** the Octavia service user cannot see it (`Invalid key_name`).
- **After ANY change to `/etc/octavia/octavia.conf`, restart BOTH `octavia-worker` and `octavia-health-manager`.** The health manager
  rebuilds failed amphorae with its own copy of the config; a stale one made automatic failover fail until it was restarted.
- **Placement accounting:** disk ratio raised to 1.5 and memory to 1.1 (real usage is far lower); project core quota raised to 64.
  Two 2 GB amphorae per HA load balancer.
- A `PENDING_*` load balancer cannot be changed or deleted; wait for the worker's retries to expire (~15-20 min) or fix the cause.
- If one instance fails at the quota check, Nova can leave an ERROR instance without a request spec, which makes
  `openstack server list` return 500 (`KeyError` in `servers/detail`). Delete that instance by id.

## Cutover (done 2026-10-20) and rollback
The load balancer now owns **192.168.2.5**, the finance front door (the public entry points there; Argo has its own load balancer, see `argo-lb`).
It was done by swapping floating IPs, which is atomic in Neutron (151 probe requests, 0 failed; first answer from the load balancer 2 s later):
```bash
openstack floating ip unset --port 192.168.2.119                              # free .119 from the LB
openstack floating ip set --port <finance-lb vip_port_id> 192.168.2.5         # .5 moves to the LB
openstack floating ip set --port <haproxy VM port id> 192.168.2.119           # the old haproxy VM keeps a reachable address
```
The old haproxy VM was left running at **192.168.2.119** as a rollback path, with the reverse swap below. It was
retired on 2026-10-20 (no traffic for 30+ minutes, nothing referenced it), so the rollback no longer exists.
Kept for history only:
```bash
openstack floating ip unset --port 192.168.2.119
openstack floating ip set --port <finance-lb vip_port_id> 192.168.2.119
openstack floating ip set --port <haproxy VM port id> 192.168.2.5
```
Not carried over from haproxy: its `qa.rdulinux.com` -> QA-cluster route (the `qa.rdulinux.com` apex record was removed on 2026-10-20; the `qa.rdulinux.com.` zone stays for the QA VMs).

## Old haproxy VM (retired 2026-10-20)
Removed from `environments/prod/nodes.yaml`; `terraform apply` destroys the VM, its port and floating IP `.119`. The
`loadbalancer` role, `cloud-init/haproxy.*` and the `haproxy` ssh alias were deleted. Its last config is in git history
(`cloud-init/haproxy.cfg`). The DNS names `haproxy.rdulinux.com` and `lb.rdulinux.com` were retired; `finance.rdulinux.com` is the name of 192.168.2.5 (A and PTR).
Before this, Terraform had to adopt `.119` as the VM's floating IP (`terraform state rm` + `import` of the association)
so that it would not re-attach `.5`; that is no longer relevant.

## Workers change over time (pools are static)
Octavia pools do not follow Kubernetes nodes. When a worker is added or retired, edit BOTH load balancers by hand (`finance-pool` on `finance-lb`, `argo-backend` on `argo-lb`):
```bash
openstack loadbalancer member create --name wN --subnet-id private_subnet --address <private ip> --protocol-port 30080 finance-pool
openstack loadbalancer member create --name wN --subnet-id private_subnet --address <private ip> --protocol-port 30443 argo-backend
openstack loadbalancer member delete finance-pool wN   # and argo-backend, BEFORE draining/powering off a node
```
History: `w4`, `w5` added and the original `w1` retired on 2026-10-20, then a fresh `w1` (10.0.1.67) added the same day, so both pools hold `w1` to `w5` (drain with `--ignore-daemonsets --delete-emptydir-data`; the finance
Deployments have PodDisruptionBudgets with minAvailable 2 and a required anti-affinity, so a drain never takes two copies).
A new worker joins with `/nfsshare/join-prod.sh`; its token lasts 24 h, so recreate it on `c1` first
(`sudo kubeadm token create --print-join-command | sudo tee /nfsshare/join-prod.sh`).
