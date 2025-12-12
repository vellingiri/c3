########################################
# Forward DNS Zone
########################################
resource "openstack_dns_zone_v2" "forward" {
  name  = var.dns_zone_name
  email = var.dns_email
  type  = "PRIMARY"
  ttl   = 6000
}

########################################
# Reverse DNS Zone
########################################
resource "openstack_dns_zone_v2" "reverse" {
  name  = var.reverse_zone_name
  email = var.dns_email
  type  = "PRIMARY"
  ttl   = 6000
}

resource "openstack_dns_recordset_v2" "cloud_f" {
  zone_id = openstack_dns_zone_v2.forward.id
  name    = "cloud.${var.dns_zone_name}"
  type    = "A"
  ttl     = 3000
  records = ["192.168.2.15"]
}
resource "openstack_dns_recordset_v2" "cloud_r" {
  zone_id = openstack_dns_zone_v2.reverse.id
  name    = "15.${var.reverse_zone_name}"
  type    = "PTR"
  ttl     = 3000
  records = ["cloud.${var.dns_zone_name}"]
}

resource "openstack_dns_recordset_v2" "repo_f" {
  zone_id = openstack_dns_zone_v2.forward.id
  name    = "repo.${var.dns_zone_name}"
  type    = "A"
  ttl     = 3000
  records = ["192.168.2.10"]
}
resource "openstack_dns_recordset_v2" "repo_r" {
  zone_id = openstack_dns_zone_v2.reverse.id
  name    = "10.${var.reverse_zone_name}"
  type    = "PTR"
  ttl     = 3000
  records = ["repo.${var.dns_zone_name}"]
}
