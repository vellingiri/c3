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


# Names of the non-Kubernetes VMs (same day): db1-prod, db2-prod, dbw1-prod (their etcd/Patroni member names stay db1, db2, dbw1: `member:` in nodes.yaml)
# and ci1-prod, the GitHub Actions runner (role `runner`, formerly `runner`).

# 2026-11-19: the Rancher management VM drops the -prod suffix (prod keeps plain role names for its shared services); renamed in place.
moved {
  from = module.node["rancher-prod"]
  to   = module.node["rancher"]
}

# 2026-11-19: db1, db2 and dbw1 lose the -prod suffix (plain names for prod); their old moved blocks were removed so the keys can be reused; the VMs are replaced one by one (db-ha-patroni.md).

# 2026-11-20: the DR replica VM `finance` moves here from the former environments/dr stack (that environment no longer exists). Nothing is recreated: the
# existing objects are imported into this state. Afterwards remove them from the old state WITHOUT destroying them:
#   (cd environments/dr && terraform state rm 'module.node["finance"]')   (see CHANGELOG 2026-11-20). Safe to delete these blocks once applied.
import {
  to = module.node["finance"].openstack_compute_instance_v2.this
  id = "36c9ddac-0b34-40ec-a2be-df7152c272f9"
}

import {
  to = module.node["finance"].openstack_networking_port_v2.this
  id = "3493cf0a-0b81-4c9d-9a50-b7e5eb471f24"
}

import {
  to = module.node["finance"].openstack_networking_floatingip_v2.this
  id = "54d414dc-9a0a-4ec7-a475-9756bd6d483d"
}

import {
  to = module.node["finance"].openstack_networking_floatingip_associate_v2.this
  id = "54d414dc-9a0a-4ec7-a475-9756bd6d483d"
}

import {
  to = module.node["finance"].openstack_dns_recordset_v2.a[0]
  id = "16d50132-7dda-40c7-9012-6b0c12076523/840ec6ea-49bd-49b8-a6bd-271469e64d58"
}

import {
  to = module.node["finance"].openstack_dns_recordset_v2.ptr[0]
  id = "4c58314c-3cfe-4859-95ba-2b6ff57509f6/8fd1c13c-0454-41b1-8bea-ff6776969b0b"
}
