# Rebuild the prod k8s cluster (park workloads on QA)

Goal: recreate `c1`, `w1..3` from the current cloud-init (proper hostnames /
node names) with almost no downtime, by running the workloads on the QA cluster meanwhile.

## What runs in prod (from the 2026-10-17 inventory)
| Where | What |
|---|---|
| ns `argocd` | Argo CD v3.5.1 (7 pods), one Application `finance-qa`, one repo credential |
| ns `finance` | Deployments backend, docs, frontend, nginx; CronJobs db-backup-hourly/daily |
| finance secrets | `app-secret`, `db-secret`, `ghcr-secret` (not in git) |
| finance storage | 3 NFS PVs on `repo.rdulinux.com:/exports/finance-qa/{backups/finance,logs,uploads}` (data stays on NFS) |
| database | the shared `db` VM, outside the cluster |
| Exposure | `finance/nginx` NodePort 30080, `argocd-server` NodePort 30443, haproxy routes to both |
| Git | `https://github.com/vellingiri/finance.git`, path `k8s`, branch `develop` |

## Key facts that make this safe
- A replaced VM keeps its port and floating IP (separate Terraform resources), so private and
  floating IPs, haproxy backends and any IP allow-lists do not change.
- Until Phase 3 nothing in prod is modified. To roll back before then, restore the haproxy config.
- Never run the same CronJobs in both clusters (they write to the same NFS backup dir).

Helper: `scripts/k8s-copy.sh` (run on c1.prod.rdulinux.com) pipes objects to QA over ssh without writing
them to disk. Copy it to c1.prod.rdulinux.com first: `scp scripts/k8s-copy.sh root@c1.prod.rdulinux.com:/usr/local/bin/`.

---

## Phase 0 - preflight (read-only on prod)
On `c1.prod.rdulinux.com`:
```bash
# what Argo manages (are PV/PVC in git or hand-made?)
kubectl -n argocd get application finance-qa -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{"\n"}{end}'
# sync policy (selfHeal would fight a manual suspend)
kubectl -n argocd get application finance-qa -o jsonpath='{.spec.syncPolicy}{"\n"}'
# a fresh backup, and prove it ran
kubectl -n finance create job --from=cronjob/db-backup-daily pre-move-backup
kubectl -n finance logs job/pre-move-backup
# final etcd snapshot of the old cluster (kept as rollback evidence)
sudo systemctl start etcd-snapshot.service && ls -lh /var/backups/etcd
```
The VM disk is destroyed in Phase 3, so copy that snapshot OFF the VM now, e.g. from your Mac:
`scp root@c1.prod.rdulinux.com:/var/backups/etcd/etcd-*.db ~/`
On `db`: the Postgres allow-list must accept the QA workers (`10.0.1.118`, `.10`, `.96`):
```bash
sudo grep -vE '^\s*(#|$)' /etc/postgresql/*/main/pg_hba.conf
```
If it lists individual prod IPs instead of `10.0.1.0/24`, add the QA IPs before Phase 1.

## Phase 1 - prepare QA (nothing user-visible)
1. **Free NodePort 30080 on QA.** The QA ingress-nginx owns it and has no apps, so remove it
   for now (re-install later if wanted):
   ```bash
   # on c1.qa.rdulinux.com
   kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/baremetal/deploy.yaml
   ```
2. **Install Argo CD with the same version** on QA:
   ```bash
   # on c1.qa.rdulinux.com
   kubectl create ns argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.1/manifests/install.yaml
   ```
3. **Copy Argo config and repo credential** (on c1.prod.rdulinux.com):
   ```bash
   k8s-copy.sh c1.qa.rdulinux.com -n argocd configmap argocd-cm argocd-cmd-params-cm argocd-rbac-cm
   k8s-copy.sh c1.qa.rdulinux.com -n argocd secret -l argocd.argoproj.io/secret-type=repository
   ssh root@c1.qa.rdulinux.com kubectl -n argocd rollout restart deploy/argocd-server
   ```
4. **Finance namespace, secrets, storage** (on c1.prod.rdulinux.com):
   ```bash
   ssh root@c1.qa.rdulinux.com kubectl create ns finance
   k8s-copy.sh c1.qa.rdulinux.com -n finance secret app-secret db-secret ghcr-secret
   k8s-copy.sh c1.qa.rdulinux.com pv finance-backups finance-logs finance-uploads
   k8s-copy.sh c1.qa.rdulinux.com -n finance pvc backups-pvc logs-pvc uploads-pvc
   k8s-copy.sh c1.qa.rdulinux.com -n finance configmap nginx-config    # skip if Phase 0 shows it is in git
   ```
5. **Create the Application** and let it sync (on c1.prod.rdulinux.com):
   ```bash
   k8s-copy.sh c1.qa.rdulinux.com -n argocd application finance-qa
   ```
6. **Suspend the CronJobs on QA straight away** (prod keeps running them):
   ```bash
   # on c1.qa.rdulinux.com
   kubectl -n finance patch cronjob db-backup-hourly db-backup-daily -p '{"spec":{"suspend":true}}'
   ```
   (If the Application has `selfHeal`, Argo may revert this; then pause its auto-sync instead.)
7. **Verify on QA** without touching haproxy:
   ```bash
   kubectl -n finance get pods,pvc
   curl -s -o /dev/null -w '%{http_code}\n' http://192.168.2.59:30080/     # compare with prod: curl http://192.168.2.152:30080/
   ```
   Backend must reach the DB: `kubectl -n finance logs deploy/backend --tail=30`.

