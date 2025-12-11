#!/usr/bin/env bats

# --- Helper Functions (Replacements for bats-support/bats-assert) ---

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

assert_output_partial() {
	local expected="$1"
	if [[ "$output" != *"$expected"* ]]; then
		echo "Expected output to contain: $expected"
		echo "Actual output: $output"
		return 1
	fi
}

refute_output_partial() {
	local unexpected="$1"
	if [[ "$output" == *"$unexpected"* ]]; then
		echo "Expected output NOT to contain: $unexpected"
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

assert_not_empty() {
	if [ -z "$1" ]; then
		echo "Expected non-empty string"
		return 1
	fi
}

assert_file_exist() {
	if [ ! -f "$1" ]; then
		echo "File does not exist: $1"
		return 1
	fi
}

# --- Test Setup ---

setup() {
	TEST_TMPDIR="$(mktemp -d)"
	export TEST_TMPDIR # Export so mocks can see it
	export DATA_DIR="$TEST_TMPDIR/k3s-data"
	export KUBECONFIG_DIR="$TEST_TMPDIR/kubeconfig"
	export PODMAN_NETWORK="test-k3s-ha-net-batch3"
	export CLUSTER_NAME="test-k3s-ha-batch3"
	export K3S_IMAGE="docker.io/rancher/k3s:v1.32.10-k3s1"

	# Create mock binaries directory
	MOCK_BIN="$TEST_TMPDIR/bin"
	mkdir -p "$MOCK_BIN"
	export PATH="$MOCK_BIN:$PATH"

	# Mock `hostname`
	cat <<'EOF' >"$MOCK_BIN/hostname"
#!/usr/bin/env bash
if [[ "$1" == "-I" ]]; then
    echo "192.168.1.100 172.17.0.1"
else
    # Fallback to system hostname if available, else echo mock
    if command -v /usr/bin/hostname >/dev/null; then
        /usr/bin/hostname "$@"
    else
        echo "mock-hostname"
    fi
fi
EOF
	chmod +x "$MOCK_BIN/hostname"

	# Mock `podman`
	# This mock needs to handle state for idempotency tests and failure injection
    # Use unquoted heredoc to expand TEST_TMPDIR, but escape internal vars
	cat <<EOF >"$MOCK_BIN/podman"
#!/usr/bin/env bash
STATE_DIR="${TEST_TMPDIR}"

case "\$1" in
    network)
        if [[ "\$2" == "inspect" ]]; then
            if [[ -f "\$STATE_DIR/network_created" ]]; then exit 0; else exit 1; fi
        elif [[ "\$2" == "create" ]]; then
            touch "\$STATE_DIR/network_created"
            exit 0
        fi
        ;;
    container)
        if [[ "\$2" == "exists" ]]; then
            name="\$3"
            if [[ -f "\$STATE_DIR/container_\${name}_created" ]]; then exit 0; else exit 1; fi
        fi
        ;;
    run)
        # Extract name
        name=""
        args=("\$@")
        for ((i=0; i<\${#args[@]}; i++)); do
            if [[ "\${args[i]}" == "--name" ]]; then
                name="\${args[i+1]}"
                break
            fi
        done
        
        if [[ -n "\$name" ]]; then
            touch "\$STATE_DIR/container_\${name}_created"
            # Create dummy kubeconfig inside "container" for exec/cp to find
            mkdir -p "\$STATE_DIR/containers/\$name/etc/rancher/k3s"
            echo "apiVersion: v1" > "\$STATE_DIR/containers/\$name/etc/rancher/k3s/k3s.yaml"
        fi
        exit 0
        ;;
    exec)
        # exec container test -f ...
        if [[ "\$3" == "test" && "\$4" == "-f" ]]; then
            container="\$2"
            file="\$5"
            # Simulate file existence
            if [[ -f "\$STATE_DIR/containers/\$container\$file" ]]; then exit 0; else exit 1; fi
        fi
        exit 0
        ;;
    cp)
        # cp container:path dest
        src="\$2"
        dest="\$3"
        
        # Check for failure injection flag
        if [[ -f "\$STATE_DIR/fail_cp" ]]; then
            echo "Error: failed to copy \$src to \$dest: Permission denied" >&2
            exit 1
        fi

        container="\${src%%:*}"
        path="\${src#*:}"
        
        if [[ -f "\$STATE_DIR/containers/\$container\$path" ]]; then
            mkdir -p "\$(dirname "\$dest")"
            cp "\$STATE_DIR/containers/\$container\$path" "\$dest"
            exit 0
        else
            echo "Error: No such container:path \$src" >&2
            exit 1
        fi
        ;;
    *)
        exit 0
        ;;
esac
EOF
	chmod +x "$MOCK_BIN/podman"

	# Mock other dependencies to ensure they exist in MOCK_BIN
	# This is important for the test that clears PATH
	for cmd in awk sed head base64; do
		cat <<EOF >"$MOCK_BIN/$cmd"
