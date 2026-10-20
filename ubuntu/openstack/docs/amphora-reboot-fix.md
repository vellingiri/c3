# Load balancers and host reboots: why they broke and the permanent fix

Diagnosed and fixed **2026-10-20**. After a reboot of the cloud host `c3` the VMs came back (once autostart was configured) but **both front doors stayed down** until someone repaired the load balancers by hand.
It is now fixed: a plain `reboot` of `c3` with everything running brings both doors back by themselves (about 3 minutes after `c3` answers ssh), with no rebuilt amphorae and no manual step.
Related: `c3-reboot.md` (the reboot procedure), `octavia-finance-lb.md` (the load balancers), `c3-host-route.md`.

## What was wrong (four separate problems)
| # | Problem | Evidence | Fixed by |
|---|---|---|---|
| 1 | **The amphora image loses its VIP network after a clean stop and start.** Its boot script has two defects (below). | After a host reboot every amphora answered on its agent port but reported `"networks": {}`; reproduced on one amphora with `openstack server stop` then `start` (VIP down). A hard reboot of the same VM kept the VIP | patched image |
| 2 | **OVN's router keeps a stale or wrong MAC for a VIP.** | Router options `always_learn_from_arp_request="false"`, `mac_binding_age_threshold="0"`: it never learns a new MAC from an amphora's announcement and never ages the old one out. After a rebuild (or a new keepalived election after a boot) it still pointed at the old amphora, or at the unbound VIP placeholder port's MAC | watcher on `c3` |
| 3 | **Octavia's health manager judges amphorae dead after a host reboot** and rebuilds them. | Heartbeats are received by the health manager itself, so while it (or the host) is off the stored timestamps go stale. On start it saw every amphora as dead; rebuilds then failed intermittently and left a load balancer in `ERROR` | `heartbeat_timeout = 900` (+ `failover_threshold = 2`) |
| 4 | **Nova did not restart the VMs**, and guests were not shut down cleanly with the host. | all VMs `SHUTOFF` after the first test | autostart settings in `c3-reboot.md` |

### Problem 1 in detail: two defects in `amphora-netns.service`
At every boot this unit (written by the amphora agent from the template `amphora-netns.systemd.j2` that ships in the image, Octavia 16.1.1) moves the VIP NIC into the network namespace `amphora-haproxy` and renames it `eth1`. It finds the NIC by its MAC (saved in `/var/lib/octavia/plugged_interfaces`). Two things went wrong on a cold start:
1. **Line pairing.** The command was `ip link | awk '{getline n; print $0,n}' | ...`, which pairs each line of `ip link` with the next one. That only works when every interface prints exactly two lines. The slot-named NICs of a cold start (`ens3`, `ens4`) print a third `altname enp0sN` line, the pairing slips and the VIP NIC's MAC becomes garbage (`fa16:3e:..`), so it is never matched. Checked on `c3`'s own interfaces: the old command returns garbage for almost every interface; `ip -o link` (one line per interface) returns exactly the right MAC and name for all of them.
2. **A race with udev.** The unit starts in the same second the kernel renames the NICs (`ens4: renamed from eth1`). Fixing only the pairing was **not enough** (the test failed again; the amphora's own log said `Error on action 'up' for interface eth1: list index out of range`, i.e. no `eth1` in the namespace). Adding `udevadm settle` first fixed it, and the kernel then logs `eth1: renamed from ens4`.
A hard reboot happened to work because the hot-plugged NIC kept its old name (`ens7`) and the unit ran a few seconds after the rename.

## What is installed now
| Where | What |
|---|---|
| Glance image **`Amphora-netns-fix-v2-20261020`** (`3f82fe7b-bcaa-413c-b680-6ec9d06a1b4d`), owner = Octavia's project `9197db57…`, the **only** image with the tag `Amphora` | the original image with the template patched: `udevadm settle --timeout=30` as the first step, `ip -o link` instead of the line pairing, and a diagnostic (`/var/log/amphora-netns-debug.log` inside the amphora, overwritten each boot: the `date`, the `ip -o link` output and the saved MAC list the matching step saw). All three amphorae were rebuilt from it |
| Older images, kept as untagged backups | `90ce7754-0866-40f7-826d-396b611e6a3f` (original, 2026-10-02) and `c537e966-d3f9-498f-a33c-42d246e3ef88` (first patch, pairing only: **not sufficient**). Working copies and the pre-patch template are in `/root/amphora-fix/` on `c3` |
| `/etc/octavia/octavia.conf`, `[health_manager]` | `heartbeat_timeout = 300` (an amphora must be silent for **5 minutes** before it is failed over; it was 900 until 2026-10-20, lowered after reboots were fixed and measured, see below)  and `failover_threshold = 2` (a second guard). Backups `octavia.conf.bak-20261020` and `.bak2-<time>`. Restart **both** `octavia-worker` and `octavia-health-manager` after any change |
| `scripts/ovn-vip-binding-reconciler.py`, installed on `c3` as `/usr/local/sbin/ovn-vip-binding-reconciler` by `scripts/install-ovn-vip-reconciler.sh`; systemd `ovn-vip-binding.timer` (every 30 s, 90 s after boot) | for each VIP it reads the candidate amphora MACs from OVN's northbound DB (an IP a port may use besides its own fixed IPs, i.e. the `octavia-lb-vrrp-*` ports' allowed address pairs), probes the VIP (TCP port 80 from `c3`, three tries) and, only if it does not answer, sets the router's `MAC_Binding` to each candidate in turn and keeps the one that works; if none does it restores the original. It needs no OpenStack credentials, does nothing if `c3` has no route to `10.0.1.0/24`, and logs to `journalctl -u ovn-vip-binding.service` |
| autostart settings | `resume_guests_state_on_host_boot`, `libvirt-guests`, the `nova-compute` ordering drop-in: see `c3-reboot.md` |

