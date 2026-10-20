variable "zone_name" {
  type = string
}

variable "extra_zones" {
  description = "Additional forward zones, e.g. one per environment (trailing dot)."
  type        = list(string)
  default     = []
}

variable "reverse_zone_name" {
  type = string
}

variable "email" {
  type = string
}

variable "records" {
  description = "key => {ip, ptr?, zone?, name?, ttl?}. zone defaults to zone_name, name to the key; name \"@\" is the zone apex. ptr=true also creates the PTR."
  type        = map(any)
}
