# OpenStack – Terraform

```
infra/                   shared cloud: networks, router, keypair, security group,
                         images, DNS zones + static records   (infra.yaml)
environments/prod/       VMs for prod                         (nodes.yaml)
environments/qa/         VMs for qa                           (nodes.yaml)
modules/                 network, security, keypair, image, dns, node
cloud-init/*.tftpl       reusable cloud-init parts, composed per role
scripts/adopt-node.sh    bring an existing VM under Terraform without recreating it
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
- Environments share one DNS zone and floating-IP pool, so non-prod names are
  prefixed (`qa-c1`, `qa-w1`, ...).
- Per-cluster join info lives in `/nfsshare/join-<cluster_name>.sh`.
- Records owned by `infra` (e.g. haproxy) use `manage_dns: false` on the node.
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
