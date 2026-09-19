vm_names = {
  controller = "c1"
  worker1    = "w1"
  worker2    = "w2"
  worker3    = "w3"
  controller2 = "c2"
  worker4    = "w4"
  worker5    = "w5"
  worker6    = "w6"
  runner     = "runner"
  #argocd     = "argocd"
}

vm_flavors = {
  controller  = "m1.medium"
  worker1     = "m1.small"
  worker2     = "m1.small"
  worker3     = "m1.small"
  controller2 = "m1.medium"
  worker4     = "m1.small"
  worker5     = "m1.small"
  worker6     = "m1.small"
  runner      = "m1.large"
  #argocd     = "m1.small"
}

image_name   = "ubuntu2404"
keypair_name = "default-key"
