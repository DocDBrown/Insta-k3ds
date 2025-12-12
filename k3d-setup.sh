#!/usr/bin/env bash
#
# App Name: k3sh
# File: setup.sh
#
# Description:
#   Bootstrap a highly available K3s cluster with embedded etcd
#   on a single Linux host using Podman.
#
#   - 3x K3s server (control-plane) nodes (HA etcd).
#   - 3x K3s agent (worker) nodes.
#   - Waits for the first server to be ready before joining others.
#

set -euo pipefail
IFS=$'\n\t'

# --- Configuration ---
readonly CLUSTER_NAME="${CLUSTER_NAME:-k3s-ha}"
readonly K3S_IMAGE="${K3S_IMAGE:-docker.io/rancher/k3s:v1.32.10-k3s1}"
readonly PODMAN_NETWORK="${PODMAN_NETWORK:-k3s-ha-net}"
# Using 10.45.0.0/24 to avoid conflict with K3s default 10.42.0.0/16
readonly PODMAN_SUBNET="${PODMAN_SUBNET:-10.45.0.0/24}"
readonly DATA_DIR="${DATA_DIR:-./k3s-data}"
readonly KUBECONFIG_DIR="${KUBECONFIG_DIR:-./kubeconfig}"

# --- Helper Functions ---

log_info() { echo "[INFO] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; exit 1; }

check_dependencies() {
  for dep in podman awk sed head base64; do
    command -v "${dep}" >/dev/null 2>&1 || log_error "Missing command: ${dep}"
  done
}

detect_external_ip() {
  hostname -I 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i !~ /^127\./ && $i !~ /^169\.254\./) { print $i; exit; }
    }
  }'
}

setup_network() {
  if ! podman network inspect "${PODMAN_NETWORK}" >/dev/null 2>&1; then
    log_info "Creating network '${PODMAN_NETWORK}' (${PODMAN_SUBNET})..."
    podman network create --subnet "${PODMAN_SUBNET}" "${PODMAN_NETWORK}" >/dev/null
  else
    log_info "Network '${PODMAN_NETWORK}' already exists."
  fi
}

ensure_token() {
  local token_file="${DATA_DIR}/cluster-token"
  if [[ ! -f "${token_file}" ]]; then
    mkdir -p "$(dirname "${token_file}")"
    head -c 16 /dev/urandom | base64 | tr -d '[:space:]' >"${token_file}"
  fi
  cat "${token_file}"
}

wait_for_node_ready() {
  local container_name="$1"
  log_info "Waiting for ${container_name} to be Ready..."
  local timeout=120
  local start_time=$(date +%s)

  while true; do
    # We use 'kubectl get nodes' inside the container to check status
    if podman exec "${container_name}" kubectl get nodes 2>/dev/null | grep -q "Ready"; then
      log_info "${container_name} is Ready!"
      break
    fi

    if (($(date +%s) - start_time > timeout)); then
      log_error "Timed out waiting for ${container_name}."
    fi
    sleep 5
  done
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
    log_info "Container '${container_name}' exists. Ensuring it is running..."
    podman start "${container_name}" >/dev/null 2>&1 || true
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
    run -d
    --name "${container_name}"
    --hostname "${container_name}"
    --privileged
    --network "${PODMAN_NETWORK}:ip=${ip_addr}"
    -v "${node_data_dir}:/var/lib/rancher/k3s"
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw
  )

  if [[ "${node_num}" -eq 1 ]]; then
    podman_args+=(-p 6443:6443)
  fi

  podman "${podman_args[@]}" "${K3S_IMAGE}" "${k3s_args[@]}" >/dev/null
}

start_agent_node() {
  local node_num="$1"
  local ip_addr="$2"
  local token="$3"
  local server_url="$4"
  local container_name="k3s-agent-${node_num}"

  if podman container exists "${container_name}"; then
    podman start "${container_name}" >/dev/null 2>&1 || true
    return
  fi

  log_info "Starting agent node '${container_name}'..."

  podman run -d \
    --name "${container_name}" \
    --hostname "${container_name}" \
    --privileged \
    --network "${PODMAN_NETWORK}:ip=${ip_addr}" \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    "${K3S_IMAGE}" agent \
    --server "${server_url}" \
    --token="${token}" \
    --node-ip="${ip_addr}" >/dev/null
}

retrieve_kubeconfig() {
  local external_ip="$1"
  local kubeconfig_path="${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml"
  
  log_info "Copying kubeconfig to host..."
  mkdir -p "$(dirname "${kubeconfig_path}")"
  podman cp "k3s-server-1:/etc/rancher/k3s/k3s.yaml" "${kubeconfig_path}"

  log_info "Configuring kubeconfig..."
  # Update IP
  sed -i "s,server: https://127.0.0.1:6443,server: https://${external_ip}:6443," "${kubeconfig_path}"

  # Set ownership to the user who ran sudo
  local owner_user
  owner_user="$(logname 2>/dev/null || echo "${SUDO_USER:-${USER}}")"
  local owner_group
  owner_group="$(id -gn "${owner_user}" 2>/dev/null || echo "${owner_user}")"

  chown "${owner_user}:${owner_group}" "${kubeconfig_path}"
  chmod 600 "${kubeconfig_path}"
}

main() {
  check_dependencies
  local external_ip
  external_ip="${EXTERNAL_IP:-$(detect_external_ip)}"
  log_info "Using External IP: ${external_ip}"

  mkdir -p "${DATA_DIR}" "${KUBECONFIG_DIR}"
  setup_network
  local token
  token="$(ensure_token)"

  # IPs in 10.45.0.0/24
  local s1="10.45.0.11" s2="10.45.0.12" s3="10.45.0.13"
  local a1="10.45.0.21" a2="10.45.0.22" a3="10.45.0.23"
  local url="https://${s1}:6443"

  # 1. Start First Server
  start_server_node 1 "${s1}" "${token}" "${external_ip}" "init"
  
  # 2. CRITICAL: Wait for Server 1 to be ready before joining others
  wait_for_node_ready "k3s-server-1"

  # 3. Start Remaining Servers
  start_server_node 2 "${s2}" "${token}" "${external_ip}" "join" "${url}"
  start_server_node 3 "${s3}" "${token}" "${external_ip}" "join" "${url}"

  # 4. Start Agents
  start_agent_node 1 "${a1}" "${token}" "${url}"
  start_agent_node 2 "${a2}" "${token}" "${url}"
  start_agent_node 3 "${a3}" "${token}" "${url}"

  # 5. Finalize
  retrieve_kubeconfig "${external_ip}"

  log_info "Cluster Setup Complete."
  log_info "Run: export KUBECONFIG=\"$(realpath "${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml")\""
  log_info "Then: kubectl get nodes"
}

main "$@"
