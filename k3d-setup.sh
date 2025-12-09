#!/bin/bash
set -e

# --- CONFIGURATION ---
LAN_IP=<ip>
# Generate a strong token: openssl rand -base64 32
TOKEN="my-super-secret-cluster-token"

echo "=== 1. Configuring Secrets Encryption ==="
mkdir -p /etc/rancher/k3s

# Create an encryption configuration file
# This uses AES-CBC to encrypt secrets on the disk
cat <<EOF > /etc/rancher/k3s/secrets-encrypt.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: $(openssl rand -base64 32)
      - identity: {}
EOF

echo "=== 2. Installing K3s Master (Embedded Etcd + Encryption) ==="

# We add --secrets-encryption to the command
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" \
  K3S_TOKEN="$TOKEN" \
  sh -s - \
  --cluster-init \
  --tls-san $LAN_IP \
  --node-ip $LAN_IP \
  --node-external-ip $LAN_IP \
  --secrets-encryption

echo "=== K3D MASTER READY ==="
echo "Etcd is now running with mTLS (Network Security) and AES-CBC (Disk Security)."
