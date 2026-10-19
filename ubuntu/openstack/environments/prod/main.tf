locals {
  cfg      = yamldecode(file("${path.module}/${var.nodes_file}"))
  defaults = local.cfg.defaults

  # Merge defaults into every node; per-node `vars` override default vars.
  nodes = {
    for name, n in local.cfg.nodes : name => {
      role               = n.role
      flavor             = n.flavor
      image              = try(n.image, local.defaults.image)
      keypair            = try(n.keypair, local.defaults.keypair)
      security_group_ids = try(n.security_group_ids, local.defaults.security_group_ids)
      domain             = try(n.domain, local.defaults.domain)
      manage_dns         = try(n.manage_dns, true)
      vars               = merge(local.defaults.vars, try(n.vars, {}))
    }
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
  cloud_init_vars    = each.value.vars
  cloud_init_dir     = "${path.module}/../../cloud-init"

  network_id        = data.terraform_remote_state.infra.outputs.private_network_id
  subnet_id         = data.terraform_remote_state.infra.outputs.private_subnet_id
  floating_ip_pool  = data.terraform_remote_state.infra.outputs.external_network_name
  forward_zone_id   = data.terraform_remote_state.infra.outputs.dns_forward_zone_id
  reverse_zone_id   = data.terraform_remote_state.infra.outputs.dns_reverse_zone_id
  reverse_zone_name = data.terraform_remote_state.infra.outputs.reverse_zone_name
}
