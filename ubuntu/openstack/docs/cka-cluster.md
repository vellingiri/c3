# CKA practice cluster (1 control plane + 3 workers)

A throw-away Kubernetes cluster for exam practice, separate from prod and qa. Same kubeadm cloud-init, so it comes up by itself in about 10 minutes.
Defined in `environments/cka/nodes.yaml`; DNS zone `cka.rdulinux.com.` (added in `infra/infra.yaml`); state `openstack/cka/nodes/...`.

## Names (2026-10-22): `<role><n>-<env>`
VMs are called `c1-cka`, `w1-cka` (prod too since the same day: `c1-prod` to `c3-prod`, `w1-prod` to `w3-prod`, `db1-prod`, `db2-prod`, `dbw1-prod`, and the GitHub runner is **`ci1-prod`**). Kubernetes node names follow the VM names in **prod** since 2026-10-22 (`kubectl get nodes` shows `c1-prod`..`w3-prod`; a node cannot be renamed, so each was re-joined with `scripts/k8s-rejoin-node.sh`). In **cka** they are still `c1`, `w1`.. (re-join them the same way when wanted; cka has one control plane, so `c1` cannot be re-joined). Names that systems use *internally* stay as they were: the etcd and Patroni member names `db1`, `db2`, `dbw1` (in `nodes.yaml` the field `member:`; a rebuilt database VM finds its member name by its address, not its hostname), the GitHub runner's registered name `finance-runner`. The ssh aliases `db1`, `db2`, `runner`/`ci1` are kept on the Mac, pinned to the floating IPs, so a name is unique across environments (before: `c1`, `w1` in every environment, told apart only by the DNS zone). DNS is `c1-cka.rdulinux.com`; ssh: `ssh c1-cka`. The cka VMs were **renamed in place** (no rebuild): OpenStack name, hostname, `/etc/hosts` by `scripts/k8s-rename-node-vm.sh`; Terraform follows with `environments/cka/moved.tf` (same VMs, only name attributes and DNS records change). The **Kubernetes node names stay `c1`, `w1`, `w2`, `w3`**: a node cannot be renamed in Kubernetes, so the kubelet is pinned to the old name (`--hostname-override` in `/etc/default/kubelet`); node names only have to be unique inside one cluster. A cka cluster built from scratch gets node names equal to the new hostnames (`c1-cka`).

## What it is
| VM | Flavor | Address | Role |
|---|---|---|---|
| `c1-cka` | m1.small (2 vCPU, 4 GB) | `c1-cka.rdulinux.com` | control plane (kubeadm, Calico, Kubernetes v1.30) |
| `w1-cka` `w2-cka` `w3-cka` | m1.small | `w1-cka.rdulinux.com` ... | workers; join by themselves when `c1` publishes `/nfsshare/join-cka.sh` |

**Built 2026-10-20** (c1 + w1 to w3, v1.30.14, all Ready about 9 minutes after the apply). Capacity (checked 2026-10-20 after `ram_allocation_ratio` 1.2): the four VMs need 16 GB RAM and 40 GB disk (Nova counts 10 GB per VM); `c3` had about 17 GB RAM and
44 GB disk headroom, about 21 GB and 54 GB after the spare `learn` VM is removed. Check before building: `ssh c3 'openstack resource provider usage show 51787b86-b99d-4cb3-b84d-ba4626ed34bd'`
(allowed: MEMORY_MB (80142-512) x 1.2, DISK_GB 136 x 1.5). Do not leave the cluster running when you are not practising: it takes a quarter of the free capacity,
and the finance-lb two-amphora rebuild needs about 4 GB.

