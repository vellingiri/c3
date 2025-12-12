# Security group for GitLab
resource "openstack_networking_secgroup_v2" "gitlab_sg" {
  name        = "gitlab"
  description = "GitLab access"
}

resource "openstack_networking_secgroup_rule_v2" "gitlab_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  security_group_id = openstack_networking_secgroup_v2.gitlab_sg.id
}

resource "openstack_networking_secgroup_rule_v2" "gitlab_http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  security_group_id = openstack_networking_secgroup_v2.gitlab_sg.id
}

resource "openstack_networking_secgroup_rule_v2" "gitlab_https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  security_group_id = openstack_networking_secgroup_v2.gitlab_sg.id
}

resource "openstack_networking_secgroup_rule_v2" "gitlab_registry" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 5050
  port_range_max    = 5050
  security_group_id = openstack_networking_secgroup_v2.gitlab_sg.id
}

# Port on private network
data "openstack_networking_network_v2" "private" {
  name = var.private_network_name
}

resource "openstack_networking_port_v2" "gitlab_port" {
  name       = "gitlab-port"
  network_id = data.openstack_networking_network_v2.private.id

  security_group_ids = [
    openstack_networking_secgroup_v2.gitlab_sg.id,
  ]
}

# GitLab VM
resource "openstack_compute_instance_v2" "gitlab" {
  name        = "gitlab"
  flavor_name = var.gitlab_flavor
  image_name  = var.gitlab_image
  key_pair    = var.gitlab_keypair

  network {
    port = openstack_networking_port_v2.gitlab_port.id
  }
}

# Floating IP
data "openstack_networking_network_v2" "public" {
  name = var.public_network_name
}

resource "openstack_networking_floatingip_v2" "gitlab_fip" {
  pool = data.openstack_networking_network_v2.public.name
}

resource "openstack_networking_floatingip_associate_v2" "gitlab_fip_assoc" {
  floating_ip = openstack_networking_floatingip_v2.gitlab_fip.address
  port_id     = openstack_networking_port_v2.gitlab_port.id
}

output "gitlab_floating_ip" {
  value = openstack_networking_floatingip_v2.gitlab_fip.address
}

