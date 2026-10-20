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
