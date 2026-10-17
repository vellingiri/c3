#########################################
# VM Names
#########################################
output "vm_names" {
  value = module.compute.vm_names
}

#########################################
# Floating IPs for all VMs
#########################################
output "floating_ips" {
  value = module.compute.floating_ips
}

#########################################
# DNS Records (Optional)
#########################################
output "dns_forward_records" {
  value = module.dns_records.forward_records
}

#output "dns_reverse_records" {
#  value = module.dns_records.reverse_records
#}

