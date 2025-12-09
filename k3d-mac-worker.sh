#!/bin/bash

MASTER_IP=<ip>
TOKEN="my-super-secret-cluster-token"
MAC_IP=<ip>

# Init Podman (Ensure enough RAM)
podman machine init --cpus 4 --memory 6144 2>/dev/null || true
podman machine start 2>/dev/null || true

echo "=== Joining Cluster as Secondary ==="

# Run K3s SERVER in Podman
podman run -d --name k3s-server \
  --privileged \
  --restart always \
  --network host \
  -v k3s-server-data:/var/lib/rancher/k3s \
  -e K3S_TOKEN=$TOKEN \
  -e K3S_URL="https://$MASTER_IP:<port>" \
  rancher/k3s:v1.30.4-k3s1 \
  k3s server \
  --tls-san $MAC_IP \
  --node-ip $MAC_IP \
  --node-external-ip $MAC_IP \
  --flannel-iface=eth0 
