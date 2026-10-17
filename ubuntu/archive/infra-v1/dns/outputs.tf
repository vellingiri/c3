output "forward_zone_id" {
  value = openstack_dns_zone_v2.forward.id
}

output "reverse_zone_id" {
  value = openstack_dns_zone_v2.reverse.id
}

output "reverse_zone_name" {
  value = openstack_dns_zone_v2.reverse.name
}

