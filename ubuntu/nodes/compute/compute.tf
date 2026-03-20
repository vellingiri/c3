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

  lifecycle {
    create_before_destroy = true
  }

  fixed_ip {
    subnet_id = var.private_subnet_id
  }
  security_group_ids = [
    "9c0bdbc7-1184-413a-a390-13ecc7982c33",  # default (existing)
    "d97cfded-bd35-4795-999f-7a2b7c8e1b98"   # k8s (existing)
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
  each.key == "gitlab" ?
  "${path.module}/../configs/gitlab.yaml" :
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

