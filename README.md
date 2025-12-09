# Insta-k3ds
Fast Setup for K3d clusters

## to add initial HA host

./k3d-setup.sh

## to add MacOS workers

./k3d-mac-worker.sh

## to add workers later 

curl -sfL https://get.k3s.io | K3S_URL=https://<ip>:<port> K3S_TOKEN=my-super-secret-cluster-token sh -s - agent

## to add HA nodes later 

curl -sfL https://get.k3s.io | K3S_TOKEN=my-super-secret-cluster-token sh -s - server --server https://<ip>:<port>


