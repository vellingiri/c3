locals {
  zone = var.zone_name

  # records that also get a PTR in the reverse zone
  ptr_records = { for k, r in var.records : k => r if try(r.ptr, false) }
}

resource "openstack_dns_zone_v2" "forward" {
  name  = var.zone_name
  email = var.email
  type  = "PRIMARY"
  ttl   = 6000
}

resource "openstack_dns_zone_v2" "reverse" {
  name  = var.reverse_zone_name
  email = var.email
  type  = "PRIMARY"
  ttl   = 6000
}

# key "@" is the zone apex
resource "openstack_dns_recordset_v2" "forward" {
  for_each = var.records

  zone_id = openstack_dns_zone_v2.forward.id
  name    = each.key == "@" ? var.zone_name : "${each.key}.${var.zone_name}"
  type    = "A"
  ttl     = 3000
  records = [each.value.ip]
}

resource "openstack_dns_recordset_v2" "ptr" {
  for_each = local.ptr_records

  zone_id = openstack_dns_zone_v2.reverse.id
  name    = "${split(".", each.value.ip)[3]}.${var.reverse_zone_name}"
  type    = "PTR"
  ttl     = 3000
  records = ["${each.key}.${var.zone_name}"]
}

# ---- re-keying of the old hand-written records (no recreation) ----
moved {
  from = openstack_dns_recordset_v2.cloud_f
  to   = openstack_dns_recordset_v2.forward["c3"]
}

moved {
  from = openstack_dns_recordset_v2.cloud_r
  to   = openstack_dns_recordset_v2.ptr["c3"]
}

moved {
  from = openstack_dns_recordset_v2.repo_f
  to   = openstack_dns_recordset_v2.forward["repo"]
}

moved {
  from = openstack_dns_recordset_v2.repo_r
  to   = openstack_dns_recordset_v2.ptr["repo"]
}

moved {
  from = openstack_dns_recordset_v2.haproxy_f
  to   = openstack_dns_recordset_v2.forward["haproxy"]
}

moved {
  from = openstack_dns_recordset_v2.haproxy_r
  to   = openstack_dns_recordset_v2.ptr["haproxy"]
}

moved {
  from = openstack_dns_recordset_v2.backup_f
  to   = openstack_dns_recordset_v2.forward["backup"]
}

moved {
  from = openstack_dns_recordset_v2.backup_r
  to   = openstack_dns_recordset_v2.ptr["backup"]
}

moved {
  from = openstack_dns_recordset_v2.website_root_f
  to   = openstack_dns_recordset_v2.forward["@"]
}

moved {
  from = openstack_dns_recordset_v2.website_www_f
  to   = openstack_dns_recordset_v2.forward["www"]
}

moved {
  from = openstack_dns_recordset_v2.website_rdu
  to   = openstack_dns_recordset_v2.forward["rdu"]
}

moved {
  from = openstack_dns_recordset_v2.argo_f
  to   = openstack_dns_recordset_v2.forward["argo"]
}

moved {
  from = openstack_dns_recordset_v2.qa_f
  to   = openstack_dns_recordset_v2.forward["qa"]
}
