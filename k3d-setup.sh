#!/usr/bin/env bash
#
# App Name: k3sh
# File: setup_k3s_ha_podman.sh
#
# Description:
# Shell script that bootstraps a highly available K3s cluster with embedded etcd
# on a single Linux host using Podman. The script creates three K3s server
# (control-plane) nodes and three K3s worker nodes as privileged Podman containers
# attached to a dedicated Podman network with static IP addresses.
#
# Usage:
#   ./setup_k3s_ha_podman.sh
#
# Environment Variables (optional):
#   CLUSTER_NAME   – logical name for the cluster (default: k3s-ha).
#   K3S_IMAGE      – container image for K3s server/agent (default: docker.io/rancher/k3s:v1.32.10-k3s1).
#   PODMAN_NETWORK – Podman network name to attach nodes to (default: k3s-ha-net).
#   PODMAN_SUBNET  – CIDR subnet used by the Podman network (default: 10.42.0.0/24).
#   DATA_DIR       – host directory to persist K3s data per node (default: ./k3s-data).
#   KUBECONFIG_DIR – host directory to write kubeconfig files into (default: ./kubeconfig).
#   EXTERNAL_IP    – external IP to use as TLS SAN for the API server (default: primary host IP).
#

set -euo pipefail
IFS=$'\n\t'

# --- Configuration with Defaults ---
readonly CLUSTER_NAME="${CLUSTER_NAME:-k3s-ha}"
readonly K3S_IMAGE="${K3S_IMAGE:-docker.io/rancher/k3s:v1.32.10-k3s1}"
readonly PODMAN_NETWORK="${PODMAN_NETWORK:-k3s-ha-net}"
readonly PODMAN_SUBNET="${PODMAN_SUBNET:-10.42.0.0/24}"
readonly DATA_DIR="${DATA_DIR:-./k3s-data}"
readonly KUBECONFIG_DIR="${KUBECONFIG_DIR:-./kubeconfig}"

# --- Helper Functions ---

log_info() {
	echo "[INFO] $*" >&2
}

log_error() {
	echo "[ERROR] $*" >&2
	exit 1
}

check_dependencies() {
	local dep
	for dep in podman awk sed head base64; do
		command -v "${dep}" >/dev/null 2>&1 || log_error "Required command '${dep}' is not installed or not in PATH."
	done
}

usage() {
	cat <<EOF
Usage: $0 [-h|--help]

Bootstraps a highly available K3s cluster on a single host using Podman.

This script is configured via environment variables. See the script header for details.
EOF
}

# --- Main Logic Functions ---

setup_network() {
	if ! podman network inspect "${PODMAN_NETWORK}" >/dev/null 2>&1; then
		log_info "Creating Podman network '${PODMAN_NETWORK}' with subnet '${PODMAN_SUBNET}'..."
		podman network create --subnet "${PODMAN_SUBNET}" "${PODMAN_NETWORK}" >/dev/null
	else
		log_info "Podman network '${PODMAN_NETWORK}' already exists."
	fi
}

ensure_token() {
	local token_file="${DATA_DIR}/cluster-token"
	if [[ ! -f "${token_file}" ]]; then
		log_info "Generating new cluster token..."
		mkdir -p "$(dirname "${token_file}")"
		head -c 16 /dev/urandom | base64 | tr -d '[:space:]' >"${token_file}"
	fi
	cat "${token_file}"
}

start_server_node() {
	local node_num="$1"
	local ip_addr="$2"
	local token="$3"
	local external_ip="$4"
	local mode="$5" # 'init' or 'join'
	local server_url="${6:-}"

	local container_name="k3s-server-${node_num}"
	local node_data_dir="${DATA_DIR}/${container_name}"
	mkdir -p "${node_data_dir}"

	if podman container exists "${container_name}"; then
		log_info "Container '${container_name}' already exists, skipping creation."
		return
	fi

	log_info "Starting server node '${container_name}'..."

	local k3s_args=(
		server
		--token="${token}"
		--tls-san="${external_ip}"
		--node-ip="${ip_addr}"
		--node-external-ip="${external_ip}"
		--secrets-encryption
	)

	if [[ "${mode}" == "init" ]]; then
		k3s_args+=(--cluster-init)
	else
		k3s_args+=(--server "${server_url}")
	fi

	local podman_args=(
		run
		--detach
		--name "${container_name}"
		--hostname "${container_name}"
		--privileged
		--network "${PODMAN_NETWORK}:ip=${ip_addr}"
		-v "${node_data_dir}:/var/lib/rancher/k3s"
	)

	# Expose API server port only on the first server node
	if [[ "${node_num}" -eq 1 ]]; then
		podman_args+=(-p 6443:6443)
	fi

	podman "${podman_args[@]}" "${K3S_IMAGE}" "${k3s_args[@]}"
}

