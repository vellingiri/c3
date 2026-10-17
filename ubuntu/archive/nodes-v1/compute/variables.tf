variable "vm_names" {
  type = map(string)
}

variable "image_name" {
  type = string
}

variable "keypair_name" {
  type = string
}

variable "private_network_id" {
  type = string
}

variable "private_subnet_id" {
  type = string
}

variable "public_network_name" {
  type = string
}

variable "vm_flavors" {
  type = map(string)
}

