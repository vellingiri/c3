output "forward_records" {
  value = openstack_dns_recordset_v2.forward_records[*].name
}

output "reverse_records" {
  value = openstack_dns_recordset_v2.ptr_records[*].name
}

