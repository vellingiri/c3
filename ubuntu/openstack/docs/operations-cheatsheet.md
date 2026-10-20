# Operations cheatsheet

Commands you need every week, and a "is everything healthy?" sweep. Details live in the linked docs. Written 2026-10-20 for a macOS/zsh workstation.

## Getting around
### ssh (aliases in `~/.ssh/config`)
| You type | Goes to | Notes |
|---|---|---|
| `ssh c1` `ssh w1` ... `ssh w5` | `<name>.prod.rdulinux.com` | prod Kubernetes nodes, user root, key `id_ed25519` |
| `ssh c1.prod` `ssh w2.qa` `ssh learn.qa` | `<name>.<env>.rdulinux.com` | any VM, either environment (`w1` exists in both: `ssh w1.prod`, `ssh w1.qa`) |
| `ssh db1` `ssh db2` | the two database VMs | key `id_ed25519.c3` |
| `ssh db` | whoever `db.rdulinux.com` points at (the primary) | after a failover your Mac may cache the old answer: `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder` |
| `ssh runner` `ssh repo` `ssh backup` `ssh c3` | shared services and the cloud host | key `id_ed25519.c3` |
`/opt/c3/bin/mssh host1 host2 ...` opens synchronized tmux panes (type once, runs on all).
The old `haproxy` and `qa` aliases are gone: the VM and the name were retired (`../CHANGELOG.md`).

### OpenStack CLI
Run on `c3`, whose login shell is already authenticated (the prompt reads `c3(keystone)`; there is no `admin-openrc.sh` to source), or from your Mac through `ssh c3 '<command>'`. On your Mac,
`source /opt/c3/ubuntu/openstack/scripts/openstack-shortcuts.sh` makes `openstack server list` show an `Env` column (prod/qa from the VM's metadata).
Server names repeat across environments: filter with `--tags prod|qa` or use the ID.

### Terraform
Needs `OS_*` and the MinIO keys for the S3 backend in your shell (without them: `403 InvalidAccessKeyId`). Order: `infra/` first, then `environments/<env>/`.
```bash
cd /opt/c3/ubuntu/openstack/infra && terraform plan                     # expect: no changes
cd ../environments/prod && terraform plan                              # a VM "must be replaced" means STOP
```
Never `apply` in `../archive/*` (retired). `terraform plan` clean on all three stacks is the definition of "Terraform and reality agree".

### kubectl (two clusters, never rely on the current context)
```bash
k() { kubectl --kubeconfig ~/.kube/prod -n finance "$@"; }            # use a function: K="kubectl ..." breaks in zsh
kubectl --kubeconfig ~/.kube/prod get nodes                           # prod: c1 w1 w2 w3 w4 w5
kubectl --kubeconfig ~/.kube/qa get nodes                             # qa: c1 w1 w2 w3 (spare)
```

## Is everything healthy? (about 2 minutes)
| Check | Command | Healthy |
|---|---|---|
| DNS | `for n in finance argo db db1 db2; do echo $n $(dig +short $n.rdulinux.com @192.168.2.2); done` | `.5`, `.113`, `.124`, `.124`, `.135` |
| Finance front door | `curl -s -o /dev/null -w '%{http_code}\n' http://finance.rdulinux.com/health` | 200 (**does not test the database**) |
| Argo | `curl -s -o /dev/null -w '%{http_code}\n' http://argo.rdulinux.com/` | 200 |
| Load balancers | `ssh c3 'openstack loadbalancer list; openstack loadbalancer member list finance-pool; openstack loadbalancer member list argo-backend'` | `ACTIVE`/`ONLINE`, 4 members `ONLINE` each |
| Kubernetes | `kubectl --kubeconfig ~/.kube/prod get nodes` and `k get pods -o wide` and `k get pdb` | 6 nodes Ready (c1 + w1 to w5); 3 of backend, frontend, docs, nginx, each on a different node |
| Argo app | `kubectl --kubeconfig ~/.kube/prod -n argocd get application finance-qa` | Synced, Healthy |
| Database path | `k exec deploy/backend -- sh -c 'psql "$DATABASE_URL" -qAt -c "select inet_server_addr(), pg_is_in_recovery()"'` | `10.0.1.191`, `f` |
| Replication | `scripts/db-replication-status.sh db1 db2` | `streaming, behind: 0 bytes`, exit 0 |
| Monitor | `ssh runner 'systemctl is-active db-monitor.timer; /usr/local/sbin/db-replication-monitor --dry-run'` | `active`; `db1 primary, db2 replica, lag 0 bytes` |
| Backups | `k get cronjob` and `k get jobs --sort-by=.metadata.creationTimestamp \| tail -3` | hourly and daily jobs `Complete` |
| etcd snapshots | `ssh c1.prod 'ls -lh /var/backups/etcd \| tail -3'` | a recent file |
| CI | `gh run list --repo vellingiri/finance --limit 3` | `completed/success` |

## Credentials: where they are (never in git, never paste them in chat)
| Secret | Lives in |
|---|---|
| OpenStack admin login | the login environment of root on `c3` (not a file in this repo; the prompt shows `c3(keystone)`) |
| Terraform state (MinIO) keys | your shell environment |
| App secrets, DB URL, registry login | Kubernetes secrets `app-secret`, `db-secret`, `ghcr-secret` in namespace `finance` (copied between clusters with `scripts/k8s-copy-between.sh`) |
| Argo CD admin login, repo credential | secrets `argocd-secret` and a repository secret in namespace `argocd` |
| Database roles | `postgres` (peer auth on the VM), `financeapp` (in `db-secret`), `replicator` (replica's `/var/lib/postgresql/.pgpass`), `monitor` (runner's `/etc/default/db-monitor`) |
| Alert channel (ntfy topic) | `/etc/default/db-monitor` on the runner: anyone who knows the topic can read or post to it |
| GitHub runner registration | on the runner VM (`github-runner.service`) |

## macOS and zsh traps (each one cost time once)
- A variable that holds a command (`K="kubectl ..."; $K get pods`) does not split in zsh: use a function.
- `sed -i` needs an empty suffix on macOS: `sed -i '' ...`.
- An unquoted `*` that matches nothing is an error in zsh: quote it.
- `status` is a read-only variable in zsh.
- macOS `nc -z host port` needs about 75 s to give up on a dead host: use `-w 2` and do not rely on it for timing.
- macOS caches DNS beyond a record's TTL: flush it (command above) before concluding a DNS change did not work.
- `kubectl exec ... -- python -` needs `-i` or the script is not sent.

## When something is wrong, start here
| Symptom | Go to |
|---|---|
| Database primary lost, or replication alert | `db-replication.md` |
| `finance.rdulinux.com` or `argo.rdulinux.com` down | `octavia-finance-lb.md`, then `k8s-operations.md` |
| Adding or retiring a worker, drain stuck, rollout stuck | `k8s-operations.md` |
| Control plane lost, whole cluster rebuild | `prod-k8s-rebuild.md`, `etcd-restore-rehearsal.md` |
| Need to restore data | `finance-db-restore.md` |
| `409 Port in use`, `NoValidHost`, `FloatingIPNotFound` | `../README.md` (Troubleshooting) and `octavia-finance-lb.md` (Pitfalls) |
