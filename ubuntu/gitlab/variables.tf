variable "gitlab_flavor" {
  type    = string
  default = "m1.large"
}

variable "gitlab_image" {
  type    = string
  default = "ubuntu2404"
}

variable "gitlab_keypair" {
  type    = string
  default = "default-key"
}

variable "private_network_name" {
  type    = string
  default = "private_network"
}

variable "public_network_name" {
  type    = string
  default = "external_network"
}

