#!/bin/bash
echo "Stopping and Uninstalling K3s on Fedora..."
/usr/local/bin/k3s-uninstall.sh

echo "Removing Encryption Config..."
rm -rf /etc/rancher/k3s

echo "Cleanup Complete."
