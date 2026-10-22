# Kubernetes operations: the finance app on the prod cluster

Runbook for day-to-day and for node changes. Facts checked against the manifests (finance repo `k8s/`) and the live cluster on 2026-10-20.
Where things are: `ARCHITECTURE.md`. Rebuilding a whole cluster: `prod-k8s-rebuild.md`.

## How the app is built to survive a node loss (since 2026-10-20)
Every app (`backend`, `frontend`, `docs`, `nginx`) runs **3 replicas, one per node**, on the 3 workers (`w1` to `w3`) since `w4` and `w5` were retired on 2026-10-20. **There is no free node any more:** draining a worker now leaves one replica per app pending until the node is back (the PodDisruptionBudgets hold the drain), so add a 4th worker before planned node work (`Add a worker` below).
| Setting | Value | Why |
|---|---|---|
| `replicas` | 3 | one can be lost or updated while 2 still serve |
| Pod anti-affinity (required, by hostname) | no two pods of one app on a node | a node loss costs one pod per app, never two |
| `topologySpreadConstraints` (maxSkew 1, `DoNotSchedule`, `nodeTaintsPolicy: Honor`) | even spread | `Honor` is needed: without it the tainted control plane counts as an empty domain and blocks scheduling |
| `PodDisruptionBudget` `minAvailable: 2` (one per app) | drains evict one pod at a time | a drain can never take two copies |
| `strategy: RollingUpdate`, `maxUnavailable: 1`, `maxSurge: 0` | one pod replaced at a time, no extra pod | with required anti-affinity a surge pod would have no node to land on |
| Tolerations for `unreachable` / `not-ready`, `tolerationSeconds: 30` | pods of a dead node reschedule after 30 s | default is 5 minutes |
| `preStop: sleep 8` (backend, nginx) | pod stays up while the load balancer stops sending to it | no dropped requests during rollouts and drains |
| nginx `readinessProbe` on `/health` | a pod gets traffic only when it answers | |
Consequences to remember:
- **You need at least 4 workers** (prod has 5). With 3, a drain leaves the evicted pod Pending (every other node already has one) and the app runs on 2 copies until the node is back.
- **Adding workers beyond 3 does not spread the app further**: 3 replicas occupy 3 nodes, and a new worker stays idle until a rollout places a pod there. Raise `replicas` in git if you want more, and read the next point.
- **nginx's login rate limit (`20r/m`, burst 10) is per pod**, so 3 pods allow about 3 times the limit of one. Lockouts and limits counted by address are per pod too.
- **Argo CD's `selfHeal` reverts manual changes** (scaling, suspending a CronJob, editing a Deployment). Change git, or pause auto-sync (below).

## Everyday checks
```bash
k() { kubectl --kubeconfig ~/.kube/prod -n finance "$@"; }          # a function: K="kubectl ..." breaks in zsh
kubectl --kubeconfig ~/.kube/prod get nodes
k get pods -o wide                                                    # 3 of each, each on a different node
k get pdb                                                             # ALLOWED DISRUPTIONS 1 each when healthy
kubectl --kubeconfig ~/.kube/prod -n argocd get application finance-qa   # Synced / Healthy
curl -s -o /dev/null -w '%{http_code}\n' http://finance.rdulinux.com/health
```
`/health` answers 200 even if the database is down (it does not check it). To test the database path use
`k exec deploy/backend -- sh -c 'psql "$DATABASE_URL" -qAt -c "select inet_server_addr(), pg_is_in_recovery()"'`.

## Add a worker
1. `environments/prod/nodes.yaml`: add `w6: { role: worker, flavor: m1.small }`. Check room first (`ARCHITECTURE.md`, Capacity; a failed build says `NoValidHost`).
   `terraform plan`, then `apply`. The VM gets its name, floating IP and DNS record.
2. It joins by itself using `/nfsshare/join-prod.sh` (retries 5 times). The token lasts **24 hours**; if it is older, recreate it on `c1` first:
   `ssh c1.prod 'sudo kubeadm token create --print-join-command | sudo tee /nfsshare/join-prod.sh'`.
3. `kubectl get nodes` until it is `Ready` (to test its NodePort run `curl http://<its private or floating IP>:30080/health` **from `c3`**, not from your Mac; see `operations-cheatsheet.md`, Reachability) (cloud-init shows `error - running` until the install ends: the harmless `update-locale` message).
4. **Add it to both load balancers** (they do not follow Kubernetes nodes): see `octavia-finance-lb.md`, "Workers change over time".
   `finance-pool` on `finance-lb` (port 30080) and `argo-backend` on `argo-lb` (port 30443). Confirm members go `ONLINE`.
5. Existing pods stay where they are. To use the new node, roll the apps one by one: `k rollout restart deploy/backend` (then `frontend`, `docs`, `nginx`),
   waiting for each (`k rollout status deploy/backend`). Anti-affinity picks a node without a copy.

