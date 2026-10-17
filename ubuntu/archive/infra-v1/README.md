# RETIRED – do not apply

This was the v1 `infra` stack. Its Terraform state was emptied on 2026-10-17
(`terraform state rm` of all 32 entries). The live resources (networks, router,
keypair, security group, images, DNS zones and records) are now managed by
`ubuntu/openstack/infra`, state key `openstack/infra/terraform.tfstate`.

Running `terraform apply` here would try to create all of them again.
Kept for reference only.
