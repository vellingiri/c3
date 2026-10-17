#############################################
# EXTERNAL NETWORK (Provider network)
#############################################
resource "openstack_networking_network_v2" "external" {
  name           = var.external_network_name
  admin_state_up = true
  shared         = true
  external       = true

  segments {
    network_type      = "flat"
    physical_network  = var.public_physical_network
  }
}

#############################################
# EXTERNAL SUBNET
#############################################
resource "openstack_networking_subnet_v2" "external_subnet" {
  name            = "${var.external_network_name}_subnet"
  network_id      = openstack_networking_network_v2.external.id
  cidr            = var.external_subnet_cidr
  gateway_ip      = var.external_gateway_ip
  ip_version      = 4
  enable_dhcp     = true

  allocation_pool {
    start = var.external_allocation_start
    end   = var.external_allocation_end
  }
}

#############################################
# PRIVATE NETWORK
#############################################
resource "openstack_networking_network_v2" "private" {
  name           = "private_network"
  admin_state_up = true
}

#############################################
# PRIVATE SUBNET
#############################################
resource "openstack_networking_subnet_v2" "private_subnet" {
  name            = "private_subnet"
  network_id      = openstack_networking_network_v2.private.id
  cidr            = var.private_subnet_cidr
  gateway_ip      = var.private_gateway
  ip_version      = 4
  dns_nameservers = var.dns_nameservers
}

#############################################
# ROUTER
#############################################
resource "openstack_networking_router_v2" "router" {
  name                = "main_router"
  admin_state_up      = true
  external_network_id = openstack_networking_network_v2.external.id
}

#############################################
# ROUTER INTERFACE (PRIVATE → ROUTER)
#############################################
resource "openstack_networking_router_interface_v2" "router_private" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.private_subnet.id
}

