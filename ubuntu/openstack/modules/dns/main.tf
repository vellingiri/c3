locals {
  # every zone we manage, by name (trailing dot): the main zone plus one zone per environment
  zone_ids = merge(
    { (var.zone_name) = openstack_dns_zone_v2.forward.id },
    { for name, z in openstack_dns_zone_v2.extra : name => z.id },
  )

  # records default to the main zone and to their map key as the name
  records = {
    for k, r in var.records : k => merge(r, {
      zone = try(r.zone, var.zone_name)
      name = try(r.name, k)
    })
  }

  # records that also get a PTR in the reverse zone
  ptr_records = { for k, r in local.records : k => r if try(r.ptr, false) }
}

resource "openstack_dns_zone_v2" "forward" {
  name  = var.zone_name
  email = var.email
  type  = "PRIMARY"
  ttl   = 6000
}

# one zone per environment (prod.rdulinux.com., qa.rdulinux.com., ...)
resource "openstack_dns_zone_v2" "extra" {
  for_each = toset(var.extra_zones)

  name  = each.value
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

# name "@" is the apex of the record's zone
resource "openstack_dns_recordset_v2" "forward" {
  for_each = local.records

  zone_id = local.zone_ids[each.value.zone]
  name    = each.value.name == "@" ? each.value.zone : "${each.value.name}.${each.value.zone}"
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
  records = ["${each.value.name}.${each.value.zone}"]
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

# lb.rdulinux.com (formerly haproxy) is retired: the A record is destroyed, the PTR of 192.168.2.5 moves to finance.
moved {
  from = openstack_dns_recordset_v2.ptr["lb"]
  to   = openstack_dns_recordset_v2.ptr["finance"]
}
