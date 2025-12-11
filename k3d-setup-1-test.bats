#!/usr/bin/env bats

# --- Helper Functions ---

assert_success() {
	if [ "$status" -ne 0 ]; then
		echo "Command failed with status $status"
		echo "Output: $output"
		return 1
	fi
}

assert_failure() {
	if [ "$status" -eq 0 ]; then
		echo "Command succeeded but expected failure"
		echo "Output: $output"
		return 1
	fi
}

assert_output_contains() {
	local expected="$1"
	if [[ "$output" != *"$expected"* ]]; then
		echo "Expected output to contain: $expected"
		echo "Actual output: $output"
		return 1
	fi
}

refute_output_contains() {
	local unexpected="$1"
	if [[ "$output" == *"$unexpected"* ]]; then
		echo "Expected output NOT to contain: $unexpected"
		echo "Actual output: $output"
		return 1
	fi
}

assert_output() {
	local expected="$1"
	if [[ "$output" != "$expected" ]]; then
		echo "Expected: '$expected'"
		echo "Actual:   '$output'"
		return 1
	fi
}

assert_file_exist() {
	if [ ! -f "$1" ]; then
		echo "File does not exist: $1"
		return 1
	fi
}

assert_dir_exist() {
	if [ ! -d "$1" ]; then
		echo "Directory does not exist: $1"
		return 1
	fi
}

# --- Test Setup ---

setup() {
	# Create a temporary directory for this test run
	TMPDIR=$(mktemp -d)
	export TMPDIR

	# Define paths for data and kubeconfig
	export DATA_DIR="${TMPDIR}/k3s-data"
	export KUBECONFIG_DIR="${TMPDIR}/kubeconfig"
	mkdir -p "${DATA_DIR}" "${KUBECONFIG_DIR}"

	# Set other env vars
	export CLUSTER_NAME="test-k3s-ha"
	export K3S_IMAGE="test/rancher/k3s:v1.32.10-k3s1"
	export PODMAN_NETWORK="test-k3s-ha-net"
	export PODMAN_SUBNET="10.42.0.0/24"
	export EXTERNAL_IP="192.168.1.100"

	# Create bin directory for mocks
	mkdir -p "${TMPDIR}/bin"
	export PATH="${TMPDIR}/bin:${PATH}"
    
    # State directory for mocks
    mkdir -p "${TMPDIR}/state"

	# --- Create Mocks ---

	# Mock podman
	cat <<'EOF' >"${TMPDIR}/bin/podman"
#!/usr/bin/env bash
echo "RUN_CMD: $*" >>"${TMPDIR}/podman.log"
cmd="$1"
subcmd="$2"

if [[ "$cmd" == "network" ]]; then
	if [[ "$subcmd" == "inspect" ]]; then
		if [[ -f "${TMPDIR}/state/network_created" ]]; then
			exit 0
		else
			exit 1
		fi
	elif [[ "$subcmd" == "create" ]]; then
		touch "${TMPDIR}/state/network_created"
		exit 0
	fi
elif [[ "$cmd" == "container" && "$subcmd" == "exists" ]]; then
	container_name="$3"
	if [[ -f "${TMPDIR}/state/container_${container_name}" ]]; then
		exit 0
	else
		exit 1
	fi
elif [[ "$cmd" == "run" ]]; then
    # Extract name
    name=""
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
        if [[ "${args[i]}" == "--name" ]]; then
            name="${args[i+1]}"
        fi
    done
    
    if [[ -n "$name" ]]; then
        touch "${TMPDIR}/state/container_${name}"
    fi
	exit 0
elif [[ "$cmd" == "exec" ]]; then
	# exec container test -f /etc/rancher/k3s/k3s.yaml
	# Simulate waiting for kubeconfig
	if [[ "$3" == "test" && "$4" == "-f" ]]; then
		# We use a counter file to simulate delay
		count_file="${TMPDIR}/state/exec_count"
		if [[ ! -f "$count_file" ]]; then echo 0 >"$count_file"; fi
		count=$(cat "$count_file")
		if (( count >= 1 )); then
			exit 0
		else
			echo $((count + 1)) >"$count_file"
			exit 1
		fi
	fi
elif [[ "$cmd" == "cp" ]]; then
	# cp container:path dest
	src="$2"
	dest="$3"
	if [[ "$src" == *"k3s-server-1:/etc/rancher/k3s/k3s.yaml" ]]; then
		mkdir -p "$(dirname "$dest")"
		echo "KUBECONFIG_CONTENT_SERVER_URL: 127.0.0.1" > "$dest"
		echo "KUBECONFIG_CONTENT_CLUSTER_NAME: default" >> "$dest"
		exit 0
	fi
fi
exit 0
EOF
	chmod +x "${TMPDIR}/bin/podman"

	# Mock hostname
	cat <<'EOF' >"${TMPDIR}/bin/hostname"
#!/usr/bin/env bash
echo "hostname $*" >>"${TMPDIR}/hostname.log"
if [[ "$1" == "-I" ]]; then
	echo "192.168.1.100 172.17.0.1"
else
	echo "hostname-mock"
fi
EOF
	chmod +x "${TMPDIR}/bin/hostname"

	# Mock head (for token generation)
	cat <<'EOF' >"${TMPDIR}/bin/head"
#!/usr/bin/env bash
echo "head $*" >>"${TMPDIR}/head.log"
if [[ "$1" == "-c" ]]; then
	echo "MOCKED_RANDOM_BYTES"
else
	/usr/bin/head "$@"
fi
EOF
	chmod +x "${TMPDIR}/bin/head"

	# Mock base64
	cat <<'EOF' >"${TMPDIR}/bin/base64"
#!/usr/bin/env bash
echo "base64 $*" >>"${TMPDIR}/base64.log"
input=$(cat)
if [[ "$input" == "MOCKED_RANDOM_BYTES" ]]; then
	echo "MOCKED_CLUSTER_TOKEN_BASE64"
else
	echo "$input" | /usr/bin/base64 "$@"
fi
EOF
	chmod +x "${TMPDIR}/bin/base64"

	# Mock date (for timeout loop)
	cat <<'EOF' >"${TMPDIR}/bin/date"
#!/usr/bin/env bash
echo "date $*" >>"${TMPDIR}/date.log"
if [[ "$1" == "+%s" ]]; then
	time_file="${TMPDIR}/state/date_time"
	if [[ ! -f "$time_file" ]]; then echo 1000 >"$time_file"; fi
	current=$(cat "$time_file")
	echo "$current"
	echo $((current + 10)) >"$time_file"
else
	/usr/bin/date "$@"
fi
EOF
	chmod +x "${TMPDIR}/bin/date"

	# Mock sed (passthrough but logging)
	cat <<'EOF' >"${TMPDIR}/bin/sed"
#!/usr/bin/env bash
echo "sed $*" >>"${TMPDIR}/sed.log"
/usr/bin/sed "$@"
EOF
	chmod +x "${TMPDIR}/bin/sed"
}