start_agent_node() {
	local node_num="$1"
	local ip_addr="$2"
	local token="$3"
	local server_url="$4"

	local container_name="k3s-agent-${node_num}"

	if podman container exists "${container_name}"; then
		log_info "Container '${container_name}' already exists, skipping creation."
		return
	fi

	log_info "Starting agent node '${container_name}'..."

	podman run \
		--detach \
		--name "${container_name}" \
		--hostname "${container_name}" \
		--privileged \
		--network "${PODMAN_NETWORK}:ip=${ip_addr}" \
		"${K3S_IMAGE}" agent \
		--server "${server_url}" \
		--token="${token}" \
		--node-ip="${ip_addr}"
}

retrieve_kubeconfig() {
	local external_ip="$1"
	local kubeconfig_path="${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml"
	local init_server_name="k3s-server-1"

	if [[ -f "${kubeconfig_path}" ]]; then
		log_info "Kubeconfig file '${kubeconfig_path}' already exists, skipping retrieval."
		return
	fi

	log_info "Waiting for kubeconfig to be available on '${init_server_name}'..."
	local timeout=180
	local start_time
	start_time=$(date +%s)

	while ! podman exec "${init_server_name}" test -f /etc/rancher/k3s/k3s.yaml; do
		if (($(date +%s) - start_time > timeout)); then
			log_error "Timed out waiting for kubeconfig file on '${init_server_name}'."
		fi
		sleep 5
	done

	log_info "Copying kubeconfig from '${init_server_name}' to host..."
	mkdir -p "$(dirname "${kubeconfig_path}")" # Ensure directory exists before cp
	podman cp "${init_server_name}:/etc/rancher/k3s/k3s.yaml" "${kubeconfig_path}"

	log_info "Updating kubeconfig server address to '${external_ip}'..."
	sed -i "s/127.0.0.1/${external_ip}/g" "${kubeconfig_path}"
	sed -i "s/default/${CLUSTER_NAME}/g" "${kubeconfig_path}"
	chmod 600 "${kubeconfig_path}"
}

main() {
	if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
		usage
		exit 0
	fi

	check_dependencies

	local external_ip
	external_ip="${EXTERNAL_IP:-$(hostname -I | awk '{print $1}')}"
	if [[ -z "${external_ip}" ]]; then
		log_error "Could not determine host's primary IP address. Please set EXTERNAL_IP manually."
	fi
	log_info "Using external IP: ${external_ip}"

	mkdir -p "${DATA_DIR}" "${KUBECONFIG_DIR}"

	setup_network

	local cluster_token
	cluster_token=$(ensure_token)

	local server1_ip="10.42.0.11"
	local server2_ip="10.42.0.12"
	local server3_ip="10.42.0.13"
	local agent1_ip="10.42.0.21"
	local agent2_ip="10.42.0.22"
	local agent3_ip="10.42.0.23"

	local server_url="https://${server1_ip}:6443"

	start_server_node 1 "${server1_ip}" "${cluster_token}" "${external_ip}" "init"
	start_server_node 2 "${server2_ip}" "${cluster_token}" "${external_ip}" "join" "${server_url}"
	start_server_node 3 "${server3_ip}" "${cluster_token}" "${external_ip}" "join" "${server_url}"

	start_agent_node 1 "${agent1_ip}" "${cluster_token}" "${server_url}"
	start_agent_node 2 "${agent2_ip}" "${cluster_token}" "${server_url}"
	start_agent_node 3 "${agent3_ip}" "${cluster_token}" "${server_url}"

	retrieve_kubeconfig "${external_ip}"

	log_info "\nK3s HA cluster setup complete!"
	log_info "To access your cluster, run the following commands:"
	log_info "  export KUBECONFIG=\"$(realpath "${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml")\""
	log_info "  kubectl get nodes"
}

main "$@"
