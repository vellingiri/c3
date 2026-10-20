# OpenStack – Terraform

```
infra/                   shared cloud: networks, router, keypair, security group,
                         images, DNS zones + static records   (infra.yaml)
environments/prod/       VMs for prod                         (nodes.yaml)
environments/qa/         VMs for qa                           (nodes.yaml)
modules/                 network, security, keypair, image, dns, node
cloud-init/*.tftpl       reusable cloud-init parts, composed per role
scripts/adopt-node.sh    bring an existing VM under Terraform without recreating it
scripts/k8s-copy-between.sh  copy k8s objects between clusters through two local kubeconfigs (secrets stay in the pipe)
scripts/db-replica-setup.sh  make db2 a streaming replica of db1 (re-runnable);  scripts/db-replication-status.sh checks it
docs/                    runbooks: db-replication (db1/db2 failover), octavia-finance-lb (finance-lb, argo-lb),
                         finance-db-restore (backups), prod-k8s-rebuild, etcd-restore-rehearsal
```

Apply order: `infra` first, then `environments/<env>`. Environments read infra's
outputs through its remote state (`openstack/infra/terraform.tfstate`).

## Day to day
- Add/remove/resize VMs: edit `environments/<env>/nodes.yaml`, then `terraform plan` / `apply`.
- Change network, DNS records, security rules, images: edit `infra/infra.yaml`.
- Every entry is keyed by a stable name (`for_each`), so adding or removing one
  never shifts or recreates the others.

## Rules the design enforces
- `user_data`, `image_name`, `network` and the port's `fixed_ip` are in `ignore_changes`.
  Editing a cloud-init template or a default never replaces a running VM.
  Rebuild one on purpose with
  `terraform apply -replace='module.node["<name>"].openstack_compute_instance_v2.this'`.
- VM names never contain the environment. The environment is a tag and metadata on
  the instance, port and floating IP (`openstack server list --tags qa`).
- Each environment has its own DNS zone, set by `domain` in its `nodes.yaml`: prod nodes live
  in `prod.rdulinux.com` (`c1.prod.rdulinux.com`), qa in `qa.rdulinux.com` (`c1.qa.rdulinux.com`).
  Zones are listed in `infra/infra.yaml` (`dns.extra_zones`). Shared services (`db1`, `db2`, `runner`)
  override `domain: rdulinux.com`. `db1`/`db2` are the database hosts; `db.rdulinux.com` is an alias for the current primary (infra.yaml, TTL 60 s).
  OpenStack server names can repeat across environments; use the tag or the ID to tell them apart.
- Per-cluster join info lives in `/nfsshare/join-<cluster_name>.sh`.
- Records owned by `infra` (e.g. the load balancer name) use `manage_dns: false` on the node.
- `image_cache_path` is ignored: it depends on whoever runs Terraform.

## Adopting an existing VM
```
cd environments/prod
../../scripts/adopt-node.sh . <name>          # show IDs and the values to put in nodes.yaml
../../scripts/adopt-node.sh . <name> --run    # import; then `terraform plan` must show no replace
NO_DNS=1 ...                                  # when infra owns that VM's DNS records
```

## State
S3 (MinIO) bucket `terraform-state`: `openstack/infra/...`, `openstack/<env>/nodes/...`.
Needs `OS_*` credentials and the MinIO access keys in the environment.

Retired stacks are kept for reference in `../archive/` and must never be applied.

## Troubleshooting

### `409 Port ... is still in use` after replacing a VM
`terraform apply -replace='module.node["x"].openstack_compute_instance_v2.this'` deletes the VM but
Nova may leave the old server ID in the port's `device_id`, so the new VM cannot attach it.
Easiest: `scripts/clear-stale-port.sh <port-id>`. By hand: check, then clear it through the Neutron API (the `openstack port set --device ''` client call
ignores empty values and does nothing):

```bash
openstack port show <port-id> -c device_id -c device_owner        # old, destroyed server ID?
TOKEN=$(openstack token issue -f value -c id)
curl -s -X PUT "http://192.168.2.2:9696/v2.0/ports/<port-id>" \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"port": {"device_id": "", "device_owner": ""}}'
terraform apply                                                   # creates the VM on the same port and IP
```
The port, its fixed IP and its floating IP are kept.

### Server names repeat across environments
`c1`, `w1`... exist in both prod and qa by design (the environment is a tag, not part of the name).
Use the ID, `--tags prod|qa`, or the `Env` column from `scripts/openstack-shortcuts.sh`.

### `FloatingIPNotFound` while deleting an adopted VM
Resources brought in with `adopt-node.sh` have no dependency info in state until an apply touches them,
so on delete Terraform may destroy the floating IP association and the floating IP in parallel and the
association fails ("floating IP could not be found"). The FIP is already gone, so just run
`terraform apply` again; it drops the stale entries. VMs created by Terraform are not affected.