#!/usr/bin/env bash
# Passthrough to system binary
exec /usr/bin/$cmd "\$@"
EOF
		chmod +x "$MOCK_BIN/$cmd"
	done
}

teardown() {
	rm -rf "$TEST_TMPDIR"
}

# Helper function to run the script under test
run_script_batch_3() {
	run bash "${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh" "$@"
}

@test "setup_k3s_ha_podman_main_cli_with_help_flag_displays_usage_information_and_exits_zero" {
	run_script_batch_3 --help
	assert_success
    # Match the usage line loosely to account for absolute paths in $0
	assert_output_partial "Usage:"
    assert_output_partial "[-h|--help]"
	assert_output_partial "Bootstraps a highly available K3s cluster on a single host using Podman."
}

@test "setup_k3s_ha_podman_main_cli_without_required_prerequisites_exits_with_nonzero_status" {
	# Temporarily remove podman from PATH to simulate missing dependency
	# We do this by creating a new bin dir without podman and setting PATH to it
	local NO_PODMAN_BIN="$TEST_TMPDIR/no_podman_bin"
	mkdir -p "$NO_PODMAN_BIN"
	
    # Symlink required system binaries to the restricted bin directory
    # The script needs: awk, sed, head, base64 (checked by check_dependencies)
    # The script also needs: bash, rm, mkdir, cat, tr, grep, cut, date, sleep (used in logic)
    # BATS needs: bash, rm, etc.
    
    local REQUIRED_TOOLS=(
        bash sh rm mkdir cat tr grep cut date sleep
        awk sed head base64 hostname
    )
    
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if command -v "$tool" >/dev/null; then
            ln -s "$(command -v "$tool")" "$NO_PODMAN_BIN/$tool"
        elif [[ -f "$MOCK_BIN/$tool" ]]; then
             # Fallback to our mocks if system tool not found (e.g. hostname mock)
             cp "$MOCK_BIN/$tool" "$NO_PODMAN_BIN/$tool"
        fi
    done

	local ORIGINAL_PATH="$PATH"
	export PATH="$NO_PODMAN_BIN"

	run_script_batch_3
	assert_failure
	assert_output_partial "Required command 'podman' is not installed or not in PATH."

	export PATH="$ORIGINAL_PATH"
}

@test "setup_k3s_ha_podman_main_invalid_or_unwritable_kubeconfig_output_directory_causes_descriptive_error_and_nonzero_exit" {
	# Trigger cp failure in mock
	touch "$TEST_TMPDIR/fail_cp"

	# We don't actually need to make the directory unwritable because we are mocking the failure
	# But let's set the var anyway
	export KUBECONFIG_DIR="$TEST_TMPDIR/unwritable_kubeconfig"
	mkdir -p "$KUBECONFIG_DIR"

	run_script_batch_3
	assert_failure
	assert_output_partial "Error: failed to copy"
	assert_output_partial "Permission denied"
}

@test "setup_k3s_ha_podman_main_repeated_invocation_is_idempotent_for_network_token_and_container_state" {
	# First invocation: create everything
	run_script_batch_3
	assert_success
	assert_output_partial "Creating Podman network 'test-k3s-ha-net-batch3'"
	assert_output_partial "Generating new cluster token..."
	assert_output_partial "Starting server node 'k3s-server-1'..."
	assert_output_partial "Starting agent node 'k3s-agent-1'..."
	assert_output_partial "Copying kubeconfig from 'k3s-server-1' to host..."
	assert_output_partial "K3s HA cluster setup complete!"

	# Capture the initial cluster token
	local first_token=$(cat "${DATA_DIR}/cluster-token")
	assert_not_empty "$first_token"

	# Capture the initial kubeconfig content
	local kubeconfig_path="${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml"
	assert_file_exist "$kubeconfig_path"
	local first_kubeconfig_content=$(cat "$kubeconfig_path")
	assert_not_empty "$first_kubeconfig_content"

	# Second invocation: should skip creation of existing resources
	run_script_batch_3
	assert_success
	assert_output_partial "Podman network 'test-k3s-ha-net-batch3' already exists."
	refute_output_partial "Creating Podman network 'test-k3s-ha-net-batch3'"
	refute_output_partial "Generating new cluster token..."
	assert_output_partial "Container 'k3s-server-1' already exists, skipping creation."
	assert_output_partial "Container 'k3s-agent-1' already exists, skipping creation."
	assert_output_partial "Kubeconfig file '${kubeconfig_path}' already exists, skipping retrieval."
	assert_output_partial "K3s HA cluster setup complete!"

	# Verify token is the same
	local second_token=$(cat "${DATA_DIR}/cluster-token")
	assert_equal "$first_token" "$second_token"

	# Verify kubeconfig is the same
	local second_kubeconfig_content=$(cat "$kubeconfig_path")
	assert_equal "$first_kubeconfig_content" "$second_kubeconfig_content"
}