## Phase 2 - cut over to QA (seconds of impact)
On `haproxy` (config is also in the repo: `cloud-init/haproxy.cfg`):
```bash
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.pre-park
# point k8s_nodes at the QA workers (port 30080 is the same on QA now)
sudo sed -i -E '/^backend k8s_nodes/,/^$/ { s/192\.168\.2\.152/192.168.2.59/; s/192\.168\.2\.193/192.168.2.98/; s/192\.168\.2\.139/192.168.2.136/ }' /etc/haproxy/haproxy.cfg
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
```
Then:
```bash
# prod: stop backups.   QA: start them.
ssh root@c1.prod.rdulinux.com kubectl -n finance patch cronjob db-backup-hourly db-backup-daily -p '{"spec":{"suspend":true}}'
ssh root@c1.qa.rdulinux.com   kubectl -n finance patch cronjob db-backup-hourly db-backup-daily -p '{"spec":{"suspend":false}}'
```
Argo UI during the rebuild (optional): on QA patch `argocd-server` to nodePort 30443 and point
`backend argocd_nodes` at the QA IPs the same way.

Check the real site, then wait a day if you want extra safety before Phase 3.

## Phase 3 - rebuild prod (prod is idle)
Final copy of anything not in git or NFS (nothing identified; re-check Phase 0 list).
```bash
cd environments/prod
terraform apply \
  -replace='module.node["c1"].openstack_compute_instance_v2.this' \
  -replace='module.node["w1"].openstack_compute_instance_v2.this' \
  -replace='module.node["w2"].openstack_compute_instance_v2.this' \
  -replace='module.node["w3"].openstack_compute_instance_v2.this'
```
Read the plan: only the 4 instances (and nothing with `floatingip` or `port` being destroyed).
If a replaced VM fails with `409 Port ... is still in use`, clear the stale `device_id` on its port
(see README, Troubleshooting) and apply again.
The new nodes boot with their plain hostnames (`c1`, `w1`...); the controller runs `kubeadm init` and publishes
`/nfsshare/join-prod.sh`; workers join by themselves. Expect `kubectl get nodes` to show
`c1 w1 w2 w3` after ~3-5 minutes. SSH host keys change (clear known_hosts).

## Phase 4 - move back
Repeat Phase 1 steps 2-5 **from QA to prod** (reverse the direction; `k8s-copy.sh` works from
`c1.qa.rdulinux.com` to `c1.prod.rdulinux.com`), with these differences:
- no need to delete anything; prod has no ingress-nginx,
- install the prod Argo with NodePort 30443 for `argo.rdulinux.com` (patch `argocd-server`).

Then:
```bash
# haproxy back to the prod workers
sudo cp /etc/haproxy/haproxy.cfg.pre-park /etc/haproxy/haproxy.cfg
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
# backups: QA off, prod on
```
Clean up QA: delete `finance` and `argocd` namespaces, optionally re-install ingress-nginx.
Finally: take a new etcd snapshot on `c1.prod.rdulinux.com` (the timer is installed by cloud-init) and
delete the old `/var/backups/etcd` evidence if you do not need it.

## Rollback
- Before Phase 3: restore `haproxy.cfg.pre-park`, re-enable prod CronJobs. Prod was never changed.
- After Phase 3: QA is still serving; fix prod, or restore the old etcd snapshot onto a new control plane.

## Executed 2026-10-19 (what actually happened, and what differed from the plan above)
Result: prod VMs rebuilt with correct hostnames and node names; no user-visible outage (haproxy swapped twice, a reload each).

- **Gate before touching anything:** the finance DB backup was restored into a scratch database (85/85 tables, identical row
  counts) and an etcd snapshot restore was rehearsed on QA first. See `finance-db-restore.md` and `etcd-restore-rehearsal.md`.
  A safety tarball of NFS `uploads` + `backups` went to `backup:/backup/finance-qa/pre-rebuild-20261019/`.
- **Argo manages everything in `finance`** (namespace, PVs/PVCs, NetworkPolicies, Services, Deployments, CronJobs) with
  `automated: {prune, selfHeal}`. So only what is NOT in git had to be copied: the 3 finance secrets, Argo's repo credentials,
  `argocd-secret` (keeps the admin login) and the `server.insecure` setting in `argocd-cmd-params-cm`.
- **CronJobs:** `selfHeal` reverts a manual suspend, so the parked Application was created with auto-sync OFF and synced
  without the two CronJobs; they were synced onto the other cluster only after the first one was suspended.
  The original Application (with auto-sync) was saved first: `~/finance-argo-application.prod.json`.
- **Same images, same git revision** on both clusters; public paths compared by status + content hash before each switch.
- **Use `scripts/k8s-copy-between.sh`** (two local kubeconfigs) instead of `k8s-copy.sh`; secrets never touch disk or the screen.
  Always pass `--context`: `ktx` leaves `current-context` pointing at the other cluster in both kubeconfig files.
- **QA's ingress-nginx must be removed while parked** (it owns NodePort 30080); `scripts/install-ingress-nginx.sh` restores it.
- **`cloud-init status` says `error - running` during `kubeadm init`.** That is the harmless `update-locale` message plus
  "still running"; wait for `done` (about 3 minutes). Workers joined on their own (join retry).
- **After the rebuild** the kubeconfig had to be replaced (new CA): fetch `~/.kube/config` from the controller and rename
  the entries to the context names you use.
- **haproxy:** restore the saved `haproxy.cfg.pre-park` rather than reversing the edit with `sed` (the QA backend has
  identical-looking lines). A copy of the parked config is kept as `haproxy.cfg.parked-on-qa`.
