############################################################
# READ INFRA REMOTE STATE
############################################################
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "../infra/terraform.tfstate"
  }
}

############################################################
# COMPUTE MODULE
############################################################
module "compute" {
  source = "./compute"

  vm_names   = var.vm_names
  vm_flavors = var.vm_flavors
  image_name = var.image_name

  keypair_name = data.terraform_remote_state.infra.outputs.keypair_name

  private_network_id = data.terraform_remote_state.infra.outputs.private_network_id
  private_subnet_id  = data.terraform_remote_state.infra.outputs.private_subnet_id

  public_network_name = data.terraform_remote_state.infra.outputs.external_network_name
}

############################################################
# DNS RECORDS MODULE
############################################################
module "dns_records" {
  source = "./dns_records"

  forward_zone_id   = data.terraform_remote_state.infra.outputs.dns_forward_zone_id
  reverse_zone_id   = data.terraform_remote_state.infra.outputs.dns_reverse_zone_id
  reverse_zone_name = data.terraform_remote_state.infra.outputs.reverse_zone_name

  vm_names     = module.compute.vm_names
  floating_ips = module.compute.floating_ips

  domain = var.domain
}

