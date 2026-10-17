variable "name" {
  description = "Stable VM name (also DNS hostname)."
  type        = string
}

variable "role" {
  description = "Role selects which cloud-init parts are applied."
  type        = string
  validation {
    condition     = contains(["controller", "worker", "gitlab", "runner", "database", "loadbalancer"], var.role)
    error_message = "role must be one of: controller, worker, gitlab, runner, database, loadbalancer."
  }
}

variable "flavor" {
  type = string
}

variable "image" {
  type = string
}

variable "keypair" {
  type = string
}

variable "network_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_ids" {
  description = "Security group IDs (copied from v1: default + k8s)."
  type        = list(string)
}

variable "floating_ip_pool" {
  type = string
}

variable "domain" {
  description = "DNS domain without trailing dot, e.g. rdulinux.com"
  type        = string
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

variable "cloud_init_vars" {
  description = "Values rendered into the cloud-init templates (global defaults merged with per-node overrides)."
  type        = map(string)
  default     = {}
}

variable "cloud_init_dir" {
  description = "Directory holding the *.yaml.tftpl cloud-init parts."
  type        = string
}

variable "manage_dns" {
  description = "Create the A/PTR records. Set false when another stack (e.g. infra) already owns them."
  type        = bool
  default     = true
}
