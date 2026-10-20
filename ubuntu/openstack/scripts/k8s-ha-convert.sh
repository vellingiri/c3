#!/usr/bin/env bash
# Convert a running single-control-plane kubeadm cluster so that its API address is the Octavia load balancer `<env>-api`
# (name api.<env>.rdulinux.com), ready for more control-plane nodes. Run from your Mac:
#   scripts/k8s-ha-convert.sh <env> [<kubeconfig>]        env = cka | qa | prod
# Needs first: the load balancer (scripts/octavia-k8s-api-lb.sh), its DNS name (infra/infra.yaml `api-<env>`, `terraform apply` in infra) and the
# member c1 ONLINE. Safe to re-run: every step checks whether it is already done. The API server of the first controller restarts once
# (about 30 to 60 s without the API; running pods keep running). Design, reasons and the rehearsal: docs/k8s-ha-control-plane.md.
#
# Steps: (1) backups; (2) kubeadm-config: controlPlaneEndpoint = the load balancer name, certSANs; (3) new API server certificate with those
# SANs, API server restarted; (4) every node's kubelet, kube-proxy, cluster-info and admin.conf point at the load balancer; (5) the join-command
# publisher (cloud-init/files/k8s-publish-join.sh) is installed on the first controller.
set -euo pipefail

ENV_NAME=${1:?env (cka|qa|prod)}
KCFG=${2:-$HOME/.kube/$ENV_NAME}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NAME="api.$ENV_NAME.rdulinux.com"
C1="c1.$ENV_NAME"
K() { kubectl --kubeconfig "$KCFG" --context "$ENV_NAME" "$@"; }
say() { printf '\n== %s\n' "$*"; }

say "checks"
FIP=$(dig +short "$NAME" @192.168.2.2 | tail -1)
[ -n "$FIP" ] || { echo "$NAME does not resolve (apply infra/infra.yaml first)" >&2; exit 1; }
echo "$NAME -> $FIP"
ssh "$C1" "getent hosts $NAME" >/dev/null || { echo "$C1 cannot resolve $NAME" >&2; exit 1; }
ssh "$C1" "timeout 5 bash -c 'echo > /dev/tcp/$FIP/6443'" || { echo "$FIP:6443 (the load balancer) is not reachable from $C1" >&2; exit 1; }
K get nodes --no-headers | awk '{print $1,$2}' | tr '\n' ' '; echo

say "1. backups on $C1 (/root/k8s-ha-convert-backup-*)"
ssh "$C1" 'T=$(date +%Y%m%d-%H%M%S); tar czf /root/k8s-ha-convert-backup-$T.tgz -C /etc kubernetes && ls -l /root/k8s-ha-convert-backup-$T.tgz | awk "{print \$5, \$9}"; /usr/local/sbin/etcd-snapshot 2>&1 | tail -1'

say "2+3. kubeadm-config and the API server certificate"
ssh "$C1" NAME="$NAME" FIP="$FIP" bash -s <<'REMOTE'
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
LOCAL_IP=$(hostname -I | awk '{print $1}')
OLD_EP=$(kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['controlPlaneEndpoint'])")
OLD_HOST=${OLD_EP%:*}
if [ "$OLD_EP" = "$NAME:6443" ] && openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName | grep -q "DNS:$NAME"; then
  echo "already converted (controlPlaneEndpoint $OLD_EP, certificate has $NAME)"; exit 0
fi
python3 - "$NAME" "$FIP" "$OLD_HOST" "$LOCAL_IP" <<'PY'
import subprocess, sys, yaml
name, fip, old_host, local_ip = sys.argv[1:5]
cm = yaml.safe_load(subprocess.check_output(["kubectl","-n","kube-system","get","cm","kubeadm-config","-o","yaml"]))
cc = yaml.safe_load(cm["data"]["ClusterConfiguration"])
cc["controlPlaneEndpoint"] = f"{name}:6443"
sans = list(cc.setdefault("apiServer", {}).get("certSANs", []))
for s in (name, fip, old_host, local_ip):
    if s and s not in sans: sans.append(s)
