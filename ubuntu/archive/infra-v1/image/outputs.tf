output "images" {
  value = {
    for k, img in openstack_images_image_v2.images :
    k => img.name
  }
}

