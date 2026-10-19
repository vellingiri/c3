#!/usr/bin/env bash
# Copy Kubernetes object(s) from one cluster to another using two local kubeconfigs. Nothing is written
# to disk and nothing is printed except kubectl's "created/configured" lines, so secrets stay in the pipe.
#   k8s-copy-between.sh <src-kubeconfig> <src-context> <dst-kubeconfig> <dst-context> <kubectl get args...>
#   k8s-copy-between.sh ~/.kube/prod prod ~/.kube/qa qa -n finance secret app-secret db-secret
# Strips cluster-specific fields (uid, resourceVersion, status, PV claimRef, Service clusterIP, ...).
set -euo pipefail
SRC_CFG=${1:?src kubeconfig}; SRC_CTX=${2:?src context}; DST_CFG=${3:?dst kubeconfig}; DST_CTX=${4:?dst context}
shift 4
kubectl --kubeconfig "$SRC_CFG" --context "$SRC_CTX" get "$@" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
items = d["items"] if d.get("kind") == "List" else [d]
for o in items:
    m = o["metadata"]
    for k in ("uid", "resourceVersion", "creationTimestamp", "selfLink", "generation", "managedFields", "ownerReferences"):
        m.pop(k, None)
    for a in ("pv.kubernetes.io/bind-completed", "pv.kubernetes.io/bound-by-controller"):
        m.get("annotations", {}).pop(a, None)
    o.pop("status", None); o.pop("operation", None)
    kind = o.get("kind")
    if kind == "PersistentVolume":
        o["spec"].pop("claimRef", None)
    if kind == "Service":
        for k in ("clusterIP", "clusterIPs"):
            o["spec"].pop(k, None)
json.dump(d, sys.stdout)
' | kubectl --kubeconfig "$DST_CFG" --context "$DST_CTX" apply --server-side --force-conflicts -f -
