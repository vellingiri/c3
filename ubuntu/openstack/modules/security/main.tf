resource "openstack_networking_secgroup_v2" "basic" {
  name        = var.name
  description = var.description
}

resource "openstack_networking_secgroup_rule_v2" "ingress" {
  for_each = var.ingress_rules

  security_group_id = openstack_networking_secgroup_v2.basic.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = each.value.protocol
  port_range_min    = try(each.value.port_min, null)
  port_range_max    = try(each.value.port_max, null)
  remote_ip_prefix  = try(each.value.cidr, "0.0.0.0/0")
}

# v1 had one hand-written resource per rule; map them onto the keyed rules.
moved {
  from = openstack_networking_secgroup_rule_v2.allow_icmp
  to   = openstack_networking_secgroup_rule_v2.ingress["icmp"]
}

moved {
  from = openstack_networking_secgroup_rule_v2.allow_6443
  to   = openstack_networking_secgroup_rule_v2.ingress["tcp-6443"]
}

moved {
  from = openstack_networking_secgroup_rule_v2.allow_10250
  to   = openstack_networking_secgroup_rule_v2.ingress["tcp-10250"]
}

moved {
  from = openstack_networking_secgroup_rule_v2.allow_10259
  to   = openstack_networking_secgroup_rule_v2.ingress["tcp-10259"]
}

moved {
  from = openstack_networking_secgroup_rule_v2.allow_10257
  to   = openstack_networking_secgroup_rule_v2.ingress["tcp-10257"]
}

moved {
  from = openstack_networking_secgroup_rule_v2.allow_2379_2380
  to   = openstack_networking_secgroup_rule_v2.ingress["tcp-2379-2380"]
}

moved {
  from = openstack_networking_secgroup_rule_v2.allow_443
  to   = openstack_networking_secgroup_rule_v2.ingress["tcp-443"]
}
