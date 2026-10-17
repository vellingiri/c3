# Renamed during the move to <env>-<role><n> naming. Keeps the existing VMs
# (no recreation); safe to delete once applied everywhere.
moved {
  from = module.node["c1"]
  to   = module.node["prod-c1"]
}

moved {
  from = module.node["w1"]
  to   = module.node["prod-w1"]
}

moved {
  from = module.node["w2"]
  to   = module.node["prod-w2"]
}

moved {
  from = module.node["w3"]
  to   = module.node["prod-w3"]
}
