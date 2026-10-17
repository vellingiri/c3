resource "openstack_networking_network_v2" "external" {
  name           = var.external.name
  admin_state_up = true
  shared         = true
  external       = true

  segments {
    network_type     = "flat"
    physical_network = var.external.physical_network
  }
}

resource "openstack_networking_subnet_v2" "external_subnet" {
  name        = "${var.external.name}_subnet"
  network_id  = openstack_networking_network_v2.external.id
  cidr        = var.external.cidr
  gateway_ip  = var.external.gateway_ip
  ip_version  = 4
  enable_dhcp = true

  allocation_pool {
    start = var.external.pool_start
    end   = var.external.pool_end
  }
}

resource "openstack_networking_network_v2" "private" {
  name           = "private_network"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "private_subnet" {
  name            = "private_subnet"
  network_id      = openstack_networking_network_v2.private.id
  cidr            = var.private.cidr
  gateway_ip      = var.private.gateway_ip
  ip_version      = 4
  dns_nameservers = var.private.dns_nameservers
}

resource "openstack_networking_router_v2" "router" {
  name                = "main_router"
  admin_state_up      = true
  external_network_id = openstack_networking_network_v2.external.id
}

resource "openstack_networking_router_interface_v2" "router_private" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.private_subnet.id
}
