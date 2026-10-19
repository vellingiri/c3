# Names go from qa-<x> to plain <x>. Keeps ports and floating IPs (so IPs and the
# haproxy qa_nodes backend stay valid). Safe to delete once applied.
moved {
  from = module.node["qa-c1"]
  to   = module.node["c1"]
}

moved {
  from = module.node["qa-w1"]
  to   = module.node["w1"]
}

moved {
  from = module.node["qa-w2"]
  to   = module.node["w2"]
}

moved {
  from = module.node["qa-w3"]
  to   = module.node["w3"]
}

moved {
  from = module.node["qa-learn"]
  to   = module.node["learn"]
}
