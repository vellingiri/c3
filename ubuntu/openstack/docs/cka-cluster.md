# CKA practice cluster (1 control plane + 3 workers)

A throw-away Kubernetes cluster for exam practice, separate from prod and qa. Same kubeadm cloud-init, so it comes up by itself in about 10 minutes.
Defined in `environments/cka/nodes.yaml`; DNS zone `cka.rdulinux.com.` (added in `infra/infra.yaml`); state `openstack/cka/nodes/...`.

## What it is
| VM | Flavor | Address | Role |
|---|---|---|---|
| `c1` | m1.small (2 vCPU, 4 GB) | `c1.cka.rdulinux.com` | control plane (kubeadm, Calico, Kubernetes v1.30) |
| `w1` `w2` `w3` | m1.small | `w1.cka.rdulinux.com` ... | workers; join by themselves when `c1` publishes `/nfsshare/join-cka.sh` |

**Built 2026-10-20** (c1 + w1 to w3, v1.30.14, all Ready about 9 minutes after the apply). Capacity (checked 2026-10-20 after `ram_allocation_ratio` 1.2): the four VMs need 16 GB RAM and 40 GB disk (Nova counts 10 GB per VM); `c3` had about 17 GB RAM and
44 GB disk headroom, about 21 GB and 54 GB after the spare `learn` VM is removed. Check before building: `ssh c3 'openstack resource provider usage show 51787b86-b99d-4cb3-b84d-ba4626ed34bd'`
(allowed: MEMORY_MB (80142-512) x 1.2, DISK_GB 136 x 1.5). Do not leave the cluster running when you are not practising: it takes a quarter of the free capacity,
and the finance-lb two-amphora rebuild needs about 4 GB.

## Build (about 10 minutes)
```bash
cd /opt/c3/ubuntu/openstack/infra && terraform apply            # once: adds the DNS zone cka.rdulinux.com.
cd ../environments/cka && terraform init && terraform apply
```
Then on your Mac (once): add `*.cka` next to `*.prod *.qa` in the two `Host` lines of `~/.ssh/config` (`Host *.prod *.qa *.cka`; done 2026-10-20), put `$HOME/.kube/cka` into `KUBECONFIG` in `~/.bash_profile` (`export KUBECONFIG=$HOME/.kube/prod:$HOME/.kube/qa:$HOME/.kube/cka`; done) and fetch the kubeconfig (quote the path, or your Mac expands `~` instead of the VM):
```bash
ssh c1.cka 'cat $HOME/.kube/config' | sed 's/kubernetes-admin@kubernetes/cka/; s/kubernetes-admin/cka-admin/' > ~/.kube/cka
kubectl --kubeconfig ~/.kube/cka get nodes        # c1 and w1..w3 Ready after the workers joined (about 5 more minutes)
```
If the workers do not join: `ssh w1.cka tail -20 /var/log/cloud-init-output.log`; the join command file is `/nfsshare/join-cka.sh` on the NFS share (it is per cluster, so it cannot collide with prod or qa).

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
- **This cluster has three control-plane nodes** (`c1`, `c2`, `c3`) behind the API name `api.cka.rdulinux.com` (Octavia load balancer `cka-api`), built as the rehearsal for prod and drilled by powering `c1` off (`k8s-ha-control-plane.md`). Your kubeconfig `server:` is `https://api.cka.rdulinux.com:6443`. Practise etcd backup/restore and `kubeadm upgrade` on it as a real HA cluster.