cc["apiServer"]["certSANs"] = sans
cm["data"]["ClusterConfiguration"] = yaml.safe_dump(cc, sort_keys=False)
for k in ("creationTimestamp","resourceVersion","uid"): cm["metadata"].pop(k, None)
open("/tmp/kubeadm-config-cm.yaml","w").write(yaml.safe_dump(cm, sort_keys=False))
init = {"apiVersion":"kubeadm.k8s.io/v1beta3","kind":"InitConfiguration","localAPIEndpoint":{"advertiseAddress":local_ip,"bindPort":6443}}
open("/tmp/kubeadm-cert.yaml","w").write(yaml.safe_dump(init, sort_keys=False) + "---\n" + yaml.safe_dump(cc, sort_keys=False))
print("certSANs:", sans)
PY
kubectl apply -f /tmp/kubeadm-config-cm.yaml >/dev/null
mkdir -p /root/pki-before-ha && cp -a /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key /root/pki-before-ha/
rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
kubeadm init phase certs apiserver --config /tmp/kubeadm-cert.yaml
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName | tail -1 | tr ',' '\n' | sed 's/^ *//' | tr '\n' ' '; echo
echo "restarting the API server (static pod)"
mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.moved
for i in $(seq 1 30); do crictl ps --name '^kube-apiserver$' -q | grep -q . || break; sleep 2; done
mv /root/kube-apiserver.yaml.moved /etc/kubernetes/manifests/kube-apiserver.yaml
for i in $(seq 1 60); do kubectl get --raw /livez >/dev/null 2>&1 && break; sleep 3; done
kubectl get --raw /livez; echo
REMOTE

say "verify through the load balancer with the new certificate"
K --server "https://$NAME:6443" get nodes --no-headers | awk '{print $1,$2}' | tr '\n' ' '; echo

say "4. every node and component points at $NAME"
NODES=$(K get nodes -o jsonpath='{.items[*].metadata.name}')
for n in $NODES; do
  if [ "$n" = c1 ]; then
    ssh "$C1" "sed -i 's#server: https://[^ ]*#server: https://$NAME:6443#' /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf && cp /etc/kubernetes/admin.conf /root/.kube/config && cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && systemctl restart kubelet"
  else
    ssh "$n.$ENV_NAME" "sed -i 's#server: https://[^ ]*#server: https://$NAME:6443#' /etc/kubernetes/kubelet.conf && systemctl restart kubelet"
  fi
  echo "$n: kubelet.conf -> $NAME"
done
K -n kube-system get cm kube-proxy -o yaml | sed "s#server: https://[^ ]*#server: https://$NAME:6443#" | K apply -f - >/dev/null
K -n kube-public get cm cluster-info -o yaml | python3 -c "
import sys, yaml, re
cm = yaml.safe_load(sys.stdin)
kc = cm['data']['kubeconfig']
cm['data']['kubeconfig'] = re.sub(r'server: https://[^\n ]*', 'server: https://$NAME:6443', kc)
for k in ('creationTimestamp','resourceVersion','uid'): cm['metadata'].pop(k, None)
print(yaml.safe_dump(cm))" | K apply -f - >/dev/null
K -n kube-system rollout restart ds/kube-proxy >/dev/null
K -n kube-system rollout status ds/kube-proxy --timeout=180s | tail -1

say "5. join-command publisher on $C1"
ssh "$C1" "echo $ENV_NAME > /etc/k8s-cluster-name"
scp -q "$HERE/cloud-init/files/k8s-publish-join.sh" "$C1:/usr/local/sbin/k8s-publish-join"
scp -q "$HERE/cloud-init/files/k8s-publish-join.service" "$HERE/cloud-init/files/k8s-publish-join.timer" "$C1:/etc/systemd/system/"
ssh "$C1" "chmod 0755 /usr/local/sbin/k8s-publish-join && systemctl daemon-reload && systemctl enable --now k8s-publish-join.timer >/dev/null 2>&1 && /usr/local/sbin/k8s-publish-join && ls -l /nfsshare/join-$ENV_NAME.sh /nfsshare/join-cp-$ENV_NAME.sh | awk '{print \$1, \$9}'; sed 's/--token [^ ]*/--token <hidden>/; s/--discovery-token-ca-cert-hash [^ ]*/--discovery-token-ca-cert-hash <hidden>/; s/--certificate-key [^ ]*/--certificate-key <hidden>/' /nfsshare/join-cp-$ENV_NAME.sh"

say "done: the API address of $ENV_NAME is https://$NAME:6443"
echo "Next: point your kubeconfig at it ('server:' in $KCFG), then add control-plane nodes in environments/$ENV_NAME/nodes.yaml (role controller_join)."
K get nodes --no-headers | awk '{print $1,$2}' | tr '\n' ' '; echo
