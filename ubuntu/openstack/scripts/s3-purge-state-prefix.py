#!/usr/bin/env python3
# Remove the OLD top-level key prefixes (infra/, nodes/, v2/) from the Terraform-state bucket in RustFS, through the S3 API (never rm inside /opt/rustfs/data).
# Run ON s3:  python3 s3-purge-state-prefix.py <prefix>/            (dry run: lists what is there and the live state's versions)
#             python3 s3-purge-state-prefix.py <prefix>/ apply      (saves the state versions to /backup/legacy-state-export/<prefix>-<time>.tgz, then deletes
#                                                                    every version and delete marker under the prefix, then checks openstack/infra is unchanged)
# Refuses any prefix that starts with "openstack" (those are the live states). Used on 2026-11-07 for infra/, nodes/ and v2/ (all three gone). docs/s3-state-store.md.
import re, subprocess, sys, os, json, hashlib, tarfile, time
PREFIX = sys.argv[1]            # e.g. "infra/"  (the top-level legacy key prefix, never "openstack/...")
APPLY = len(sys.argv) > 2 and sys.argv[2] == "apply"
assert PREFIX.endswith("/") and not PREFIX.startswith("openstack"), PREFIX
env = subprocess.check_output(["docker","inspect","rustfs","--format","{{range .Config.Env}}{{println .}}{{end}}"], text=True)
AK = re.search(r"^RUSTFS_ACCESS_KEY=(.*)$", env, re.M).group(1); SK = re.search(r"^RUSTFS_SECRET_KEY=(.*)$", env, re.M).group(1)
BASE = "http://s3-prod.rdulinux.com:9000/terraform-state"
def s3(method, path, out=None):
    cmd = ["curl","-fsS","--aws-sigv4","aws:amz:us-east-1:s3","--user",f"{AK}:{SK}","-X",method,BASE+path]
    if out: cmd += ["-o", out]
    return subprocess.run(cmd, capture_output=True, text=True)
def versions(prefix):
    x = s3("GET", f"?versions&prefix={prefix}").stdout
    out = []
    for tag in ("Version","DeleteMarker"):
        for m in re.finditer(rf"<{tag}>(.*?)</{tag}>", x, re.S):
            b = m.group(1)
            out.append((tag, re.search(r"<Key>(.*?)</Key>", b).group(1), re.search(r"<VersionId>(.*?)</VersionId>", b).group(1),
                        (re.search(r"<Size>(.*?)</Size>", b) or [0,"0"])[1], re.search(r"<LastModified>(.*?)</LastModified>", b).group(1)[:19]))
    return out
live_before = [v for v in versions("openstack/infra/") if v[0]=="Version" and v[1]=="openstack/infra/terraform.tfstate"]
print("live openstack/infra/terraform.tfstate versions before:", len(live_before), "newest:", max(v[4] for v in live_before))
vs = versions(PREFIX)
print(f"under {PREFIX}: {len(vs)} entries ({sum(1 for v in vs if v[0]=='Version')} versions, {sum(1 for v in vs if v[0]=='DeleteMarker')} delete markers)")
for k in sorted({v[1] for v in vs}): print("  key:", k)
assert all(v[1].startswith(PREFIX) for v in vs)
if not APPLY: print("(dry run: nothing deleted)"); sys.exit(0)
# 1. safety copy of every state version (the lock files are empty bookkeeping)
stamp = time.strftime("%Y%m%d-%H%M%S"); d = f"/backup/legacy-state-export/{PREFIX.strip('/')}-{stamp}"; os.makedirs(d, mode=0o700, exist_ok=True)
saved = 0
for t,k,vid,size,lm in vs:
    if t=="Version" and not k.endswith(".tflock"):
        r = s3("GET", f"/{k}?versionId={vid}", out=f"{d}/{k.replace('/','_')}.{lm.replace(':','')}.{vid[:8]}")
        saved += (r.returncode == 0)
tgz = d + ".tgz"
with tarfile.open(tgz, "w:gz") as t: t.add(d, arcname=os.path.basename(d))
os.chmod(tgz, 0o600)
import shutil; shutil.rmtree(d)
print(f"safety copy: {saved} state versions -> {tgz} ({os.path.getsize(tgz)} bytes)")
# 2. delete every version and delete marker under the prefix
bad = 0
for t,k,vid,size,lm in vs:
    r = s3("DELETE", f"/{k}?versionId={vid}")
    bad += (r.returncode != 0)
print("deleted:", len(vs)-bad, "failed:", bad)
# 3. verify
left = versions(PREFIX); print(f"left under {PREFIX}:", len(left))
live_after = [v for v in versions("openstack/infra/") if v[0]=="Version" and v[1]=="openstack/infra/terraform.tfstate"]
print("live openstack/infra/terraform.tfstate versions after:", len(live_after), "newest:", max(v[4] for v in live_after), "(unchanged)" if len(live_after)==len(live_before) else "(CHANGED!)")
cur = s3("GET", "/openstack/infra/terraform.tfstate", out="/dev/null"); print("live state readable:", cur.returncode == 0)
