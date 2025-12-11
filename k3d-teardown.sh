#!/bin/bash
set -euo pipefail

# 1. Check for Root privileges
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (sudo)." 
   exit 1
fi

echo "Stopping and Uninstalling K3s on Fedora..."

# 2. Run the official uninstaller
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    /usr/local/bin/k3s-uninstall.sh
else
    echo "WARNING: /usr/local/bin/k3s-uninstall.sh not found."
    echo "Attempting to kill k3s processes manually..."
    # Fallback if uninstaller is missing
    if [ -f /usr/local/bin/k3s-killall.sh ]; then
        /usr/local/bin/k3s-killall.sh
    fi
fi

echo "Removing Configuration..."
rm -rf /etc/rancher/k3s
rm -rf /root/.kube  # Remove root's kubeconfig if it exists

echo "Removing Data Directories (Images, DB, Volumes)..."
# This is the critical part missing from your original script
rm -rf /var/lib/rancher/k3s
rm -rf /var/lib/kubelet

echo "Removing CNI (Network) Configurations..."
rm -rf /etc/cni
rm -rf /opt/cni

echo "Cleanup Complete. K3s has been fully removed."
