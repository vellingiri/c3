# etcd restore rehearsal (do this on QA, never first on prod)

A backup is only proven once it has been restored. This rehearses the full path on the QA
single-node control plane (`c1.qa.rdulinux.com`) using a marker object, so no real data is at risk.
QA controllers built from the current cloud-init already run the `etcd-snapshot.timer`.

## 1. Create a marker and take a snapshot
```bash
# on c1.qa.rdulinux.com
kubectl create configmap restore-marker --from-literal=when=before-snapshot
sudo systemctl start etcd-snapshot.service
SNAP=$(ls -1t /var/backups/etcd/etcd-*.db | head -1); echo $SNAP
```

## 2. Change the cluster after the snapshot
```bash
kubectl delete configmap restore-marker          # the restore must bring this back
```

## 3. Get etcdutl on the host (matches the 3.5 line used by kubeadm 1.30)
```bash
curl -fsSL https://github.com/etcd-io/etcd/releases/download/v3.5.15/etcd-v3.5.15-linux-amd64.tar.gz \
  | sudo tar -xz -C /usr/local/bin --strip-components=1 etcd-v3.5.15-linux-amd64/etcdutl
etcdutl version
```

## 4. Stop etcd, restore, start etcd
```bash
sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak
until [ -z "$(sudo crictl ps --name '^etcd$' -q)" ]; do sleep 2; done      # etcd (and then the apiserver) stop

NAME=$(awk -F= '/--name=/{print $2}' /root/etcd.yaml.bak)
PEER=$(awk -F= '/--initial-advertise-peer-urls=/{print $2}' /root/etcd.yaml.bak)
sudo mv /var/lib/etcd /var/lib/etcd.old
sudo etcdutl snapshot restore "$SNAP" --name "$NAME" \
  --initial-cluster "$NAME=$PEER" --initial-advertise-peer-urls "$PEER" --data-dir /var/lib/etcd

sudo mv /root/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
```
Wait a minute for the API server to come back.

## 5. Verify
```bash
kubectl get nodes                                 # node is Ready again
kubectl get configmap restore-marker -o jsonpath='{.data.when}{"\n"}'   # prints: before-snapshot
```
The marker coming back proves the snapshot restores the cluster to the state it was taken in.

## Cleanup
```bash
kubectl delete configmap restore-marker
sudo rm -rf /var/lib/etcd.old
```

## For a real prod restore
Same steps on the replacement control plane after `kubeadm init` has NOT yet run (or on a rebuilt
node with its etcd data dir removed), using the newest file from `/nfsshare/etcd-backups/prod/`.
Snapshots contain the cluster's Secrets in plain form: keep them root-only (`0600`) and off public storage.
Expect to lose changes made after the last snapshot (timer: every 6 hours).
