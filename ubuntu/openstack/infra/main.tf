locals {
  cfg = yamldecode(file("${path.module}/infra.yaml"))
}

module "network" {
  source   = "../modules/network"
  external = local.cfg.network.external
  private  = local.cfg.network.private
}

module "keypair" {
  source          = "../modules/keypair"
  name            = local.cfg.keypair.name
  public_key_path = local.cfg.keypair.public_key_path
}

module "security" {
  source        = "../modules/security"
  name          = local.cfg.security_group.name
  description   = local.cfg.security_group.description
  ingress_rules = local.cfg.security_group.ingress_rules
}

module "image" {
  source = "../modules/image"
  images = local.cfg.images
}

module "dns" {
  source            = "../modules/dns"
  zone_name         = local.cfg.dns.zone
  reverse_zone_name = local.cfg.dns.reverse_zone
  email             = local.cfg.dns.email
  records           = local.cfg.dns.records
}
