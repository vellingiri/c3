############################################################
# READ INFRA REMOTE STATE
############################################################
data "terraform_remote_state" "infra" {
  backend = "s3"

  config = {
    bucket = "terraform-state"
    key    = "infra/terraform.tfstate"
    region = "us-east-1"

    endpoints = {
      s3 = "http://192.168.2.196:9000"
    }

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true

    #force_path_style = true
    use_path_style = true
    insecure       = true
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

