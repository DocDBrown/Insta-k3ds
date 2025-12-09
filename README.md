# Insta-k3ds

- Fast Setup for K3d clusters with TLS enabled
- Longhorn and CloudNativePG installation not yet included
- Manage firewall settings where relevant

## 1. Add or remove initial HA host

```bash
./k3d-setup.sh
```
```bash
./k3d-teardown.sh
```

## 2. Add or remove MacOS nodes

```bash
./k3d-mac-worker.sh
```
```bash
./k3d-mac-teardown.sh
```

## 3. Add or remove workers later 

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://<MASTER_IP>:6443 K3S_TOKEN=my-super-secret-cluster-token sh -s - agent
```
```bash
/usr/local/bin/k3s-uninstall.sh
```

## 4. Add or remove HA nodes later 

```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=my-super-secret-cluster-token sh -s - server --server https://<ip>:<port>
```
```bash
/usr/local/bin/k3s-uninstall.sh
```






