# The cka cluster runs on Docker (cri-dockerd)

**Since 2026-10-24 all four cka nodes (`c1`, `w1-cka`, `w2-cka`, `w3-cka`) use Docker Engine as their container runtime**, not containerd. Prod and qa are unchanged (containerd).

## How it works
Kubernetes 1.24 and later have no Docker support built in, so the kubelet cannot talk to Docker directly. It talks to **`cri-dockerd`** (Mirantis, a CRI shim, socket `/run/cri-dockerd.sock`), which hands the work to Docker Engine (`docker.io` 29.1.3 from Ubuntu 24.04). Docker itself runs on the containerd that was already installed (its own `moby` namespace), so containerd is still on every node.
- kubelet flag: `--container-runtime-endpoint=unix:///run/cri-dockerd.sock` in `/var/lib/kubelet/kubeadm-flags.env` (the cgroup driver stays systemd, set in `/etc/docker/daemon.json`).
- node annotation `kubeadm.alpha.kubernetes.io/cri-socket` = the same socket.
- `/etc/crictl.yaml` points at cri-dockerd, so `crictl ps` shows what `docker ps` shows (the containers are named `k8s_<container>_<pod>_...`).
- Check: `kubectl get nodes -o wide` shows `docker://29.1.3` in the runtime column.
- The cri-dockerd package is `cri-dockerd_0.4.9.3-0.ubuntu-noble_amd64.deb`, checked against the SHA-256 GitHub publishes for the release before it is installed.

## What was done (2026-10-24)
`scripts/k8s-runtime-docker.sh <env> <node>`, one node at a time: workers `w3-cka`, `w2-cka`, `w1-cka` (cordon, drain, switch, uncordon), then the control plane `c1` (etcd snapshot first, `/var/backups/etcd/etcd-20261024T074524.db`; the API was away for about a minute). The old containerd copy of the images and the old pod sandboxes were removed (they were a second copy of the same images; node disks are 10 GB, 4.6 to 6 GB free afterwards). A throwaway pod pulled an image, ran on a Docker node and resolved cluster DNS; 0 non-running pods afterwards.
**Found on the way:** the kubelet package was half-configured on all four cka nodes (`dpkg -l` state `hU`): the nightly automatic security updates had stopped on a conffile prompt about `/etc/default/kubelet` (written by cloud-init, also shipped by the package), which made every `apt install` fail. Fixed with `dpkg --configure --force-confold` (the file is kept as it is) on each node; the script now does that first. Prod nodes do not have the problem.
**Found earlier the same day:** the cka kubelets had been `disabled` (no start at boot); they are `enabled` now.

## Things to know
- **The exam environment for the CKA uses containerd and `crictl`.** Docker commands (`docker ps`, `docker images`) work on these nodes now; for exam practice use `crictl`, which also works here.
- **Images are stored by Docker now** (`/var/lib/docker`), pulled again on first use; `docker image prune -a` cleans them (`crictl rmi` also works through cri-dockerd).
- **Terraform and cloud-init were not changed**: a cka node that is rebuilt (`terraform apply -replace`) comes back on containerd, like every other cluster. To make Docker the default for cka, add a runtime switch to the cka templates (not done); until then run the script on a rebuilt node.
- The control plane's static pods (etcd, apiserver, controller-manager, scheduler) run as Docker containers now; `etcd` data is on the host (`/var/lib/etcd`) and was not touched.

## Go back to containerd (one node at a time, same order)
On the node: `systemctl stop kubelet`; remove its containers (`docker ps -aq | xargs -r docker rm -f`); in `/var/lib/kubelet/kubeadm-flags.env` set `--container-runtime-endpoint=unix:///run/containerd/containerd.sock`; put the same endpoint in `/etc/crictl.yaml`; `systemctl start kubelet`; from the Mac `kubectl annotate node <node> --overwrite kubeadm.alpha.kubernetes.io/cri-socket=unix:///run/containerd/containerd.sock`. Docker can stay installed or be removed (`apt remove docker.io cri-dockerd`). Drain a worker first and uncordon it after, as the script does.

## Rename of the single control plane (2026-10-24): c1 -> c1-cka, without leaving the cluster
`scripts/k8s-rename-single-cp.sh cka c1 c1-cka`. Re-joining (`k8s-rejoin-node.sh`) needs three control planes, so it cannot be used on a one-control-plane cluster. The script relies on the control-plane containers (etcd, API server, controller manager, scheduler) belonging to the container runtime, not to the kubelet: it takes an etcd snapshot and a tarball of `/etc/kubernetes` (`/root/cka-c1-rename-backup.tgz` on the node), issues a new kubelet client certificate for `system:node:c1-cka` signed by the cluster CA (`kubeadm kubeconfig user`), stops the kubelet (the API kept answering 200), installs the new `kubelet.conf`, removes `--hostname-override=c1` from `/etc/default/kubelet`, deletes the old Node object, starts the kubelet (it registers `c1-cka`), and puts back the control-plane label, the load-balancer exclusion label, the `NoSchedule` taint and the cri-socket annotation. Afterwards: `calico-node` and `kube-proxy` on all four nodes, CoreDNS 3 of 3, etcd healthy, 0 non-running pods, a pod resolving the service and an outside name. The etcd **member** name stays `c1` (a label inside etcd; changing it would restart etcd for nothing). The new kubelet certificate is valid one year (`kubeadm certs renew` covers the kubeconfigs).
**Rollback:** `systemctl stop kubelet`; `cp /etc/kubernetes/kubelet.conf.before-rename /etc/kubernetes/kubelet.conf`; put `--hostname-override=c1` back in `/etc/default/kubelet`; `kubectl delete node c1-cka`; `systemctl start kubelet`; re-add the control-plane label and taint.
