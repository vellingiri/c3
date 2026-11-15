# Stopping and starting all the VMs of one environment (maintenance window)

`scripts/env-vms.py` brings every VM of **one environment** (`prod`, `cka`, `qa`) down in a safe order and back up again, from your Mac, with no Terraform. Written 2026-11-15.

```bash
scripts/env-vms.py prod status                    # VMs and their state, Kubernetes nodes Ready, Patroni roles
scripts/env-vms.py prod stop --dry-run          # the plan, nothing changes
scripts/env-vms.py prod stop                    # no confirmation question (add --confirm to be asked to type "prod")
scripts/env-vms.py prod start                    # brings back exactly what the last stop stopped
scripts/env-vms.py prod start --all              # every VM of the environment that is SHUTOFF (no saved list needed)
scripts/env-vms.py prod stop  --lbs             # ALSO the load-balancer VMs (Octavia amphorae) of the environment
scripts/env-vms.py prod start                    # brings the amphorae back too when `stop --lbs` marked them (--all --lbs for unmarked ones)
```

## How it picks the VMs and the order
- **Which VMs:** those whose Nova metadata says `env=<env>` (Terraform sets `env` and `role` on every node). The Octavia amphorae have no `env`, so **by default the load balancers are not touched**; they just mark their members down while the VMs are off. With **`--lbs`** the amphorae of the environment's load balancers are included (prod: `finance-lb`, `argo-lb`, `prod-api`, 6 VMs; cka: `cka-api`, 1 VM; change the mapping with `ENV_LBS="prod=a,b;cka=c"`). They are found through `openstack loadbalancer amphora list` (the server is called `amphora-<amphora id>`).
- **Stop order** (a graceful ACPI shutdown; Nova forces the power-off after its own timeout; the kubelet's graceful-shutdown setting stops the pods first), each tier waited for until every VM is `SHUTOFF`:
  1. the GitHub runner (`ci1-prod`), 2. the workers, 3. the control planes, 4. the databases: the **Patroni standby first, the leader last** (it asks Patroni who the leader is), 5. the witness (`dbw1-prod`, an etcd member).
- **Load balancers (`--lbs`) and the Octavia health manager.** The health manager rebuilds an amphora that is silent for `heartbeat_timeout` (300 s), so with `--lbs` the script **stops `octavia-health-manager` on c3 before the first amphora is stopped**, stops the amphorae **last**, and on `start` brings them back **first**, waits 90 s (`LB_SETTLE`) for them to boot and send heartbeats, and only then starts the health manager again. At the end of every `start` it checks that the health manager is running (and starts it if not), and prints the load balancers' state. `status` shows the load balancers and the health manager. If a stop dies half way, run `start`: it also fixes the health manager.
- **Start order** is the exact reverse: witness, database **leader**, standby, control planes, workers, runner. It also waits for what the next step needs: a Patroni leader before the control planes, the API server before the workers, then every node Ready.
- At the end of a start it deletes the `Error` / `ContainerStatusUnknown` pod records a graceful shutdown leaves (`kubectl delete pod -A --field-selector=status.phase=Failed`; `--no-cleanup` skips it) and prints the checks: nodes, Patroni, and for prod the finance front door.
- **What was stopped is remembered twice:** in `~/.cache/c3-env-vms/<env>.json` on the machine that ran `stop`, **and in OpenStack** as the properties `maint_stopped` / `maint_sub` on each stopped VM (`openstack server show <vm> -c properties`). So you can stop on c3 and start from your Mac, or the other way round. A VM that was off on purpose carries no mark and is not started by `start`; the marks are removed after a successful start. Running `stop` twice merges the lists. After a successful `start` the file is renamed `<env>.json.last`.
- It reaches OpenStack with `ssh c3` (admin credentials in `/root/.bashrc`), the cluster with `~/.kube/<env>` (context `<env>`) and the databases with ssh names like `db1-prod`. Set `C3_HOST` to use another name for c3.

## Good to know
- **`s3-prod` is never stopped or started by this script** (role `objstore`, `NEVER_STOP_ROLES`). It is the Terraform state store; `status` does not list it. An older copy of the script does not know this and would stop it: update every copy.
- **Terraform is not needed to start.** A later `terraform plan` simply sees the VMs active (it was how you started them before; both work).
- **Downtime:** the app is down from the first tier on. For prod expect roughly 5 minutes to stop and 8 to 10 to start (databases, then the control planes, then the pods are rescheduled).
- **Do not start a half-stopped environment by hand in the wrong order:** a worker before the databases is fine, but a database leader that is not the one stopped last can start second; `start` always brings the leader first.
- **A VM that does not stop** within 6 minutes makes the script stop and name it; nothing further is stopped, and `start` still brings back what was stopped.
- **Not covered:** c3 itself (use `scripts/c3-vms-stop.sh` / `c3-vms-start.sh` for the whole host: those stop every VM on c3 including the amphorae, with the Octavia health manager handled), the `backup` host, the router.
- **Tested:** `status`, `stop --dry-run`, `start --dry-run` and `start --all --dry-run` against prod and cka on 2026-11-15, plus the error cases (unknown environment, no saved list). **A live `start cka --all` was run on 2026-11-15** with all four cka VMs off: control plane first, API ok, then the three workers, 4 of 4 nodes Ready, 0 leftover Error pod records, cluster healthy afterwards. A live **stop** and the prod path (databases and Patroni waits) have not been exercised yet; do a first stop/start round trip on cka before relying on it for prod.
