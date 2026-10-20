# Terraform redesign (v1 to v2) and the migration of the live VMs

Done 2026-10-17 to 2026-10-19 (state moved to S3 on 2026-10-17). This document records **why** the structure is the way it is, **how** the running VMs were moved without being rebuilt,
and the traps found on the way. How to use the result day to day is in `../README.md`.

## What was wrong with v1
Two stacks, `infra` and `nodes`, driven by lists: VMs were addressed by position, so adding or removing one shifted the others and Terraform wanted to
recreate them. Names carried the environment, cloud-init inputs were scattered in `.tfvars` and code, and there was no clean way to have two environments.

## What v2 is
| Piece | Decision | Reason |
|---|---|---|
| `infra/` + `infra.yaml` | one stack for everything shared: networks, router, keypair, `k8s` security group, images, DNS zones and static records | change shared things in one place, apply it first |
| `environments/<env>/` + `nodes.yaml` | one stack and one state per environment (`prod`, `qa`); VMs are a YAML map | an environment can be applied, destroyed or rebuilt without touching the other |
| `modules/node` | one module builds a VM: port, instance, floating IP, association, A and PTR records; the **role** picks the cloud-init parts | adding a role means one line plus one template |
| `for_each` with **stable keys** | key = the VM's name | adding, removing or reordering entries never shifts or recreates the others |
| Cloud-init inputs from YAML | `vars:` in `nodes.yaml`, rendered into `*.tftpl` and composed as multipart cloud-config | no values hidden in code |
| `ignore_changes` on `user_data`, `image_name`, `network`, port `fixed_ip` | editing a template never replaces a running VM; rebuild on purpose with `-replace` | cloud-init only runs on first boot anyway |
| **No environment in VM names**; environment is a tag/metadata | `c1`, `w2`, `db1`; `ssh c1.prod`, `ssh w2.qa` | short names; the DNS zone carries the environment |
| **One DNS zone per environment** | `prod.rdulinux.com`, `qa.rdulinux.com`; shared services stay in `rdulinux.com` | names never clash across environments |
| Names `@name` for security groups | `nodes.yaml` can refer to a group by name; the module looks it up | no hard-coded IDs to drift |
| State in S3 (MinIO), key `openstack/<stack>/...` | moved from local files on 2026-10-17 | locking, no state on a laptop |
| The old stacks | kept in `../archive/{infra-v1,nodes-v1}` with a `RETIRED - do not apply` notice | reference only; their state was emptied |

## How the live VMs were moved (no recreation)
1. **Read the v1 values** (IDs, flavors, IPs, security groups) into `nodes.yaml` and `infra.yaml`.
2. **Test with one new VM** from v2 first, to prove the domain and IP came out right.
3. **Adopt, don't recreate:** `scripts/adopt-node.sh <env-dir> <name>` prints the IDs; `--run` does `terraform import` for the port, instance, floating IP, association and DNS records.
   `terraform plan` must then show **no replace** before anything is applied. `NO_DNS=1` when infra owns the records; it skips anything already in state.
4. **Rename with `moved` blocks** instead of recreating: for example `module.node["prod-c1"]` to `["c1"]`, and later `["db"]` to `["db1"]`
   (`environments/prod/moved.tf`, safe to delete once applied everywhere). A rename changes the Nova name in place; the VM, port and floating IP stay.
5. **Retire v1:** `terraform state rm` of all entries in both v1 stacks (32 and 55 resources), after backing the state up.
6. **Decommission** what was no longer needed: `c2`, `w4` to `w6` (old), the haproxy VM and the test VMs `web1`/`web2` (by editing `nodes.yaml` and applying).

## Traps found, and how they were fixed
| Trap | Fix |
|---|---|
| `terraform plan` wanted to destroy the whole old stack when pointed at the new state | adopt first, `plan` must be clean before any `apply` |
| Two security groups named `default` | look up by ID; later by name through a `@name` lookup |
| Import addresses wrong after DNS records became conditional (`count`) | `a[0]`, `ptr[0]`; moved blocks inside the node module |
| `manage_dns` not reaching the module | a variable pass-through that a formatter had hidden; fixed |
| `409 Port ... is still in use` after `-replace` | Nova leaves a stale `device_id` on the port; clear it through the Neutron API (the CLI call is a no-op): `scripts/clear-stale-port.sh` |
| An orphan instance after a quota failure made `openstack server list` return 500 | delete the instance by ID |
| `FloatingIPNotFound` on deleting an adopted VM | the association and the floating IP are destroyed in parallel; run `apply` again |
| Image resource always changed | `image_cache_path` depends on who runs Terraform: ignored |
| Control-plane security group wide open | `k8s` group rules limited to `192.168.2.0/24` and `10.0.1.0/24`; 443 and ICMP stay open |
| Metrics server unhealthy on new controllers | patched with `--kubelet-insecure-tls` in the controller cloud-init |
| Joined workers missing the join file | per-cluster join file `/nfsshare/join-<cluster>.sh`, 5 retries in the worker template |
| `sed -i` and shell habits (macOS BSD `sed`, zsh) | use a function instead of a variable holding a command; quote globs; `status` is read-only in zsh |

## The rebuild of the prod Kubernetes cluster that followed (2026-10-19)
Once VMs had proper names, the prod cluster was rebuilt from cloud-init so nodes register with the right names, with the workloads parked on the QA cluster
meanwhile. Full procedure and what really happened: `prod-k8s-rebuild.md`; the backup proof: `finance-db-restore.md`; the etcd restore rehearsal: `etcd-restore-rehearsal.md`.

## Rules to keep (so v2 stays maintainable)
1. Edit `nodes.yaml` / `infra.yaml`, not the modules, for ordinary changes.
2. Never put the environment in a name. Never rely on list order.
3. After any import, rename or `moved`: `terraform plan` must show no replace of a VM. If it does, stop.
4. A change that is not in Terraform (load balancers, secrets, Placement) goes in `ARCHITECTURE.md` under "What Terraform does not manage" and in `../CHANGELOG.md`.
