# Source this from ~/.bashrc or ~/.bash_profile:
#   source /opt/c3/ubuntu/openstack/scripts/openstack-shortcuts.sh
#
# Plain `openstack server list` prints the normal table (same columns, same order, same
# style) with one extra column, Env (prod/qa), read from the `env` metadata that Terraform
# sets on every VM. VMs without it show "-".
# Any call with extra arguments (-f json, --tags qa, ...) is passed through unchanged,
# so scripts and one-off queries behave exactly as before.
openstack() {
  if [ "$#" -eq 2 ] && [ "$1" = "server" ] && [ "$2" = "list" ]; then
    command openstack server list --long -f json | python3 -c '
import json, re, sys
rows = json.load(sys.stdin)

def env(r):
    p = r.get("Properties") or {}
    if isinstance(p, str):
        m = re.search(r"env=\x27?([\w-]+)", p)
        return m.group(1) if m else "-"
    return p.get("env", "-")

def networks(r):
    n = r.get("Networks", "")
    if isinstance(n, dict):
        return "; ".join("%s=%s" % (k, ", ".join(v)) for k, v in n.items())
    return str(n)

head = ["ID", "Name", "Status", "Networks", "Image", "Flavor", "Env"]
body = [[r["ID"], r["Name"], r["Status"], networks(r),
         str(r.get("Image Name", r.get("Image", ""))), str(r.get("Flavor", "")), env(r)]
        for r in rows]
w = [max(len(x[i]) for x in [head] + body) for i in range(len(head))]
bar = "+" + "+".join("-" * (n + 2) for n in w) + "+"
line = lambda cells: "| " + " | ".join(c.ljust(w[i]) for i, c in enumerate(cells)) + " |"
print(bar); print(line(head)); print(bar)
for b in body: print(line(b))
print(bar)
'
  else
    command openstack "$@"
  fi
}