## Build (about 10 minutes)
```bash
cd /opt/c3/ubuntu/openstack/infra && terraform apply            # once: adds the DNS zone cka.rdulinux.com.
cd ../environments/cka && terraform init && terraform apply
```
Then on your Mac (once): add `*.cka *-cka *-prod` next to `*.prod *.qa` in the two `Host` lines of `~/.ssh/config` (`Host *.prod *.qa *.cka`; done 2026-10-20), put `$HOME/.kube/cka` into `KUBECONFIG` in `~/.bash_profile` (`export KUBECONFIG=$HOME/.kube/prod:$HOME/.kube/qa:$HOME/.kube/cka`; done) and fetch the kubeconfig (quote the path, or your Mac expands `~` instead of the VM):
```bash
ssh c1-cka 'cat $HOME/.kube/config' | sed 's/kubernetes-admin@kubernetes/cka/; s/kubernetes-admin/cka-admin/' > ~/.kube/cka
kubectl --kubeconfig ~/.kube/cka get nodes        # c1 and w1..w3 Ready after the workers joined (about 5 more minutes)
```
If the workers do not join: `ssh w1-cka tail -20 /var/log/cloud-init-output.log`; the join command file is `/nfsshare/join-cka.sh` on the NFS share (it is per cluster, so it cannot collide with prod or qa).

## Rebuild from scratch (what was done 2026-10-21)
1. `ssh repo 'rm -f /nfsshare/join-cka.sh /nfsshare/join-cp-cka.sh'`: **stale join files on the NFS share** are picked up by new workers (they wait for the file and use whatever is there), so they would try the OLD cluster's token.
2. `cd environments/cka && terraform destroy && terraform apply`. The load balancer `cka-api` and the DNS name stay; the reconciler on `c3` swaps its member to the new `c1`.
3. Refetch the kubeconfig (the CA is new): `ssh c1-cka 'cat $HOME/.kube/config' | sed 's/kubernetes-admin@kubernetes/cka/g; s/kubernetes-admin/cka-admin/g; s/name: kubernetes$/name: cka/; s/cluster: kubernetes$/cluster: cka/' > ~/.kube/cka` (quote the path so your Mac does not expand `~`).

## Tear down (frees all the memory and disk)
```bash
cd /opt/c3/ubuntu/openstack/environments/cka && terraform destroy
```
Rebuilding from nothing later gives a fresh cluster with a new CA: fetch the kubeconfig again.

## Practising the exam topics on it
- **etcd backup and restore:** the controller already takes etcd snapshots (`/var/backups/etcd`, copied to the NFS share under `etcd-backups/cka`); the restore procedure is rehearsed in `etcd-restore-rehearsal.md` (`etcdctl snapshot save/restore`, certificates under `/etc/kubernetes/pki/etcd`).
- **Cluster upgrade with kubeadm:** the nodes install `kubeadm`/`kubelet`/`kubectl` from the v1.30 repo and hold them; to practise an upgrade point apt at the next minor repo, `kubeadm upgrade plan/apply`, drain, upgrade kubelet, uncordon.
- **Add / remove a node:** change `nodes.yaml` and apply (`k8s-operations.md` has the drain and delete steps; same procedure).
- **Troubleshooting drills:** `systemctl stop kubelet` on a worker, break a static pod manifest in `/etc/kubernetes/manifests`, change a certificate path, then repair.
- **One control plane (`c1`) and three workers, recreated on 2026-10-21.** It was briefly an HA cluster (`c2`, `c3`, the rehearsal for prod, `k8s-ha-control-plane.md`); they were destroyed without leaving the cluster, etcd lost its majority and the API hung, so the whole cluster was destroyed and applied again. The cluster is still built through the API name `api.cka.rdulinux.com` (Octavia load balancer `cka-api`, not Terraform-managed, kept across rebuilds; the reconciler on `c3` points it at the new `c1` within a minute), so `~/.kube/cka` has `server: https://api.cka.rdulinux.com:6443`. **After every rebuild the CA is new: refetch the kubeconfig** (below). To add control planes again, put `c2`/`c3` (`role: controller_join`) back in `environments/cka/nodes.yaml`; to remove nodes later use `scripts/k8s-retire-node.sh cka <node>` first.
