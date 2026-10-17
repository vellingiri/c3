output "info" {
  value = {
    name        = var.name
    role        = var.role
    fixed_ip    = openstack_networking_port_v2.this.all_fixed_ips[0]
    floating_ip = openstack_networking_floatingip_v2.this.address
    fqdn        = local.fqdn
  }
}