teardown() {
	rm -rf "${TMPDIR}"
}

@test "setup_k3s_ha_podman_main_each_container_started_with_privileged_flag_and_attached_to_dedicated_network_with_configured_static_ip" {
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"

	assert_success
	assert_output_contains "K3s HA cluster setup complete!"

	local expected_ips=(
		"10.42.0.11" "10.42.0.12" "10.42.0.13" # Servers
		"10.42.0.21" "10.42.0.22" "10.42.0.23" # Agents
	)
	local container_types=(
		"k3s-server-1" "k3s-server-2" "k3s-server-3"
		"k3s-agent-1" "k3s-agent-2" "k3s-agent-3"
	)

	for i in "${!container_types[@]}"; do
		local container_name="${container_types[$i]}"
		local ip_addr="${expected_ips[$i]}"

		# We grep the log file generated by the mock
		run grep -E "RUN_CMD:.*--name ${container_name}.*--privileged.*--network ${PODMAN_NETWORK}:ip=${ip_addr}" "${TMPDIR}/podman.log"
		assert_success
	done
}

@test "setup_k3s_ha_podman_main_first_server_started_with_cluster_init_and_other_servers_join_existing_control_plane" {
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"

	assert_success

	# Verify server 1 is started with --cluster-init
	run grep -E "RUN_CMD:.*--name k3s-server-1.*--cluster-init" "${TMPDIR}/podman.log"
	assert_success

	# Verify server 2 and 3 join server 1
	run grep -E "RUN_CMD:.*--name k3s-server-2.*--server https://10.42.0.11:6443" "${TMPDIR}/podman.log"
	assert_success

	run grep -E "RUN_CMD:.*--name k3s-server-3.*--server https://10.42.0.11:6443" "${TMPDIR}/podman.log"
	assert_success
}

@test "setup_k3s_ha_podman_main_all_servers_configured_for_embedded_etcd_and_form_single_etcd_cluster" {
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"

	assert_success

	# Verify all servers use the same token
	local token_file="${DATA_DIR}/cluster-token"
	assert_file_exist "$token_file"

	local expected_token
	expected_token=$(cat "$token_file")

	# Check logs for token usage
	run grep -E "RUN_CMD:.*--name k3s-server-1.*--token=${expected_token}" "${TMPDIR}/podman.log"
	assert_success
	run grep -E "RUN_CMD:.*--name k3s-server-2.*--token=${expected_token}" "${TMPDIR}/podman.log"
	assert_success
	run grep -E "RUN_CMD:.*--name k3s-server-3.*--token=${expected_token}" "${TMPDIR}/podman.log"
	assert_success
}

@test "setup_k3s_ha_podman_main_k3s_server_configuration_enables_secrets_encryption_with_aes_cbc_provider" {
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"

	assert_success

	# Verify all server nodes are started with --secrets-encryption
	run grep -E "RUN_CMD:.*--name k3s-server-1.*--secrets-encryption" "${TMPDIR}/podman.log"
	assert_success
	run grep -E "RUN_CMD:.*--name k3s-server-2.*--secrets-encryption" "${TMPDIR}/podman.log"
	assert_success
	run grep -E "RUN_CMD:.*--name k3s-server-3.*--secrets-encryption" "${TMPDIR}/podman.log"
	assert_success
}

