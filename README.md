# Insta-k3ds
Fast Setup for K3d clusters

## 1. Add or remove initial HA host

./k3d-setup.sh
./k3d-teardown.sh

## 2. Add or remove MacOS nodes

./k3d-mac-worker.sh
./k3d-mac-teardown.sh

## 3. Add workers later 

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://<MASTER_IP>:6443 K3S_TOKEN=my-super-secret-cluster-token sh -s - agent
```

## 4. Add HA nodes later 

```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=my-super-secret-cluster-token sh -s - server --server https://<ip>:<port>
```


