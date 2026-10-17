output "external_network_id" {
  value = openstack_networking_network_v2.external.id
}

output "external_network_name" {
  value = openstack_networking_network_v2.external.name
}

output "private_network_id" {
  value = openstack_networking_network_v2.private.id
}

output "private_subnet_id" {
  value = openstack_networking_subnet_v2.private_subnet.id
}
