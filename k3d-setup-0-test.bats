#!/usr/bin/env bats

# --- Helper Functions ---

assert_success() {
	if [ "$status" -ne 0 ]; then
		echo "Command failed with status $status"
		echo "Output: $output"
		return 1
	fi
}

assert_exist() {
	if [ ! -f "$1" ]; then
		echo "File does not exist: $1"
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

assert_not_equal() {
	local actual="$1"
	local unexpected="$2"
	if [ "$actual" == "$unexpected" ]; then
		echo "Expected not to equal: '$unexpected'"
		return 1
	fi
}

assert_equal() {
	local actual="$1"
	local expected="$2"
	if [ "$actual" != "$expected" ]; then
		echo "Expected: '$expected'"
		echo "Actual:   '$actual'"
		return 1
	fi
}

# --- Test Setup ---

SCRIPT_FILE="setup_k3s_ha_podman.sh"

setup() {
	# Create a temporary directory for all test artifacts
	tmpdir="$(mktemp -d)"
	export HOME="${tmpdir}/home"
	mkdir -p "${HOME}"

	# Create bin directory
	mkdir -p "${tmpdir}/bin"
	export PATH="${tmpdir}/bin:${PATH}"

	# --- Create Mocks ---

	# Mock podman
	cat <<EOF >"${tmpdir}/bin/podman"
#!/usr/bin/env bash

# Log args for verification
echo "\$@" >> "${tmpdir}/podman.log"

CMD="\$1"

if [[ "\$CMD" == "network" ]]; then
    SUBCMD="\$2"
    if [[ "\$SUBCMD" == "inspect" ]]; then
        if [[ -f "${tmpdir}/network_exists" ]]; then exit 0; else exit 1; fi
    elif [[ "\$SUBCMD" == "create" ]]; then
        touch "${tmpdir}/network_exists"
        exit 0
    elif [[ "\$SUBCMD" == "rm" ]]; then
        rm -f "${tmpdir}/network_exists"
        exit 0
    fi

elif [[ "\$CMD" == "container" ]]; then
    SUBCMD="\$2"
    if [[ "\$SUBCMD" == "exists" ]]; then
        NAME="\$3"
        if [[ -f "${tmpdir}/container_\${NAME}_exists" ]]; then exit 0; else exit 1; fi
    fi

elif [[ "\$CMD" == "run" ]]; then
    # Extract container name from arguments
    NAME=""
    PREV=""
    for ARG in "\$@"; do
        if [[ "\$PREV" == "--name" ]]; then
            NAME="\$ARG"
            break
        fi
        PREV="\$ARG"
    done

    if [[ -n "\$NAME" ]]; then
        touch "${tmpdir}/container_\${NAME}_exists"
        
        # Special handling for k3s-server-1 to create the kubeconfig file
        # This prevents the retrieve_kubeconfig function from looping indefinitely
        if [[ "\$NAME" == "k3s-server-1" ]]; then
            mkdir -p "${tmpdir}/data/k3s-server-1/etc/rancher/k3s"
            echo "apiVersion: v1" > "${tmpdir}/data/k3s-server-1/etc/rancher/k3s/k3s.yaml"
        fi
    fi
    exit 0

elif [[ "\$CMD" == "exec" ]]; then
    # Check if this is the kubeconfig check
    # Arguments will be: exec k3s-server-1 test -f /etc/rancher/k3s/k3s.yaml
    # We just check if the file exists on our mock filesystem
    if [[ "\$@" == *"/etc/rancher/k3s/k3s.yaml"* ]]; then
        if [[ -f "${tmpdir}/data/k3s-server-1/etc/rancher/k3s/k3s.yaml" ]]; then
            exit 0
        else
            exit 1
        fi
    fi
    exit 0

elif [[ "\$CMD" == "cp" ]]; then
    # cp k3s-server-1:/etc/rancher/k3s/k3s.yaml dest
    SRC="\$2"
    DEST="\$3"
    if [[ "\$SRC" == *"k3s-server-1:/etc/rancher/k3s/k3s.yaml" ]]; then
        mkdir -p "\$(dirname "\$DEST")"
        if [[ -f "${tmpdir}/data/k3s-server-1/etc/rancher/k3s/k3s.yaml" ]]; then
            cp "${tmpdir}/data/k3s-server-1/etc/rancher/k3s/k3s.yaml" "\$DEST"
            exit 0
        else
            echo "Source file not found" >&2
            exit 1
        fi
    fi
    exit 0
    
elif [[ "\$CMD" == "rm" ]]; then
    exit 0
fi

exit 1
EOF
	chmod +x "${tmpdir}/bin/podman"

	# Mock other utilities
	for tool in awk sed head base64; do
		cat <<EOF >"${tmpdir}/bin/${tool}"
#!/usr/bin/env bash
exec /usr/bin/${tool} "\$@"
EOF
		chmod +x "${tmpdir}/bin/${tool}"
	done
}

teardown() {
	rm -rf "${tmpdir}"
}

@test "setup_k3s_ha_podman_main_no_existing_containers_creates_all_server_and_agent_containers_successfully" {
	DATA_DIR="${tmpdir}/data" \
		KUBECONFIG_DIR="${tmpdir}/kube" \
		EXTERNAL_IP="203.0.113.5" \
		PODMAN_NETWORK="k3s-ha-net" \
		PODMAN_SUBNET="10.42.0.0/24" \
		run bash "${BATS_TEST_DIRNAME}/${SCRIPT_FILE}"

	assert_success
	assert_exist "${tmpdir}/network_exists"
	assert_exist "${tmpdir}/container_k3s-server-1_exists"
	assert_exist "${tmpdir}/container_k3s-server-2_exists"
	assert_exist "${tmpdir}/container_k3s-server-3_exists"
	assert_exist "${tmpdir}/container_k3s-agent-1_exists"
	assert_exist "${tmpdir}/container_k3s-agent-2_exists"
	assert_exist "${tmpdir}/container_k3s-agent-3_exists"
	assert_exist "${tmpdir}/kube/k3s-server-1-kubeconfig.yaml"
}

@test "setup_k3s_ha_podman_main_existing_named_containers_are_detected_and_skipped_without_recreation" {
	# Pre-create state
	touch "${tmpdir}/container_k3s-server-1_exists"
	touch "${tmpdir}/container_k3s-agent-1_exists"
	touch "${tmpdir}/network_exists"
	
	# IMPORTANT: Pre-create the kubeconfig file because k3s-server-1 exists, 
	# so 'podman run' won't be called to create it.
	mkdir -p "${tmpdir}/data/k3s-server-1/etc/rancher/k3s"
	touch "${tmpdir}/data/k3s-server-1/etc/rancher/k3s/k3s.yaml"

	DATA_DIR="${tmpdir}/data" \
		KUBECONFIG_DIR="${tmpdir}/kube" \
		EXTERNAL_IP="198.51.100.7" \
		PODMAN_NETWORK="k3s-ha-net" \
		PODMAN_SUBNET="10.42.0.0/24" \
		run bash "${BATS_TEST_DIRNAME}/${SCRIPT_FILE}"

	assert_success
	assert_output_partial "Container 'k3s-server-1' already exists, skipping creation."
	assert_output_partial "Container 'k3s-agent-1' already exists, skipping creation."
	assert_exist "${tmpdir}/container_k3s-server-2_exists"
	assert_exist "${tmpdir}/container_k3s-server-3_exists"
	assert_exist "${tmpdir}/container_k3s-agent-2_exists"
	assert_exist "${tmpdir}/container_k3s-agent-3_exists"
}

@test "setup_k3s_ha_podman_main_cluster_token_generated_once_and_reused_for_all_servers_and_agents_in_single_run" {
	DATA_DIR="${tmpdir}/data" \
		KUBECONFIG_DIR="${tmpdir}/kube" \
		EXTERNAL_IP="192.0.2.55" \
		PODMAN_NETWORK="k3s-ha-net" \
		PODMAN_SUBNET="10.42.0.0/24" \
		run bash "${BATS_TEST_DIRNAME}/${SCRIPT_FILE}"

	assert_success
	assert_exist "${tmpdir}/data/cluster-token"
	local token_content
	token_content=$(cat "${tmpdir}/data/cluster-token")
	assert_not_equal "${token_content}" ""

	# Check log for token usage
	run grep "token=${token_content}" "${tmpdir}/podman.log"
	assert_success
}

@test "setup_k3s_ha_podman_main_cluster_token_persisted_and_reused_across_two_consecutive_invocations" {
	DATA_DIR="${tmpdir}/data" \
		KUBECONFIG_DIR="${tmpdir}/kube" \
		EXTERNAL_IP="203.0.113.12" \
		PODMAN_NETWORK="k3s-ha-net" \
		PODMAN_SUBNET="10.42.0.0/24" \
		run bash "${BATS_TEST_DIRNAME}/${SCRIPT_FILE}"
	assert_success

	local first_run_token
	first_run_token=$(cat "${tmpdir}/data/cluster-token")
	assert_not_equal "${first_run_token}" ""

	# Reset container state
	rm -f "${tmpdir}/container_"*
	rm -f "${tmpdir}/network_exists"

	DATA_DIR="${tmpdir}/data" \
		KUBECONFIG_DIR="${tmpdir}/kube" \
		EXTERNAL_IP="198.51.100.20" \
		PODMAN_NETWORK="k3s-ha-net" \
		PODMAN_SUBNET="10.42.0.0/24" \
		run bash "${BATS_TEST_DIRNAME}/${SCRIPT_FILE}"
	assert_success

	local second_run_token
	second_run_token=$(cat "${tmpdir}/data/cluster-token")
	assert_equal "${first_run_token}" "${second_run_token}"
}

@test "setup_k3s_ha_podman_main_podman_network_created_when_missing_and_reused_when_already_present" {
	rm -f "${tmpdir}/network_exists"

	DATA_DIR="${tmpdir}/data" \
		KUBECONFIG_DIR="${tmpdir}/kube" \
		EXTERNAL_IP="10.0.0.1" \
		PODMAN_NETWORK="k3s-ha-net" \
		PODMAN_SUBNET="10.42.0.0/24" \
		run bash "${BATS_TEST_DIRNAME}/${SCRIPT_FILE}"
	assert_success
	assert_exist "${tmpdir}/network_exists"
	assert_output_partial "Creating Podman network 'k3s-ha-net'"

	# Second run
	rm -f "${tmpdir}/container_"* # Clear containers to force run logic if needed, but network exists
	
	DATA_DIR="${tmpdir}/data" \
		KUBECONFIG_DIR="${tmpdir}/kube" \
		EXTERNAL_IP="10.0.0.2" \
		PODMAN_NETWORK="k3s-ha-net" \
		PODMAN_SUBNET="10.42.0.0/24" \
		run bash "${BATS_TEST_DIRNAME}/${SCRIPT_FILE}"
	assert_success
	assert_output_partial "Podman network 'k3s-ha-net' already exists."
}