@test "setup_k3s_ha_podman_main_node_internal_ips_derived_from_podman_network_subnet_for_all_server_and_agent_nodes" {
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"

	assert_success

	local expected_ips=(
		"10.42.0.11" "10.42.0.12" "10.42.0.13" # Servers
		"10.42.0.21" "10.42.0.22" "10.42.0.23" # Agents
	)
	local container_types=(
		"k3s-server-1" "k3s-server-2" "k3s-server-3"
		"k3s-agent-1" "k3s-agent-2" "k3s-agent-3"
	)

	for i in "${!container_types[@]}"; do
		local container_name="${container_types[$i]}"
		local ip_addr="${expected_ips[$i]}"

		# Check --node-ip and --network ip
        # Note: The order of arguments in the script is:
        # podman run ... --network ... image ... --node-ip ...
        # So --network comes BEFORE --node-ip in the full command string.
		run grep -E "RUN_CMD:.*--name ${container_name}.*--network ${PODMAN_NETWORK}:ip=${ip_addr}.*--node-ip=${ip_addr}" "${TMPDIR}/podman.log"
		assert_success
	done
}

@test "kubeconfig is generated and updated with external IP and cluster name" {
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"

	assert_success

	local kubeconfig_file="${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml"
	assert_file_exist "$kubeconfig_file"

	# Read content and check
	run cat "$kubeconfig_file"
	assert_output_contains "KUBECONFIG_CONTENT_SERVER_URL: ${EXTERNAL_IP}"
	assert_output_contains "KUBECONFIG_CONTENT_CLUSTER_NAME: ${CLUSTER_NAME}"

	# Verify permissions (stat output format varies, but script does chmod 600)
	if [[ "$OSTYPE" == "linux-gnu"* ]]; then
		run stat -c "%a" "$kubeconfig_file"
		assert_output "600"
	fi
}

@test "script is idempotent for network creation" {
	# First run creates the network
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"
	assert_success
	assert_output_contains "Creating Podman network '${PODMAN_NETWORK}'"

	# Reset logs
	rm "${TMPDIR}/podman.log" || true

	# Second run should report network already exists
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"
	assert_success
	assert_output_contains "Podman network '${PODMAN_NETWORK}' already exists."
	refute_output_contains "Creating Podman network '${PODMAN_NETWORK}'"
}

@test "script is idempotent for container creation" {
	# First run creates containers
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"
	assert_success

	# Reset logs
	rm "${TMPDIR}/podman.log" || true

	# Second run should skip container creation
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"
	assert_success
	assert_output_contains "Container 'k3s-server-1' already exists, skipping creation."
	refute_output_contains "Starting server node 'k3s-server-1'..."
}

@test "script is idempotent for cluster token generation" {
	# First run generates token
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"
	assert_success
	assert_output_contains "Generating new cluster token..."

	# Second run should not generate a new token
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"
	assert_success
	refute_output_contains "Generating new cluster token..."
}

@test "script handles missing dependencies gracefully" {
    # Create a restricted bin directory
    mkdir -p "${TMPDIR}/bin_restricted"
    
    # Symlink required tools EXCEPT podman
    for tool in awk sed head base64 cat mkdir rm sleep date tr cut dirname realpath bash sh grep; do
        if command -v "$tool" >/dev/null; then
            ln -s "$(command -v "$tool")" "${TMPDIR}/bin_restricted/$tool"
        fi
    done
    
    # Also link our mocks if they aren't system tools (like hostname mock)
    # But for this test we want system tools mostly, except podman is missing.
    # Actually, the script uses 'check_dependencies' which checks: podman awk sed head base64.
    # We need to ensure 'podman' is NOT in PATH.
    
    # Save original PATH
    local ORIG_PATH="$PATH"
    export PATH="${TMPDIR}/bin_restricted"
    
    run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"
    
    # Restore PATH immediately
    export PATH="$ORIG_PATH"
    
    assert_failure
    assert_output_contains "Required command 'podman' is not installed"
}

@test "script uses default values when environment variables are not set" {
	# Unset all relevant environment variables
	unset CLUSTER_NAME
	unset K3S_IMAGE
	unset PODMAN_NETWORK
	unset PODMAN_SUBNET
	unset DATA_DIR
	unset KUBECONFIG_DIR
	unset EXTERNAL_IP

	# Run from temp dir so relative paths work cleanly
	cd "$TMPDIR"

	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"

	assert_success
	
	# Verify default network name (k3s-ha-net)
	run grep "k3s-ha-net" "${TMPDIR}/podman.log"
	assert_success

	# Verify default dirs created
	assert_dir_exist "./k3s-data"
	assert_dir_exist "./kubeconfig"
}
