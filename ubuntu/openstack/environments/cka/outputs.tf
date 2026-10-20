output "nodes" {
  description = "Per-node name, role, IPs and FQDN, keyed by node name."
  value       = { for name, m in module.node : name => m.info }
}
