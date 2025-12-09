# Insta-k3ds
Fast Setup for K3d clusters

## 1. To add initial HA host

./k3d-setup.sh

## 2. To add MacOS workers

./k3d-mac-worker.sh

## 3. To add workers later 

curl -sfL https://get.k3s.io | K3S_URL=https://<ip>:<port> K3S_TOKEN=my-super-secret-cluster-token sh -s - agent

## 4. To add HA nodes later 

curl -sfL https://get.k3s.io | K3S_TOKEN=my-super-secret-cluster-token sh -s - server --server https://<ip>:<port>


