output "private_network_id" {
  value = module.network.private_network_id
}

output "private_subnet_id" {
  value = module.network.private_subnet_id
}

output "external_network_name" {
  value = module.network.external_network_name
}

output "keypair_name" {
  value = module.keypair.keypair_name
}

output "dns_forward_zone_id" {
  value = module.dns.forward_zone_id
}

output "dns_reverse_zone_id" {
  value = module.dns.reverse_zone_id
}

output "reverse_zone_name" {
  value = module.dns.reverse_zone_name
}

