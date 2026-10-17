variable "external_network_name" {
  default = "external_network"
}

variable "external_subnet_cidr" {
  default = "192.168.2.0/24"
}

variable "external_gateway_ip" {
  default = "192.168.2.1"
}

variable "external_allocation_start" {
  default = "192.168.2.51"
}

variable "external_allocation_end" {
  default = "192.168.2.150"
}

variable "public_physical_network" {
  default = "physnet1"     # CHANGE THIS IF NEEDED
}

variable "private_subnet_cidr" {
  default = "10.0.1.0/24"
}

variable "private_gateway" {
  default = "10.0.1.1"
}

variable "dns_nameservers" {
  type    = list(string)
  default = ["8.8.8.8"]
}

