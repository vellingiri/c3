#!/usr/bin/env bash
# Install ingress-nginx on a cluster as a NodePort (default 30080, the port the load balancer used to route to).
#   scripts/install-ingress-nginx.sh <controller-host> [nodeport]    e.g. c1.qa.rdulinux.com
# Safe to re-run. Do not use on a cluster where another service already owns the NodePort.
set -euo pipefail
HOST=${1:?controller host, e.g. c1.qa.rdulinux.com}
PORT=${2:-30080}
VER=controller-v1.11.2
SSH_USER=${SSH_USER:-root}

ssh "$SSH_USER@$HOST" bash -s -- "$PORT" "$VER" <<'REMOTE'
set -euo pipefail
PORT=$1; VER=$2
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$VER/deploy/static/provider/baremetal/deploy.yaml"
kubectl -n ingress-nginx patch svc ingress-nginx-controller --type merge -p \
  "{\"spec\":{\"ports\":[{\"name\":\"http\",\"port\":80,\"targetPort\":\"http\",\"nodePort\":$PORT,\"protocol\":\"TCP\"},{\"name\":\"https\",\"port\":443,\"targetPort\":\"https\",\"protocol\":\"TCP\"}]}}"
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
kubectl -n ingress-nginx get pods,svc
REMOTE
echo "Test: curl -s -o /dev/null -w '%{http_code}\n' http://<a worker floating IP>:$PORT/   (404 = ingress is up, no rules yet)"
