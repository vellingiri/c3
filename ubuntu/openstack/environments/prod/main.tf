locals {
  # security groups infra exports by name, for nodes.yaml entries written as "@name"
  sg_by_name = try(data.terraform_remote_state.infra.outputs.security_group_ids, {})

  cfg      = yamldecode(file("${path.module}/${var.nodes_file}"))
  defaults = local.cfg.defaults

  # Merge defaults into every node; per-node `vars` override default vars.
  nodes = {
    for name, n in local.cfg.nodes : name => {
      role    = n.role
      flavor  = n.flavor
      image   = try(n.image, local.defaults.image)
      keypair = try(n.keypair, local.defaults.keypair)
      security_group_ids = [
        for g in try(n.security_group_ids, local.defaults.security_group_ids) :
        startswith(g, "@") ? local.sg_by_name[trimprefix(g, "@")] : g
      ]
      private_ip = try(n.ip, null)
      domain     = try(n.domain, local.defaults.domain)
      manage_dns = try(n.manage_dns, true)
      vars       = merge(local.defaults.vars, try(n.vars, {}))
    }
  }
}

# The database HA group (db1, db2 and the witness dbw): every member needs the list of members and the shared passwords to set itself up.
# Only these roles get them in their user data.
locals {
  db_ha_roles = ["database", "witness"]
  db_ha_members = join(",", [
    for name, n in local.nodes : "${name}=${n.private_ip}" if contains(local.db_ha_roles, n.role)
  ])
  db_ha_vars = {
    ha_members              = local.db_ha_members
    ha_witness              = join(",", [for name, n in local.nodes : name if n.role == "witness"])
    ha_postgres_password    = var.db_ha_postgres_password
    ha_replication_password = var.db_ha_replication_password
    ha_rest_password        = var.db_ha_rest_password
    ha_ntfy_url             = var.db_ha_ntfy_url
  }
}

check "db_ha_members_have_addresses" {
  assert {
    condition     = alltrue([for name, n in local.nodes : n.private_ip != null if contains(local.db_ha_roles, n.role)])
    error_message = "every database / witness node in nodes.yaml needs `ip:` (its fixed private address); the group is built from those addresses."
  }
}

# Shared infra (network, keypair, DNS zones) comes from the infra stack's state.
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "terraform-state"
    key    = "openstack/infra/terraform.tfstate"
    region = "us-east-1"

    endpoints = {
      s3 = "http://192.168.2.4:9000"
    }

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    use_path_style              = true
    insecure                    = true
  }
}

module "node" {
  source   = "../../modules/node"
  for_each = local.nodes

  environment = local.cfg.environment

  name               = each.key
  role               = each.value.role
  flavor             = each.value.flavor
  image              = each.value.image
  keypair            = each.value.keypair
  security_group_ids = each.value.security_group_ids
  domain             = each.value.domain
  manage_dns         = each.value.manage_dns
  private_ip         = each.value.private_ip
  cloud_init_vars    = contains(local.db_ha_roles, each.value.role) ? merge(each.value.vars, local.db_ha_vars) : each.value.vars
  cloud_init_dir     = "${path.module}/../../cloud-init"

  network_id        = data.terraform_remote_state.infra.outputs.private_network_id
  subnet_id         = data.terraform_remote_state.infra.outputs.private_subnet_id
  floating_ip_pool  = data.terraform_remote_state.infra.outputs.external_network_name
  forward_zone_id   = data.terraform_remote_state.infra.outputs.dns_forward_zone_ids["${each.value.domain}."]
  reverse_zone_id   = data.terraform_remote_state.infra.outputs.dns_reverse_zone_id
  reverse_zone_name = data.terraform_remote_state.infra.outputs.reverse_zone_name
}
