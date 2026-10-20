# Octavia load balancer for the finance app (prod)

Goal: put the prod finance app behind an Octavia load balancer that health-checks the workers and survives the loss
of one of its own nodes, instead of the single `haproxy` VM (`192.168.2.5`). Built 2026-10-20 with the OpenStack CLI
on `c3` (not Terraform-managed). The old haproxy is untouched and is the rollback path.

## What exists
| Object | Value |
|---|---|
| Load balancer | `finance-lb`, flavor `ha` (**ACTIVE_STANDBY**: two amphorae, VRRP failover) |
| VIP / floating IP | `10.0.1.89` on `private_subnet` / **`192.168.2.119`** |
| Listener | `finance-http` HTTP :80, inserts `X-Forwarded-For` |
| Pool `finance-pool` | workers `w2 10.0.1.197`, `w3 10.0.1.45`, `w4 10.0.1.206`, `w5 10.0.1.33` : **30080** (nginx NodePort), HTTP monitor `GET /health` = 200 |
| Pool `argo-pool` | same workers : **30443** (Argo CD), HTTP monitor `GET /healthz` = 200 |
| L7 policies | `argo` (Host = `argo.rdulinux.com`) and `argo-host` (regex `^argo(\.rdulinux\.com)?(:[0-9]+)?$`: short name and host-with-port, as the old haproxy accepted) -> `argo-pool`; everything else -> `finance-pool` |

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
openstack loadbalancer member create --name w1 --subnet-id private_subnet --address 10.0.1.237 --protocol-port 30080 finance-pool   # w2, w3 likewise
openstack loadbalancer healthmonitor create --name finance-hm --type HTTP --url-path /health --expected-codes 200 --delay 5 --timeout 3 --max-retries 3 finance-pool
openstack loadbalancer pool create --name argo-pool --lb-algorithm ROUND_ROBIN --loadbalancer finance-lb --protocol HTTP
openstack loadbalancer member create --name w1 --subnet-id private_subnet --address 10.0.1.237 --protocol-port 30443 argo-pool     # w2, w3 likewise
openstack loadbalancer healthmonitor create --name argo-hm --type HTTP --url-path /healthz --expected-codes 200 --delay 5 --timeout 3 --max-retries 3 argo-pool
openstack loadbalancer l7policy create --name argo --action REDIRECT_TO_POOL --redirect-pool argo-pool finance-http
openstack loadbalancer l7rule create --type HOST_NAME --compare-type EQUAL_TO --value argo.rdulinux.com argo
FIP=$(openstack floating ip create external_network -c floating_ip_address -f value)
openstack floating ip set --port $(openstack loadbalancer show finance-lb -c vip_port_id -f value) $FIP
```

## Pitfalls we hit (all fixed)
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
The load balancer now owns **192.168.2.5**, the finance front door (public entry, `qa.rdulinux.com`, `argo.rdulinux.com` all point there).
It was done by swapping floating IPs, which is atomic in Neutron (151 probe requests, 0 failed; first answer from the load balancer 2 s later):
```bash
openstack floating ip unset --port 192.168.2.119                              # free .119 from the LB
openstack floating ip set --port <finance-lb vip_port_id> 192.168.2.5         # .5 moves to the LB
openstack floating ip set --port <haproxy VM port id> 192.168.2.119           # the old haproxy VM keeps a reachable address
```
The old haproxy VM is unchanged and now at **192.168.2.119** (`ssh root@192.168.2.119`). **Rollback** = the reverse swap:
```bash
openstack floating ip unset --port 192.168.2.119
openstack floating ip set --port <finance-lb vip_port_id> 192.168.2.119
openstack floating ip set --port <haproxy VM port id> 192.168.2.5
```
Not carried over from haproxy: its `qa.rdulinux.com` -> QA-cluster route (`qa.` now lands on the finance app by design).

### Terraform follow-up (prod environment) - do this BEFORE the next `terraform apply` there
Terraform still believes floating IP .5 belongs to the haproxy VM and would re-attach it, pulling it away from the load balancer.
Make it adopt .119 as the VM's floating IP instead (state-only, no OpenStack changes):
```bash
cd environments/prod
terraform state rm 'module.node["haproxy"].openstack_networking_floatingip_associate_v2.this' 'module.node["haproxy"].openstack_networking_floatingip_v2.this'
terraform import 'module.node["haproxy"].openstack_networking_floatingip_v2.this' d9c7b9df-7541-4fdd-9272-1a7ad037bff8
terraform import 'module.node["haproxy"].openstack_networking_floatingip_associate_v2.this' d9c7b9df-7541-4fdd-9272-1a7ad037bff8
terraform plan    # expect at most in-place tag updates; nothing touching 192.168.2.5
```
The DNS name `haproxy.rdulinux.com` (infra.yaml) still points at .5, which is now the load balancer.

## Workers change over time (pools are static)
Octavia pools do not follow Kubernetes nodes. When a worker is added or retired, edit BOTH pools by hand:
```bash
openstack loadbalancer member create --name wN --subnet-id private_subnet --address <private ip> --protocol-port 30080 finance-pool
openstack loadbalancer member create --name wN --subnet-id private_subnet --address <private ip> --protocol-port 30443 argo-pool
openstack loadbalancer member delete finance-pool wN   # and argo-pool, BEFORE draining/powering off a node
```
History: `w4`, `w5` added and `w1` retired on 2026-10-20 (drain with `--ignore-daemonsets --delete-emptydir-data`; the finance
Deployments have PodDisruptionBudgets with minAvailable 2 and a required anti-affinity, so a drain never takes two copies).
A new worker joins with `/nfsshare/join-prod.sh`; its token lasts 24 h, so recreate it on `c1` first
(`sudo kubeadm token create --print-join-command | sudo tee /nfsshare/join-prod.sh`).