## Proof (all on the live system, 2026-10-20)
| Test | Result |
|---|---|
| Clean stop and start of an amphora, **original image** | VIP lost (`networks=[]`, VIP down) |
| Same, **first patch** (pairing only) | VIP lost again (this is how the race was found) |
| Same, first patch **plus a udev wait added on the amphora's disk** | VIP restored, `networks=['eth1']`, door 200 |
| Same, **final image**, Argo's amphora, 3 rounds in a row | VIP back every time (agent up after about 33 s) |
| Final image, each of finance's two amphorae stopped and started while probing the door every second | both came back with `eth1`; **146 requests, 1 failed** (about a second while keepalived moved the VIP to the other amphora) |
| Deliberately wrong router entries (Argo's VIP set to a bogus MAC; finance's set to the other amphora) | healed by the watcher in **32 s** and **24 s** |
| **Plain host reboot with all 17 VMs running (before `dbw1` was added; 18 now), no manual step** (first try of the final design) | 17 of 17 guests running about 2 minutes after `c3` answered ssh; both doors 200 about 3 minutes after. But one amphora was flagged `ERROR` by the health manager (it booted a little after the others, so only one was stale and the threshold of 2 did not protect it) |
| Same, after adding `heartbeat_timeout = 900` | **0 failovers, the same three amphora IDs, all `ALLOCATED`, both load balancers `ACTIVE`/`ONLINE`, both doors 200**; `c3` back in 172 s; the watcher corrected the finance VIP within 30 s (the pair had re-elected a master on boot) |

## Check it at any time
```bash
ssh c3 'openstack loadbalancer list; openstack loadbalancer amphora list'          # ACTIVE/ONLINE; every amphora ALLOCATED (not ERROR, not FAILOVER_STOPPED)
ssh c3 'openstack image list --tag Amphora'                                        # exactly one: Amphora-netns-fix-v2-20261020
ssh c3 'systemctl is-active ovn-vip-binding.timer; journalctl -u ovn-vip-binding.service --since -1h --no-pager | grep -E "trying|answers again|no candidate"'
# does an amphora hold its VIP network? (look at "networks": it must not be empty)
ssh c3 'curl -s --cert /etc/octavia/certs/private/client.cert-and-key.pem --cacert /etc/octavia/certs/server_ca-chain.cert.pem -k https://<amphora lb_network_ip>:9443/1.0/details'
```
Expected after any host reboot: the watcher may log "trying ... answers again" once for the finance VIP in the first minutes (normal: the keepalived pair re-elected its master), and "no candidate worked ... will retry" while the amphorae are still booting.

