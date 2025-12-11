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

########################################
# Static recording for testing
########################################
resource "openstack_dns_recordset_v2" "test_record" {
  zone_id = openstack_dns_zone_v2.forward.id
  name    = "cloud.${var.dns_zone_name}"
  type    = "A"
  ttl     = 3000
  records = ["192.168.2.15"]
}

