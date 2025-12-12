# Insta-k3ds

- Fast Setup for K3d clusters with TLS enabled
- Setup multiple HA etcd nodes for a multi-node cluster starting with three master/ server nodes and 3 worker nodes on one computer with a shell script.
- To achieve etcd HA K3s are setup in server mode on multiple nodes, each with its own etcd instance that is part of a cluster.
- A script that automates the setup of three K3s HA server nodes (control plane nodes) with HA etcd as the data store and secrets encryption enabled.
- It uses mTLS for securing the etcd communication and AES-CBC encryption for Kubernetes secrets.
- Sets up AES-CBC encryption for Kubernetes secrets, ensuring that secrets stored in etcd are encrypted at rest.
- It configures the first K3s node to act as the first control plane node.
- Configures the node's internal and external IPs and ensures proper certificates are generated for secure access.

## 1. Add or remove initial HA host

```bash
sudo bash setup.sh
export KUBECONFIG="./kubeconfig/k3s-server-1-kubeconfig.yaml"
kubectl get nodes
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

## 3. Add or remove workers later (Linux environment)

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://<MASTER_IP>:6443 K3S_TOKEN=my-super-secret-cluster-token sh -s - agent
```
```bash
/usr/local/bin/k3s-uninstall.sh
```

## 4. Add or remove HA nodes later (Linux environment) 

```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=my-super-secret-cluster-token sh -s - server --server https://<ip>:<port>
```
```bash
/usr/local/bin/k3s-uninstall.sh
```