## Rebuilding or upgrading the amphora image
The patch lives **inside the image**, so it is lost if the image is rebuilt or replaced by a newer Octavia amphora image. Before doing that, check whether the new Octavia release already fixes `amphora-netns` (look at the template `.../octavia/amphorae/backends/agent/api_server/templates/amphora-netns.systemd.j2` for `getline` and for a udev wait). If not, repeat the patch on the new image:
```bash
cd /root/amphora-fix && export LIBGUESTFS_BACKEND=direct
cp /var/lib/glance/images/<new image id> new.qcow2 && mkdir -p mnt && guestmount --format=qcow2 -a new.qcow2 -i mnt
T=mnt/opt/amphora-agent-venv/lib/python3.*/site-packages/octavia/amphorae/backends/agent/api_server/templates/amphora-netns.systemd.j2
# 1. before the line "# Re-add the namespace" insert:   ExecStart=-/usr/bin/udevadm settle --timeout=30
# 2. replace   /sbin/ip link | awk \'{getline n; print $0,n}\' |   with   /sbin/ip -o link |
#    (keep the rest of that ExecStart line exactly as it is; optionally add the diagnostic ExecStart shown in the current image)
guestunmount mnt && qemu-img check new.qcow2
openstack image create --file new.qcow2 --disk-format qcow2 --container-format bare --private --project 9197db575d8f4822801e6513e3f9c340 --tag Amphora "<name>"
openstack image unset --tag Amphora <old image id>          # Octavia takes the newest tagged image; keep only one tag
openstack loadbalancer failover argo-lb; openstack loadbalancer failover finance-lb      # rebuild onto it, one at a time (retry on 409)
```
Then **prove it**: `openstack server stop` then `start` of each amphora must leave `networks` non-empty and the VIP answering. The image must be owned by Octavia's project (the amphora servers live in `9197db57…`); an image owned by the admin project is invisible to Octavia.

## Limits and things to know
- **Automatic repair of a really dead amphora takes 5 minutes** (`heartbeat_timeout = 300`; 15 minutes before 2026-10-20). Both load balancers are ACTIVE_STANDBY, so the other amphora serves meanwhile (proven for `argo-lb`: 100 of 100 requests 200 with the master powered off). You can repair at once with `openstack loadbalancer failover <lb>` (retry on a 409).
- **Why 300 is safe for a host reboot now:** a reboot used to take 5 to 8 minutes and needed 900. With the shutdown/boot fixes (`c3-reboot.md`, tests 7 and later) a plain `systemctl reboot` takes about 2 minutes to answer ssh and the amphorae answer about a minute after that; and `failover_threshold = 2` stops the health manager from failing over when two or more amphorae are silent at once (as at a reboot, 4 of 4). Measured 2026-10-20 (reboot 20:39:34, 4 amphorae): **0 failovers, the same four amphora IDs, all `ALLOCATED`, both load balancers `ACTIVE`/`ONLINE`, both front doors 200 about 2.5 minutes after `c3` answered ssh.** Backup of the previous file: `/root/octavia.conf.bak-20261020-heartbeat` on `c3`. Do not go much lower than 300: a slow boot (an amphora waiting for udev, the earlier failure) must stay inside the margin.
- **Rebuilding two amphorae at once is still flaky.** `openstack loadbalancer failover finance-lb` fails about half the time (Nova logs "Got no allocation candidates from the Placement API" for the second VM, although Placement shows room; cause not found) and succeeds on a retry within a few minutes. Retry, and make sure about 4 GB of allocatable memory is free first (`ARCHITECTURE.md`, Capacity). A rebuild of the single Argo amphora has always worked.
- The watcher assumes the load balancers listen on **port 80** and that `c3` can reach the private network (`c3-host-route.md`). A new load balancer on another port needs the constant `PORT` in the script changed (or a per-VIP port).
- When both amphorae of a load balancer are down the watcher can do nothing (it restores the original entry and retries every 30 s); fix the amphorae first.
- A rebuild creates new amphora VMs with **new MACs**; the watcher is what makes the router follow them. If a front door is down while the load balancer says `ACTIVE`/`ONLINE`, check `journalctl -u ovn-vip-binding.service`, and run it once by hand: `ssh c3 /usr/local/sbin/ovn-vip-binding-reconciler`.
- Making `argo-lb` active/standby (flavor `ha`) would give it a second amphora; not done (memory is tight and the watcher already covers its failover case).

## How it was diagnosed (reusable)
- The agent API tells what an amphora thinks: `GET /1.0/details` shows `networks`, `haproxy_count`, topology.
- An amphora's disk can be read without stopping it: `LIBGUESTFS_BACKEND=direct virt-cat --format=qcow2 -a /var/lib/nova/instances/<server id>/disk /var/log/messages` (the `--format` avoids a lock error). `/var/log/messages` in the amphora holds the real errors (`amphora-interface`, sysctl, kernel NIC renames), and the console log (`openstack console log show <server id>`) shows the boot order.
- A disk edit is safe while the VM is **stopped**: `guestmount --format=qcow2 -a <disk> -i <dir>` (the flag must come before `-a`). That is how the udev wait was tried on one amphora before it was baked into the image.
- The OVN side: `ovn-nbctl list Logical_Router` (options), `ovn-sbctl find MAC_Binding ip=<vip>`, and `ovn-nbctl list Logical_Switch_Port` (the `port_security` of the vrrp ports lists the VIP).
