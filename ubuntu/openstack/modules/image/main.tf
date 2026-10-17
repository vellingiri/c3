resource "openstack_images_image_v2" "images" {
  for_each = var.images

  name             = each.key
  container_format = "bare"
  disk_format      = "qcow2"
  visibility       = "public"
  local_file_path  = each.value

  lifecycle {
    # Defaults to $HOME/.terraform/image_cache of whoever runs Terraform. It is a
    # property of the client machine, not of the Glance image, so it must not
    # produce a diff when the stack is run from a different server or user.
    ignore_changes = [image_cache_path]
  }
}

# v1 keyed these img1/img2; re-key by image name without recreating.
moved {
  from = openstack_images_image_v2.images["img1"]
  to   = openstack_images_image_v2.images["ubuntu2404"]
}

moved {
  from = openstack_images_image_v2.images["img2"]
  to   = openstack_images_image_v2.images["debian13"]
}
