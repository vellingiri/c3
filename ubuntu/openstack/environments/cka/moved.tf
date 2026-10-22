# 2026-10-22: the VMs were renamed IN PLACE to <role><n>-cka (scripts/k8s-rename-node-vm.sh), no rebuild. These blocks make Terraform follow:
# same VM, port and floating IP under the new key; only the name attributes change and the DNS records are re-created under the new names.
moved {
  from = module.node["c1"]
  to   = module.node["c1-cka"]
}

moved {
  from = module.node["w1"]
  to   = module.node["w1-cka"]
}

moved {
  from = module.node["w2"]
  to   = module.node["w2-cka"]
}

moved {
  from = module.node["w3"]
  to   = module.node["w3-cka"]
}
