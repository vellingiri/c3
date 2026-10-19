#!/usr/bin/env bash
# Copy Kubernetes object(s) to another cluster over ssh. Nothing is written to disk,
# so secrets only ever travel through the pipe. Run it ON the source controller:
#
#   k8s-copy.sh <dest-controller-host> <kubectl get args...>
#   k8s-copy.sh c1.qa.rdulinux.com -n finance secret app-secret db-secret ghcr-secret
#
# Strips cluster-specific fields (uid, resourceVersion, status, PV claimRef, Service clusterIP, ...)
# so the object can be applied cleanly on the destination.
set -euo pipefail
DEST=${1:?destination controller host}; shift
kubectl get "$@" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
items = d["items"] if d.get("kind") == "List" else [d]
for o in items:
    m = o["metadata"]
    for k in ("uid", "resourceVersion", "creationTimestamp", "selfLink", "generation",
              "managedFields", "ownerReferences"):
        m.pop(k, None)
    for a in ("pv.kubernetes.io/bind-completed", "pv.kubernetes.io/bound-by-controller"):
        m.get("annotations", {}).pop(a, None)
    o.pop("status", None)
    o.pop("operation", None)
    kind = o.get("kind")
    if kind == "PersistentVolume":
        o["spec"].pop("claimRef", None)
    if kind == "Service":
        for k in ("clusterIP", "clusterIPs"):
            o["spec"].pop(k, None)
json.dump(d, sys.stdout)
' | ssh "root@$DEST" kubectl apply -f -
