# Highly available Kubernetes control plane (prod and cka: three control-plane nodes behind a load balancer)

Built and drilled 2026-10-20. Before this, every cluster had **one** control-plane node (`c1`): if it died, the API (kubectl, deploys, scheduling, Argo CD) was gone until it was rebuilt
(running pods kept serving). Now `prod` and `cka` have three control-plane nodes and one stable API address in front of them. `qa` still has one (spare cluster; the same steps apply).

## The pieces
| Piece | What / where |
|---|---|
| API address | `https://api.<env>.rdulinux.com:6443` (DNS in `infra/infra.yaml`, keys `api-prod`, `api-cka`) = floating IP of an Octavia **TCP** load balancer `<env>-api` (listener `<env>-api-6443`, pool `<env>-api-pool`, TCP health monitor 3 s / 2 retries). `prod-api` is ACTIVE_STANDBY (two amphorae), `cka-api` SINGLE. TCP passthrough: clients see the API server's own certificate |
| Certificates | the API server certificate lists the API name, its floating IP, the old first-controller floating IP and the node IP, so old kubeconfigs keep working |
| Control-plane nodes | `c1` (kubeadm init), `c2`, `c3` (role `controller_join` in `nodes.yaml`, m1.small): stacked etcd on each (3 members, one failure tolerated), API server, controller-manager and scheduler (leader election) on each |
| Join commands | every control-plane node runs `k8s-publish-join.timer` (hourly): it writes `/nfsshare/join-<env>.sh` (workers) and `/nfsshare/join-cp-<env>.sh` (control plane, with a fresh certificate key) so **a node created later joins by itself**. `cloud-init/files/k8s-publish-join.sh` (serialised with a lock) |
| Load balancer members | `c3` runs `k8s-api-lb.timer` (every 30 s, `scripts/k8s-api-lb-reconciler.py`, installed by `scripts/install-k8s-api-lb-reconciler.sh`): members of `<env>-api-pool` = the ACTIVE servers tagged env=<env>, role=controller/controller_join. A new control-plane VM is added by itself, a deleted one removed (never the last member) |
| OVN VIP fix | the OVN VIP reconciler (`scripts/ovn-vip-binding-reconciler.py`) probes port 80 **and 6443**, so the API load balancers get the same stale-MAC protection as the app ones |

## Look at it
```bash
ssh c3 'openstack loadbalancer member list prod-api-pool -c name -c address -c operating_status'   # who is behind the VIP (ONLINE = gets traffic)
kubectl --kubeconfig ~/.kube/prod get endpoints kubernetes                                         # the real API servers inside the cluster
kubectl --kubeconfig ~/.kube/prod get nodes                                                        # c1 c2 c3 control-plane, w1..w3
```
etcd members of a cluster (from a control-plane node): `crictl exec $(crictl ps --name '^etcd$' -q) etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list -w table`.
Your kubeconfigs point at the API name (`~/.kube/prod`, `~/.kube/cka`, and the CI runner's `/home/runner/.kube/config`; backup `config.bak-20261020-ha`).

## Convert a running single-controller cluster (what was done)
1. `ssh c3 'bash /root/octavia-k8s-api-lb.sh <env> <single|ha> <c1 private ip>'` (`scripts/octavia-k8s-api-lb.sh`): creates the load balancer and prints its floating IP.
2. Put the floating IP in `infra/infra.yaml` (`api-<env>`), `terraform apply` in `infra`.
3. `scripts/k8s-ha-convert.sh <env>` from your Mac: backups (tarball of `/etc/kubernetes`, an etcd snapshot), `kubeadm-config` controlPlaneEndpoint and certSANs, **new API server certificate** and a restart of the API server (about 30 to 60 s without the API, running pods keep running), every node's `kubelet.conf`, `kube-proxy` and `cluster-info` point at the API name, the join publisher installed on `c1`. Re-runnable.
4. Point your kubeconfig (`server:`) and the runner's at `https://api.<env>.rdulinux.com:6443`.
5. In `environments/<env>/nodes.yaml` set `api_endpoint` and add `c2`/`c3` (`role: controller_join`, `vars: { join_delay: "300" }` on the last so etcd takes one member at a time); `terraform apply`. They join, `c3` adds itself to the load balancer by the reconciler.
A **new** cluster built from nothing: create the load balancer first (step 1, with the floating IP of the first controller as the only member, or none), set `api_endpoint` in `nodes.yaml`; `kubeadm init` then uses the API name as its endpoint from the start.

## Drill results (cka, 2026-10-20)
| Test | Result |
|---|---|
| Conversion of the running cluster | API restart once, all nodes Ready afterwards, certificate with the new SANs, `kubectl` through the load balancer works |
| `c2`, `c3` joined | etcd 3 of 3 members, three apiservers listed by `kubectl get endpoints kubernetes`, load balancer members ONLINE |
| **First control plane `c1` powered off** (power cut) | the API stayed available through the load balancer: 5 failed requests out of 51 (one probe per second) during the 25 s until the load balancer marked the dead member (health monitor then 5 s x 3; tightened to 3 s x 2 afterwards), writes (a ConfigMap create) worked at once, controller-manager and scheduler leadership moved to `c2`; `c1` started again and rejoined etcd by itself (3 of 3 healthy), member back ONLINE |
| Prod conversion | front door 200, Argo 200, 12 of 12 pods, Argo `Synced Healthy` before and after |

## Things found while building it (all fixed)
- **Two overlapping runs of the join publisher** (the timer firing while an explicit run was going) wrote a key file that did not match the secret: `error decoding secret data with provided key: cipher: message authentication failed` and both new controllers failed to join in cloud-init. Fix: the publisher takes a lock (`flock`); the join in cloud-init retries and re-reads the file each time.
- **New nodes never became Ready: kubelet used systemd-resolved's resolver file, which on a fresh VM lists only the subnet's `8.8.8.8`**, so host-network pods (kube-proxy, calico) could not resolve `api.<env>.rdulinux.com` ("lookup ... on 8.8.8.8:53: no such host"). Fix: `resolvConf: /etc/resolv.conf` (the static file with our DNS server) in the kubelet config, in all node cloud-init templates and by hand on `c2`/`c3`.
- The OVN VIP reconciler assumed port 80; for the API load balancers it would have "repaired" VIPs that were fine. It now probes 80 and 6443.
- `kubeadm join` of two control planes at the same moment is fragile (etcd adds one member at a time): `join_delay` staggers them.

## Limits and care
- Three control-plane nodes tolerate **one** failure (etcd majority). Two at once, and the API is read-only/unavailable until one is back (workloads keep running).
- Everything still runs on one host (`c3`). The load balancer, the control planes and the workers go down together with it.
- The certificate key published for control-plane joins is valid 2 hours and refreshed hourly; the files are on the NFS share (the control-plane one is mode 0700, root).
- Capacity: each control-plane VM is 4 GB (m1.small); `prod-api` costs two amphorae (4 GB), `cka-api` one. RAM allocation limit on `c3`: `ram_allocation_ratio` 1.5, `disk_allocation_ratio` 2.5 (`CHANGELOG.md`).
- etcd backups: every control-plane node snapshots its own etcd every 6 hours (`/var/backups/etcd`, copied to `/nfsshare/etcd-backups/<env>`). Restore: `etcd-restore-rehearsal.md`.
