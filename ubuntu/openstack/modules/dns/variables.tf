variable "zone_name" {
  type = string
}

variable "reverse_zone_name" {
  type = string
}

variable "email" {
  type = string
}

variable "records" {
  description = "name => {ip, ptr?}. Name \"@\" is the apex. ptr=true also creates the PTR."
  type        = map(any)
}
