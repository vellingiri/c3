# Replaced VMs failed with "Port ... is still in use" (fixed 2026-10-20)

## Symptom
`terraform apply -replace='module.node["db-witness"].openstack_compute_instance_v2.this'` destroyed the VM, then failed to create the new one:
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

## Other things learned in the same session (OpenStack)
- **A `SHUTOFF` server still reserves its memory in Nova.** Stopping QA VMs to make room for scratch VMs frees nothing; only deleting does. Capacity
  needed for a rehearsal must be found by deleting something or raising `ram_allocation_ratio` (still 1.1).
- `openstack server create --nic net-id=...,v4-fixed-ip=...` is rejected on this cloud (400 on `networks`); create a port with the fixed IP and use `--port`.
- Several security groups are named `default` (one per project): pass the ID.
