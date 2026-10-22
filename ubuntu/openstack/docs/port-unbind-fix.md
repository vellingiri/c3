# Replaced VMs failed with "Port ... is still in use" (fixed 2026-10-20)

## Symptom
`terraform apply -replace='module.node["dbw1"].openstack_compute_instance_v2.this'` destroyed the VM, then failed to create the new one:
`409 Port 575d33f2-... is still in use`. The port belongs to Terraform (a separate resource), so it survives the replace, but it still said
`device_id = <the deleted server>`. Every VM replace would have hit this.

## Cause
Nova clears `device_id` / `device_owner` on a port it did not create when the server is deleted. That update was **refused by Neutron's policy**
(`/var/log/nova/nova-compute.log`: `Unable to clear device ID for port ...: Forbidden ... rule:update_port:device_id ... is disallowed`).
Nova talks to Neutron as the user `neutron` (`[neutron]` section of `/etc/nova/nova.conf`, project `service`); with `enforce_new_defaults = true`
that kind of update needs the **`service`** role, and the user only had `admin`. (The `nova` user has both.)

## Fix (on `c3`, by hand; these are Keystone/Nova settings, not in Terraform)
```bash
openstack role add --user neutron --project service service     # the missing role
systemctl restart nova-compute                                  # so Nova's cached token has the new role (running guests are not touched)
```

## Proof
A throwaway server (`m1.tiny`) on a pre-made port: after `openstack server delete`, the port's `device_id` and `device_owner` were empty and no new
"Unable to clear device ID" error appeared. The port was then deleted. Then the witness replace was repeated (see CHANGELOG).
Check any time: `openstack role assignment list --user neutron --names` must show `admin` and `service`; `grep -c "Unable to clear device ID" /var/log/nova/nova-compute.log` must not grow.

## If it ever happens again
Clear the stale binding on the port (only after confirming the server is gone) and apply again:
`python3 -c "import openstack; c=openstack.connect(); c.network.update_port('<port id>', device_id='', device_owner='')"` on `c3`
(the CLI's `openstack port set --device ''` does **not** clear it).

## Second trap: a VM adopted with a port that Nova had created (`db1`, 2026-10-20)
Replacing `db1` destroyed the VM, and the create then failed with `Could not find any matching port 0513f21a-...`. `db1` came from the pre-Terraform
VM `db`, whose port Nova itself had made, so Nova deleted the port together with the VM while Terraform's state still listed it.
Fix, no `-replace` needed once the VM is gone: **plain `terraform apply`**. It sees the port missing, recreates `db1-port` at the pinned `10.0.1.191`,
the instance and the floating IP link. From then on `db1` has a Terraform-owned port like the others.
Audit afterwards (every VM port of prod and qa): all are named `<vm>-port` and tagged with the environment, i.e. Terraform-owned; only the Octavia amphorae
have Nova/Octavia-made ports, and those are not Terraform's. So this cannot happen again for the database group; if a plain `apply` after a failed replace is
ever needed, the symptom is exactly that error message.

## Other things learned in the same session (OpenStack)
- **A `SHUTOFF` server still reserves its memory in Nova.** Stopping QA VMs to make room for scratch VMs frees nothing; only deleting does. Capacity
  needed for a rehearsal must be found by deleting something or raising `ram_allocation_ratio` (done the same day: 1.1 -> 1.2, see below).
- `openstack server create --nic net-id=...,v4-fixed-ip=...` is rejected on this cloud (400 on `networks`); create a port with the fixed IP and use `--port`.
- Several security groups are named `default` (one per project): pass the ID.

## Capacity change and scratch rehearsal (OpenStack actions, 2026-10-20)
- **`ram_allocation_ratio` 1.1 -> 1.2** in `/etc/nova/nova.conf` `[DEFAULT]` on `c3` (backup `/root/nova.conf.bak-20261020-ram`, deleted 2026-10-22; superseded by `nova.conf.bak-20261022-ratio12`), then `systemctl restart nova-compute`; the Placement inventory `MEMORY_MB` showed 1.2 about a minute later. Headroom went from about 1.5 GB to about 9 GB. To undo: restore the backup and restart `nova-compute`. Disk is the next limit (`DISK_GB` ratio 1.5, 204 GB allowed, 180 used): a 10 GB flavor per scratch VM does not fit three times, so the rehearsal used a throwaway flavor `scratch-tiny` (2 GB RAM, 1 vCPU, 7 GB disk; a flavor with disk 0 gives a 1 GB root file system and the install fails).
- **Scratch VMs** `dbt1`, `dbt2`, `dbt-witness` (10.0.1.231 to .233) and their ports and the flavor were created for the whole-group rehearsal (`db-ha-patroni.md`) and **all deleted afterwards** (checked: no server, port or flavor left).
- **Cleanup of retired workers:** `w4` and `w5` VMs were removed by you through Terraform; their now-dead members were deleted from `finance-pool` and `argo-backend` and the Kubernetes nodes were deleted (`kubectl delete node w4 w5`). Both front doors stayed 200.
