variable "nodes_file" {
  description = "YAML file describing every node. This is the only file you edit day to day."
  type        = string
  default     = "nodes.yaml"
}

# Database HA group secrets. Not in git: scripts/db-ha-secrets.sh writes them to secrets.auto.tfvars (git-ignored), taking the values the running
# cluster already uses, or new random ones when there is no cluster yet. No defaults on purpose: a rebuilt node must never get an invented password.
variable "db_ha_postgres_password" {
  description = "Password of the postgres superuser (Patroni logs in with it)."
  type        = string
  sensitive   = true
}

variable "db_ha_replication_password" {
  description = "Password of the replicator role."
  type        = string
  sensitive   = true
}

variable "db_ha_rest_password" {
  description = "Password for writes to Patroni's REST API (user patroni)."
  type        = string
  sensitive   = true
}

variable "db_ha_ntfy_url" {
  description = "ntfy topic URL for role-change messages; empty = no messages."
  type        = string
  sensitive   = true
  default     = ""
}
