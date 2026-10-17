# RETIRED – do not apply

This was the v1 `nodes` stack. Its Terraform state was emptied on 2026-10-17
(`terraform state rm` of all 55 entries; backup in the state owner's home dir).
All VMs are now managed by `ubuntu/openstack/environments/{prod,qa}`.

Running `terraform apply` here would try to create every VM again.
Kept for reference only.
