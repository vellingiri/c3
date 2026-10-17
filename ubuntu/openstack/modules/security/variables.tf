variable "name" {
  type = string
}

variable "description" {
  type    = string
  default = ""
}

variable "ingress_rules" {
  description = "rule key => {protocol, port_min?, port_max?, cidr?}"
  type        = map(any)
}