## Retire any node (script) / what not to do
Use **`scripts/k8s-retire-node.sh <env> <node>`** (drain, etcd member removal for control-plane nodes, node delete) and only then edit `nodes.yaml` and apply. Destroying a VM first leaves a `NotReady` node object and, for a control-plane node, a dead etcd member that can cost the cluster its etcd majority (the API hangs): `k8s-ha-control-plane.md`, "Removing a node". The manual steps below are what the script does for a worker.

## Retire a worker (the order matters)
1. **Remove it from both pools first** (`openstack loadbalancer member delete finance-pool wN`, `... argo-backend wN`). Traffic stops going there within seconds.
   (If you forget, traffic still works: any node forwards NodePort traffic through kube-proxy. But the node's health check will start failing once it is drained.)
2. `kubectl drain wN --ignore-daemonsets --delete-emptydir-data`. It evicts one pod at a time because of the PodDisruptionBudgets; each replacement
   starts on a free node (needs the 4th worker) and the drain moves on once the budget allows. Expect a few minutes. Do not use `--force` or `--disable-eviction`.
3. Check `k get pods -o wide`: 3 of each, none on `wN`, and `k get pdb`.
4. `kubectl delete node wN`; remove the entry from `nodes.yaml`; `terraform plan` (expect the VM, its port, floating IP and DNS records destroyed, nothing else) and `apply`.
5. If the node is already dead, skip the drain: its pods reschedule by themselves after the 30 s toleration. Still do steps 1, 4 and 5.
Worked example (2026-10-20, `w1` retired): pools edited, drain with 81 probe checks and 0 failures, all apps back to 3/3 on three other nodes, Argo Synced/Healthy.

## What happens when a node dies without warning
- The load balancer's health check (every 5 s, 3 failures) removes it within about 15 s.
- Kubernetes marks it `NotReady`; its pods are evicted after 30 s and recreated on the free node. During that time the app still has 2 copies of everything.
- Nothing to do except replace the node later (`terraform apply -replace='module.node["wN"].openstack_compute_instance_v2.this'`; a `409 Port ... in use` is
  fixed with `scripts/clear-stale-port.sh`, see `../README.md`). The control plane `c1` is the exception: see `prod-k8s-rebuild.md`.

## Deploying and rolling back
- CI (`.github/workflows/ci.yml`) on a push to `develop`: tests, builds and scans the images, then **"Restart QA Pods"** pins the Argo application to that commit's
  images and waits for the rollout; it then runs the household-isolation checks and the browser journeys. (This is the prod Kubernetes cluster: see the glossary in `ARCHITECTURE.md`.)
  A push to `main` runs the separate production deploy to the Docker Compose host.
- A rollout takes one pod at a time per app and keeps 2 serving. If `k rollout status` hangs, `k get pods -o wide` and `k describe pod` on the Pending one:
  the usual causes are a missing free node or the spread constraint.
- Roll back by reverting the commit on `develop` (Argo and CI do the rest) or `k rollout undo deploy/backend` as an emergency (Argo will revert it on the next sync unless
  you pause auto-sync).
- Pause Argo CD auto-sync for an emergency edit, and restore it afterwards:
  ```bash
  kubectl --kubeconfig ~/.kube/prod -n argocd patch application finance-qa --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
  # ... fix ...
  kubectl --kubeconfig ~/.kube/prod -n argocd patch application finance-qa --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
  ```
  The application tracks `https://github.com/vellingiri/finance.git`, path `k8s`, branch `develop`. A saved copy of the original is in `~/finance-argo-application.prod.json` on your Mac.

## Kubeconfigs
`~/.kube/prod` and `~/.kube/cka` (practice cluster) are separate files (`~/.kube/qa` is stale: the `qa` cluster was destroyed 2026-10-22), all listed in `KUBECONFIG` in `~/.bash_profile` (backups from before the rebuild: `prod.bak-old-cluster`, `qa.bak-old-c2`). Always pass `--kubeconfig` (or `--context`):
a tool like `ktx` leaves `current-context` pointing at the other cluster in both files. After a cluster rebuild the CA changes: fetch `~/.kube/config` from `c1`
(`ssh c1.prod cat ~/.kube/config`) and rename the entries. The GitHub runner has its own kubeconfig at `/home/runner/.kube/config`; after a rebuild it must be replaced too
(CI then fails with `x509: certificate signed by unknown authority` until it is).

## Things that bit us (and the fix)
| Symptom | Cause | Fix |
|---|---|---|
| Rollout stuck, new pod Pending | spread constraint counted the tainted control plane as an empty domain | `nodeTaintsPolicy: Honor` (in git) |
| One node had 2 pods of an app after a rollout | spread alone allows it when a node is cordoned | required anti-affinity (in git) |
| Browser journeys failed in CI | nginx login rate limit with a single pod; passes with 3 | keep 3 nginx pods; the limit is per pod |
| `argo.rdulinux.com` showed the finance app | L7 rule matched only the exact host | Argo now has its own load balancer (`argo-lb`) |
| `kubectl` used the wrong cluster | `ktx` leaves `current-context` on the other one | pass `--kubeconfig` |
