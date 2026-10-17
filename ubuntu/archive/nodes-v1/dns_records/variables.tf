variable "vm_names" {
  type = list(string)
}

variable "floating_ips" {
  type = list(string)
}

variable "domain" {
  type = string
}

variable "forward_zone_id" {
  type = string
}

variable "reverse_zone_id" {
  type = string
}

variable "reverse_zone_name" {
  type = string
}

