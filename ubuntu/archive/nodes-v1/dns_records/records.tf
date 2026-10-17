########################################
# A Records
########################################

resource "openstack_dns_recordset_v2" "forward_records" {
  count = length(var.vm_names)

  zone_id = var.forward_zone_id

  name = "${var.vm_names[count.index]}.${trim(var.domain, ".")}."
  type = "A"

  # Floating IP only
  records = [var.floating_ips[count.index]]
}

########################################
# PTR Records
########################################

resource "openstack_dns_recordset_v2" "ptr_records" {
  count = length(var.vm_names)

  zone_id = var.reverse_zone_id

  name = "${split(".", var.floating_ips[count.index])[3]}.${var.reverse_zone_name}"
  type = "PTR"

  records = [
    "${var.vm_names[count.index]}.${trim(var.domain, ".")}."
  ]
}

