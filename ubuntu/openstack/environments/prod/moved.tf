# Names go back to plain (no environment prefix). Keeps the existing VMs.
# Safe to delete once applied everywhere.
moved {
  from = module.node["prod-c1"]
  to   = module.node["c1"]
}

moved {
  from = module.node["prod-w1"]
  to   = module.node["w1"]
}

moved {
  from = module.node["prod-w2"]
  to   = module.node["w2"]
}

moved {
  from = module.node["prod-w3"]
  to   = module.node["w3"]
}

# db is renamed db1 (same VM, port and floating IP; the Nova name changes in place).
moved {
  from = module.node["db"]
  to   = module.node["db1"]
}

# 2026-10-22: the Kubernetes node VMs were renamed IN PLACE to <role><n>-prod (scripts/k8s-rename-node-vm.sh), no rebuild; Terraform follows.
# Same VMs, ports and floating IPs under the new keys; only the name attributes change and the DNS records are re-created in the main zone.


moved {
  from = module.node["c1"]
  to   = module.node["c1-prod"]
}

moved {
  from = module.node["c2"]
  to   = module.node["c2-prod"]
}

moved {
  from = module.node["c3"]
  to   = module.node["c3-prod"]
}

moved {
  from = module.node["w1"]
  to   = module.node["w1-prod"]
}

moved {
  from = module.node["w2"]
  to   = module.node["w2-prod"]
}

moved {
  from = module.node["w3"]
  to   = module.node["w3-prod"]
}

moved {
  from = module.node["db1"]
  to   = module.node["db1-prod"]
}

moved {
  from = module.node["db2"]
  to   = module.node["db2-prod"]
}

moved {
  from = module.node["dbw1"]
  to   = module.node["dbw1-prod"]
}

moved {
  from = module.node["runner"]
  to   = module.node["ci1-prod"]
}

# Names of the non-Kubernetes VMs (same day): db1-prod, db2-prod, dbw1-prod (their etcd/Patroni member names stay db1, db2, dbw1: `member:` in nodes.yaml)
# and ci1-prod, the GitHub Actions runner (role `runner`, formerly `runner`).
