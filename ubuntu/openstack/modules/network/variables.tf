variable "external" {
  type = object({
    name             = string
    physical_network = string
    cidr             = string
    gateway_ip       = string
    pool_start       = string
    pool_end         = string
  })
}

variable "private" {
  type = object({
    cidr            = string
    gateway_ip      = string
    dns_nameservers = list(string)
  })
}
