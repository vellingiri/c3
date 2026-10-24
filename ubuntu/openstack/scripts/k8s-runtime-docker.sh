#!/usr/bin/env bash
# Switch ONE node of a kubeadm cluster from containerd to Docker Engine, one node at a time, from your Mac:
#   scripts/k8s-runtime-docker.sh <env> <node>         e.g.  scripts/k8s-runtime-docker.sh cka w3-cka
#
# Kubernetes 1.24 and later have no Docker support built in, so the kubelet talks to Docker through `cri-dockerd`
# (Mirantis, CRI shim, socket /run/cri-dockerd.sock). Docker Engine is Ubuntu's `docker.io`, which runs on the containerd that is already
# installed (its own "moby" namespace), so going back is only a kubelet flag (see "Go back" in docs/k8s-docker-runtime.md).
# What it does, per node:
#   workers:        cordon, drain (pods move to the other nodes, so run it on one worker at a time, never in parallel)
#   control plane:  etcd snapshot first (/usr/local/sbin/etcd-snapshot), no drain (static pods are not evicted); the API is down for a minute or two
#   on the node:    install docker.io + cri-dockerd (checksum-verified), docker cgroup driver systemd (same as the kubelet), stop the kubelet,
#                   remove every container and pod sandbox that still runs under containerd (they would hold the same ports), point the kubelet and
#                   crictl at cri-dockerd, start the kubelet
#   afterwards:     node annotation cri-socket updated, wait Ready, uncordon, old containerd images removed (they are a second copy of the same images)
# Stops at the first problem and leaves the node cordoned. Nothing is retried blindly.
set -euo pipefail

ENV_NAME=${1:?env (cka|prod|qa)}; NODE=${2:?node name}
KCFG=${KCFG:-$HOME/.kube/$ENV_NAME}
CRI_DOCKERD_VERSION=0.4.9
CRI_DOCKERD_DEB="cri-dockerd_${CRI_DOCKERD_VERSION}.3-0.ubuntu-noble_amd64.deb"
CRI_DOCKERD_URL="https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/${CRI_DOCKERD_DEB}"
CRI_DOCKERD_SHA256=${CRI_DOCKERD_SHA256:-b7c012772042992ee09fa8a3e22ca18dafd04fbef6c8b50a7d8ab8709f869825}   # published with the release (gh api repos/Mirantis/cri-dockerd/releases/tags/v0.4.9)
NEW_SOCK=unix:///run/cri-dockerd.sock
OLD_SOCK=unix:///run/containerd/containerd.sock

K() { kubectl --kubeconfig "$KCFG" --context "$ENV_NAME" "$@"; }
say() { printf '\n== %s\n' "$*"; }
die() { echo "STOP: $*" >&2; exit 1; }
# the node's ssh name: names that already carry -<env> (w3-cka) are used as they are
host_of() { case "$1" in *-$ENV_NAME) echo "$1" ;; *) echo "$1.$ENV_NAME" ;; esac; }
# a single-control-plane cluster keeps its first node as plain "c1" (cka), whose VM is c1-<env>
if [ "$NODE" = c1 ]; then SSH="c1-$ENV_NAME"; else SSH=$(host_of "$NODE"); fi

