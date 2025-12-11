#!/usr/bin/env bats

# --- Helper Functions ---

assert_success() {
	if [ "$status" -ne 0 ]; then
		echo "Command failed with status $status"
		echo "Output: $output"
		return 1
	fi
}

assert_output_partial() {
	local expected="$1"
	if [[ "$output" != *"$expected"* ]]; then
		echo "Expected output to contain: $expected"
		echo "Actual output: $output"
		return 1
	fi
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	if [ "$actual" != "$expected" ]; then
		echo "Expected: '$expected'"
		echo "Actual:   '$actual'"
		return 1
	fi
}

# --- Test Setup ---

SCRIPT_NAME="setup_k3s_ha_podman.sh"
TEST_TMPDIR=""

setup() {
	TEST_TMPDIR="$(mktemp -d)"
	export DATA_DIR="${TEST_TMPDIR}/k3s-data"
	export KUBECONFIG_DIR="${TEST_TMPDIR}/kubeconfig"
	export PODMAN_NETWORK="k3s-ha-net-test-batch5"
	export CLUSTER_NAME="k3s-ha-test-batch5"
	export K3S_IMAGE="docker.io/rancher/k3s:v1.32.10-k3s1"

	# Copy script
	cp "${BATS_TEST_DIRNAME}/${SCRIPT_NAME}" "${TEST_TMPDIR}/${SCRIPT_NAME}"
	chmod +x "${TEST_TMPDIR}/${SCRIPT_NAME}"

	# Create mocks
	MOCK_BIN="${TEST_TMPDIR}/bin"
	mkdir -p "${MOCK_BIN}"
	export PATH="${MOCK_BIN}:${PATH}"

	# Mock hostname
	echo '#!/bin/bash' > "${MOCK_BIN}/hostname"
	echo 'echo 127.0.0.1' >> "${MOCK_BIN}/hostname"
	chmod +x "${MOCK_BIN}/hostname"

	# Mock head/base64
	echo '#!/bin/bash' > "${MOCK_BIN}/head"
	echo 'echo mock' >> "${MOCK_BIN}/head"
	chmod +x "${MOCK_BIN}/head"
	echo '#!/bin/bash' > "${MOCK_BIN}/base64"
	echo 'echo mocktoken' >> "${MOCK_BIN}/base64"
	chmod +x "${MOCK_BIN}/base64"

	# Mock podman
	cat <<'EOF' >"${MOCK_BIN}/podman"
#!/usr/bin/env bash
# Determine state directory relative to this script location
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$(dirname "$BIN_DIR")/podman_state"
mkdir -p "${STATE_DIR}"

cmd="$1"
shift

case "$cmd" in
    network)
        if [[ "$1" == "inspect" ]]; then
            if [[ -f "${STATE_DIR}/net" ]]; then exit 0; else exit 1; fi
        elif [[ "$1" == "create" ]]; then
            touch "${STATE_DIR}/net"
            exit 0
        fi
        ;;
    container)
        if [[ "$1" == "exists" ]]; then
            if [[ -f "${STATE_DIR}/cont_$2" ]]; then exit 0; else exit 1; fi
        elif [[ "$1" == "inspect" ]]; then
             # Simple existence check for test 1
             if [[ -f "${STATE_DIR}/cont_$2" ]]; then exit 0; else exit 1; fi
        fi
        ;;
    run)
        name=""
        args="$*"
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "--name" ]]; then name="$2"; fi
            shift
        done
        if [[ -n "$name" ]]; then
            touch "${STATE_DIR}/cont_$name"
            echo "$args" > "${STATE_DIR}/args_$name"
            # Generate a fake ID
            echo "id_$name" > "${STATE_DIR}/id_$name"
            
            if [[ "$name" == "k3s-server-1" ]]; then
                mkdir -p "${STATE_DIR}/vols/k3s-server-1/etc/rancher/k3s"
                echo "server: https://127.0.0.1:6443" > "${STATE_DIR}/vols/k3s-server-1/etc/rancher/k3s/k3s.yaml"
                echo "name: default" >> "${STATE_DIR}/vols/k3s-server-1/etc/rancher/k3s/k3s.yaml"
            fi
        fi
        exit 0
        ;;
    inspect)
        # Handle format requests
        name=""
        fmt=""
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "-f" || "$1" == "--format" ]]; then fmt="$2"; shift; else name="$1"; fi
            shift
        done
        
        if [[ "$fmt" == "{{.Id}}" ]]; then
            cat "${STATE_DIR}/id_$name"
        elif [[ "$fmt" == "{{.Config.Cmd}}" ]]; then
            cat "${STATE_DIR}/args_$name"
        fi
        exit 0
        ;;
    exec)
        if [[ "$2" == "test" ]]; then exit 0; fi
        ;;
    cp)
        src="$1"
        dest="$2"
        container="${src%%:*}"
        path="${src#*:}"
        if [[ -f "${STATE_DIR}/vols/$container$path" ]]; then
            mkdir -p "$(dirname "$dest")"
            cp "${STATE_DIR}/vols/$container$path" "$dest"
        fi
        exit 0
        ;;
    stop|rm) exit 0 ;;
