#!/bin/bash
echo "Stopping K3s Container..."
podman rm -f k3s-server

echo "Removing Data Volume..."
podman volume rm k3s-server-data

echo "Cleanup Complete."