say "checks"
K get node "$NODE" >/dev/null || die "no node $NODE in $ENV_NAME"
TOTAL=$(K get nodes --no-headers | wc -l | tr -d ' ')
READY=$(K get nodes --no-headers | grep -c ' Ready' || true)
[ "$READY" = "$TOTAL" ] || die "not all $TOTAL nodes are Ready ($READY)"
CUR=$(K get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
echo "$NODE: now $CUR"; case "$CUR" in docker://*) echo "already on Docker; nothing to do"; exit 0 ;; esac
ssh -o ConnectTimeout=8 "$SSH" 'test "$(. /etc/os-release; echo $VERSION_CODENAME)" = noble' || die "$SSH is not Ubuntu 24.04 (the cri-dockerd package here is for noble)"
IS_CP=0; K get node "$NODE" -o jsonpath='{.metadata.labels}' | grep -q 'node-role.kubernetes.io/control-plane' && IS_CP=1
echo "$([ $IS_CP = 1 ] && echo control-plane || echo worker), ssh as $SSH, pods: $(K get pods -A --field-selector spec.nodeName="$NODE" --no-headers | wc -l | tr -d ' ')"

if [ "$IS_CP" = 1 ]; then
  say "1. etcd snapshot before touching the control plane"
  ssh "$SSH" '/usr/local/sbin/etcd-snapshot 2>&1 | tail -2'
else
  say "1. cordon and drain $NODE"
  K cordon "$NODE" >/dev/null
  K drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s 2>&1 | tail -2 || die "drain did not finish; node stays cordoned (kubectl uncordon $NODE)"
fi

say "2. install Docker Engine and cri-dockerd on $SSH"
ssh "$SSH" bash -s <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# A half-configured kubelet package (the automatic security updates stop on a prompt about /etc/default/kubelet, which cloud-init wrote and the
# package also ships) makes every apt install fail. Finish it and keep the file the cluster already uses.
dpkg --configure --force-confold -a >/dev/null 2>&1 || true
apt-get update -qq
apt-get install -y -qq docker.io >/dev/null
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'J'
{"exec-opts": ["native.cgroupdriver=systemd"], "log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}, "storage-driver": "overlay2"}
J
systemctl enable --now docker >/dev/null 2>&1
systemctl restart docker
curl -fsSL -o /tmp/$CRI_DOCKERD_DEB "$CRI_DOCKERD_URL"
echo "$CRI_DOCKERD_SHA256  /tmp/$CRI_DOCKERD_DEB" | sha256sum -c - >/dev/null || { echo "checksum of $CRI_DOCKERD_DEB does not match"; exit 1; }
dpkg -i /tmp/$CRI_DOCKERD_DEB >/dev/null
rm -f /tmp/$CRI_DOCKERD_DEB
systemctl enable --now cri-docker.socket cri-docker.service >/dev/null 2>&1
test -S /run/cri-dockerd.sock && echo "docker \$(docker version -f '{{.Server.Version}}'), cgroup driver \$(docker info -f '{{.CgroupDriver}}'), cri-dockerd socket present"
REMOTE

say "3. stop the kubelet, clear what still runs under containerd, switch"
ssh "$SSH" bash -s <<REMOTE
set -euo pipefail
systemctl stop kubelet
OLD="crictl --runtime-endpoint $OLD_SOCK"
\$OLD ps -aq | xargs -r \$OLD rm -f >/dev/null 2>&1 || true
\$OLD pods -q | xargs -r \$OLD rmp -f >/dev/null 2>&1 || true
echo "left under containerd: \$(\$OLD ps -aq | wc -l) containers, \$(\$OLD pods -q | wc -l) sandboxes"
sed -i 's#--container-runtime-endpoint=[^ "]*#--container-runtime-endpoint=$NEW_SOCK#' /var/lib/kubelet/kubeadm-flags.env
grep -o -- '--container-runtime-endpoint=[^ "]*' /var/lib/kubelet/kubeadm-flags.env
cat > /etc/crictl.yaml <<C
runtime-endpoint: $NEW_SOCK
image-endpoint: $NEW_SOCK
timeout: 10
C
systemctl start kubelet
REMOTE
# On a single control plane the API restarts with the kubelet (a minute or two): wait for it instead of failing on the first EOF.
for i in $(seq 1 60); do [ "$(K get --raw /livez 2>/dev/null)" = ok ] && break; sleep 5; done
for i in 1 2 3 4 5; do K annotate node "$NODE" --overwrite kubeadm.alpha.kubernetes.io/cri-socket="$NEW_SOCK" >/dev/null 2>&1 && break; sleep 5; done

say "4. wait for $NODE to be Ready on Docker"
for i in $(seq 1 60); do
  K get node "$NODE" --no-headers 2>/dev/null | grep -q ' Ready' && K get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' | grep -q '^docker://' && break
  sleep 5
done
K get node "$NODE" -o jsonpath='{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.nodeInfo.containerRuntimeVersion}{"\n"}'
K get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' | grep -q '^docker://' || die "$NODE is not on Docker; look at: ssh $SSH journalctl -u kubelet -n 50 (revert: docs/k8s-docker-runtime.md)"
K get node "$NODE" --no-headers | grep -q ' Ready' || die "$NODE is not Ready; look at: ssh $SSH journalctl -u kubelet -n 50"

if [ "$IS_CP" = 1 ]; then
  say "5. control plane checks"
  for i in $(seq 1 40); do [ "$(K get --raw /livez 2>/dev/null)" = ok ] && break; sleep 5; done
  echo "API /livez: $(K get --raw /livez 2>&1 | head -1)"
else
  say "5. uncordon"
  K uncordon "$NODE" >/dev/null
fi
for i in $(seq 1 60); do [ "$(K get pods -A --no-headers 2>/dev/null | grep -c -v -E 'Running|Completed')" = 0 ] && break; sleep 5; done
echo "non-running pods in the cluster: $(K get pods -A --no-headers | grep -c -v -E 'Running|Completed')"

say "6. remove the old containerd copy of the images on $SSH"
ssh "$SSH" "crictl --runtime-endpoint $OLD_SOCK pods -q | xargs -r crictl --runtime-endpoint $OLD_SOCK rmp -f >/dev/null 2>&1 || true; crictl --runtime-endpoint $OLD_SOCK rmi --all >/dev/null 2>&1 || true; echo \"disk free: \$(df -h / | tail -1 | awk '{print \$4}'); docker images: \$(docker images -q | wc -l)\""
echo
K get nodes -o wide --no-headers | awk '{print $1,$2,$NF}' | tr '\n' ';'; echo