esac
EOF
	chmod +x "${MOCK_BIN}/podman"

    # Passthrough
    ln -s "$(command -v awk)" "${MOCK_BIN}/awk"
    ln -s "$(command -v sed)" "${MOCK_BIN}/sed"
}

teardown() {
	rm -rf "$TEST_TMPDIR"
}

@test "setup_k3s_ha_podman_Integration_existing_server_and_agent_containers_are_not_duplicated_on_second_run_idempotency_preserved" {
	run bash "${TEST_TMPDIR}/${SCRIPT_NAME}"
	assert_success

	# Capture IDs
	local server1_id_first_run
	server1_id_first_run=$(podman inspect -f '{{.Id}}' k3s-server-1)
	local agent1_id_first_run
	agent1_id_first_run=$(podman inspect -f '{{.Id}}' k3s-agent-1)

	# Run again
	run bash "${TEST_TMPDIR}/${SCRIPT_NAME}"
	assert_success
	assert_output_partial "Container 'k3s-server-1' already exists, skipping creation."

	local server1_id_second_run
	server1_id_second_run=$(podman inspect -f '{{.Id}}' k3s-server-1)
	
	assert_equal "$server1_id_first_run" "$server1_id_second_run"
}

@test "setup_k3s_ha_podman_Integration_embedded_etcd_and_aes_cbc_encryption_flags_present_in_k3s_server_container_command_line" {
	run bash "${TEST_TMPDIR}/${SCRIPT_NAME}"
	assert_success

	run podman inspect k3s-server-1 --format '{{.Config.Cmd}}'
	assert_success
	assert_output_partial "server"
	assert_output_partial "--cluster-init"
	assert_output_partial "--secrets-encryption"

	run podman inspect k3s-server-2 --format '{{.Config.Cmd}}'
	assert_success
	assert_output_partial "server"
	assert_output_partial "--secrets-encryption"
}

@test "setup_k3s_ha_podman_Integration_kubeconfig_copied_from_first_server_container_into_host_temp_directory_and_remains_unchanged_on_rerun" {
	run bash "${TEST_TMPDIR}/${SCRIPT_NAME}"
	assert_success

	local kubeconfig_file="${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml"
	
	# Check content
	run grep "server: https://127.0.0.1:6443" "$kubeconfig_file"
	assert_success
	run grep "name: ${CLUSTER_NAME}" "$kubeconfig_file"
	assert_success

	local initial_content
	initial_content=$(cat "$kubeconfig_file")

	# Rerun
	run bash "${TEST_TMPDIR}/${SCRIPT_NAME}"
	assert_success

	local second_content
	second_content=$(cat "$kubeconfig_file")
	assert_equal "$initial_content" "$second_content"
}
