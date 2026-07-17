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
  name    = "c3.${var.dns_zone_name}"
  type    = "A"
  ttl     = 3000
  records = ["192.168.2.2"]
}
resource "openstack_dns_recordset_v2" "cloud_r" {
  zone_id = openstack_dns_zone_v2.reverse.id
  name    = "2.${var.reverse_zone_name}"
  type    = "PTR"
  ttl     = 3000
  records = ["c3.${var.dns_zone_name}"]
}

resource "openstack_dns_recordset_v2" "repo_f" {
  zone_id = openstack_dns_zone_v2.forward.id
  name    = "repo.${var.dns_zone_name}"
  type    = "A"
  ttl     = 3000
  records = ["192.168.2.3"]
}
resource "openstack_dns_recordset_v2" "repo_r" {
  zone_id = openstack_dns_zone_v2.reverse.id
  name    = "3.${var.reverse_zone_name}"
  type    = "PTR"
  ttl     = 3000
  records = ["repo.${var.dns_zone_name}"]
}

resource "openstack_dns_recordset_v2" "finance_f" {
  zone_id = openstack_dns_zone_v2.forward.id
  name    = "finance.${var.dns_zone_name}"
  type    = "A"
  ttl     = 3000
  records = ["192.168.2.5"]
}
resource "openstack_dns_recordset_v2" "finance_r" {
  zone_id = openstack_dns_zone_v2.reverse.id
  name    = "5.${var.reverse_zone_name}"
  type    = "PTR"
  ttl     = 3000
  records = ["finance.${var.dns_zone_name}"]
}
