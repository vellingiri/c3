resource "openstack_images_image_v2" "images" {
  for_each = var.img

  name             = each.value.name
  container_format = "bare"
  disk_format      = "qcow2"
  visibility       = "public"

  local_file_path  = each.value.local_file_path
}

