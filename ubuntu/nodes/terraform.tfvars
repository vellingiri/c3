vm_names = {
  controller = "c1"
  worker1    = "w1"
  worker2    = "w2"
  worker3    = "w3"
  #worker4    = "worker4"
  #worker5    = "worker5"
  runner     = "runner"
  #argocd     = "argocd"
}

vm_flavors = {
  controller = "m1.medium"
  worker1    = "m1.small"
  worker2    = "m1.small"
  worker3    = "m1.small"
  #worker4    = "m1.small"
  #worker5    = "m1.small"
  runner     = "m1.large"
  #argocd     = "m1.small"
}

image_name   = "ubuntu2404"
keypair_name = "default-key"
