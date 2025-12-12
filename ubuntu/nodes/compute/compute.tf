locals {
  vm_keys = keys(var.vm_names)
}

#############################################
# PORTS WITH FIXED IPs
#############################################
resource "openstack_networking_port_v2" "ports" {
  for_each   = var.vm_names
  name       = "${each.value}-port"
  network_id = var.private_network_id

  fixed_ip {
    subnet_id = var.private_subnet_id
  }
  security_group_ids = [
    "a20176f9-19d9-4800-9572-8d943f4d9847",  # default (existing)
    "712cbad5-8f80-480d-8b8b-06712a28141d"   # k8s (existing)
  ]

}

#############################################
# COMPUTE INSTANCES
#############################################
resource "openstack_compute_instance_v2" "vms" {
  for_each    = var.vm_names
  name        = each.value
  flavor_name = var.vm_flavors[each.key]
  image_name  = var.image_name
  key_pair    = var.keypair_name

   user_data = file(
  each.key == "controller" ?
  "${path.module}/../configs/master.yaml" :
  each.key == "rancher" ?
  "${path.module}/../configs/rancher.yaml" :
  "${path.module}/../configs/worker.yaml"
)

  network {
    port = openstack_networking_port_v2.ports[each.key].id
  }
}

#############################################
# FLOATING IPs
#############################################
resource "openstack_networking_floatingip_v2" "fips" {
  for_each = var.vm_names
  pool     = var.public_network_name
}

resource "openstack_compute_floatingip_associate_v2" "fip_assoc" {
  for_each    = var.vm_names
  floating_ip = openstack_networking_floatingip_v2.fips[each.key].address
  instance_id = openstack_compute_instance_v2.vms[each.key].id
}
#############################################
# OUTPUTS (NO DUPLICATE FILES!)
#############################################

output "vm_names" {
  value = values(var.vm_names)
}

# Floating IPs as list(string)
output "floating_ips" {
  value = [
    for f in openstack_networking_floatingip_v2.fips :
    f.address
  ]
}

