locals {
  # Ordered cloud-init parts per role. Add a role = add a line here + a template.
  role_parts = {
    controller   = ["base", "k8s-common", "k8s-controller"]
    worker       = ["base", "k8s-common", "k8s-worker"]
    gitlab       = ["base", "gitlab"]
    runner       = ["base", "runner"]
    database     = ["base", "database"]
    loadbalancer = ["base", "haproxy"]
  }

  fqdn = "${var.name}.${var.domain}"

  template_vars = merge(var.cloud_init_vars, {
    hostname = var.name
    fqdn     = local.fqdn
    domain   = var.domain
    role     = var.role

    # shared files rendered into cloud-init (single source of truth)
    etcd_snapshot_script  = file("${var.cloud_init_dir}/files/etcd-snapshot.sh")
    etcd_snapshot_service = file("${var.cloud_init_dir}/files/etcd-snapshot.service")
    etcd_snapshot_timer   = file("${var.cloud_init_dir}/files/etcd-snapshot.timer")
  })
}

data "cloudinit_config" "this" {
  gzip          = false
  base64_encode = false

  dynamic "part" {
    for_each = local.role_parts[var.role]
    content {
      filename     = "${part.key}-${part.value}.yaml"
      content_type = "text/cloud-config"
      # Lists (runcmd, write_files) from every part are appended, in order.
      merge_type = "list(append)+dict(recurse_array)+str()"
      content    = templatefile("${var.cloud_init_dir}/${part.value}.yaml.tftpl", local.template_vars)
    }
  }
}

resource "openstack_networking_port_v2" "this" {
  name               = "${var.name}-port"
  network_id         = var.network_id
  security_group_ids = var.security_group_ids

  fixed_ip {
    subnet_id = var.subnet_id
  }

  lifecycle {
    # Neutron refuses fixed_ips updates once the IP has a floating IP, even to
    # the same value. Only matters at creation, so ignore it afterwards.
    ignore_changes = [fixed_ip]
  }
}

resource "openstack_compute_instance_v2" "this" {
  name        = var.name
  flavor_name = var.flavor
  image_name  = var.image
  key_pair    = var.keypair
  user_data   = data.cloudinit_config.this.rendered

  network {
    port = openstack_networking_port_v2.this.id
  }

  lifecycle {
    # cloud-init only runs on first boot, so editing a template must never
    # replace a running VM. To rebuild one on purpose:
    #   terraform apply -replace='module.node["<name>"].openstack_compute_instance_v2.this'
    # network is immutable on a live VM; ignoring it lets VMs created outside Terraform
    # (network by name, no explicit port) be adopted without a replace.
    ignore_changes = [user_data, image_name, network]
  }
}

resource "openstack_networking_floatingip_v2" "this" {
  pool = var.floating_ip_pool
}

resource "openstack_networking_floatingip_associate_v2" "this" {
  floating_ip = openstack_networking_floatingip_v2.this.address
  port_id     = openstack_networking_port_v2.this.id

  depends_on = [openstack_compute_instance_v2.this]
}

resource "openstack_dns_recordset_v2" "a" {
  count   = var.manage_dns ? 1 : 0
  zone_id = var.forward_zone_id
  name    = "${local.fqdn}."
  type    = "A"
  ttl     = 3000
  records = [openstack_networking_floatingip_v2.this.address]
}

resource "openstack_dns_recordset_v2" "ptr" {
  count   = var.manage_dns ? 1 : 0
  zone_id = var.reverse_zone_id
  name    = "${split(".", openstack_networking_floatingip_v2.this.address)[3]}.${var.reverse_zone_name}"
  type    = "PTR"
  ttl     = 3000
  records = ["${local.fqdn}."]
}

# manage_dns made the records conditional; keep already-adopted state addresses valid.
moved {
  from = openstack_dns_recordset_v2.a
  to   = openstack_dns_recordset_v2.a[0]
}

moved {
  from = openstack_dns_recordset_v2.ptr
  to   = openstack_dns_recordset_v2.ptr[0]
}
