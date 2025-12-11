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

assert_output_partial() {
	local expected="$1"
	if [[ "$output" != *"$expected"* ]]; then
		echo "Expected output to contain: $expected"
		echo "Actual output: $output"
		return 1
	fi
}

assert_content_partial() {
    local expected="$1"
    local content="$2"
    if [[ "$content" != *"$expected"* ]]; then
        echo "Expected content to contain: $expected"
        echo "Actual content: $content"
        return 1
    fi
}

assert_output_regexp() {
	local regex="$1"
	local content="${2:-$output}"
	if [[ ! "$content" =~ $regex ]]; then
		echo "Expected content to match regex: $regex"
		echo "Actual content: $content"
		return 1
	fi
}

refute_output_regexp() {
	local regex="$1"
	local content="${2:-$output}"
	if [[ "$content" =~ $regex ]]; then
		echo "Expected content NOT to match regex: $regex"
		echo "Actual content: $content"
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

assert_file_exist() {
	if [ ! -f "$1" ]; then
		echo "File does not exist: $1"
		return 1
	fi
}

refute_file_exist() {
	if [ -f "$1" ]; then
		echo "File exists but should not: $1"
		return 1
	fi
}

# --- Test Setup ---

# The script under test
readonly SCRIPT_UNDER_TEST="${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"

# Temporary directory for test artifacts
TMP_TEST_DIR=""
MOCK_BIN_DIR=""

setup() {
	# Create a unique temporary directory for each test
	TMP_TEST_DIR="$(mktemp -d)"
	MOCK_BIN_DIR="${TMP_TEST_DIR}/mock_bin"
	mkdir -p "${MOCK_BIN_DIR}"

	# Prepend mock_bin to PATH for this test
	export PATH="${MOCK_BIN_DIR}:${PATH}"

	# Create mock executables
	
	# Mock podman
	# Use quoted heredoc to prevent variable expansion during creation.
	# The script calculates its own state directory.
	cat <<'EOF' >"${MOCK_BIN_DIR}/podman"
#!/usr/bin/env bash
# Determine state directory relative to this script
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(dirname "$BIN_DIR")"

# Log all podman calls for inspection
echo "MOCK PODMAN CALLED: $*" >> "$TEST_ROOT/podman_calls.log"

case "$1" in
    network)
        case "$2" in
            inspect)
                if [[ "$3" == "k3s-ha-net" ]]; then
                    if [[ -f "$TEST_ROOT/network_exists" ]]; then
                        exit 0
                    else
                        exit 1
                    fi
                fi
                ;;
            create)
                touch "$TEST_ROOT/network_exists"
                exit 0
                ;;
        esac
        ;;
    container)
        case "$2" in
            exists)
                if [[ -f "$TEST_ROOT/container_${3}_exists" ]]; then
                    exit 0
                else
                    exit 1
                fi
                ;;
        esac
        ;;
    run)
        container_name=""
        args_copy=("$@")
        # Simple loop to find --name
        for ((i=0; i<${#args_copy[@]}; i++)); do
            if [[ "${args_copy[i]}" == "--name" ]]; then
                container_name="${args_copy[i+1]}"
                break
            fi
        done

        if [[ -n "$container_name" ]]; then
            touch "$TEST_ROOT/container_${container_name}_exists"
            
            # If this is server 1, create the marker that kubeconfig is ready
            if [[ "$container_name" == "k3s-server-1" ]]; then
                touch "$TEST_ROOT/kubeconfig_ready_marker"
            fi
        fi

        # Simulate specific failures for tests
        if [[ -f "$TEST_ROOT/fail_k3s_server_1_run" && "$container_name" == "k3s-server-1" ]]; then
            echo "Simulating podman run failure for k3s-server-1" >&2
            exit 1
        fi
        exit 0
        ;;
    exec)
        # Check for kubeconfig wait loop
        # args: exec k3s-server-1 test -f /etc/rancher/k3s/k3s.yaml
        if [[ "$3" == "test" && "$4" == "-f" ]]; then
            if [[ -f "$TEST_ROOT/kubeconfig_ready_marker" ]]; then
                exit 0
            else
                exit 1
            fi
        fi
        exit 0
        ;;
    cp)
        if [[ "$2" == "k3s-server-1:/etc/rancher/k3s/k3s.yaml" ]]; then
            dest_path="$3"
            mkdir -p "$(dirname "$dest_path")"
            # Simulate kubeconfig content
            echo "apiVersion: v1" > "$dest_path"
            echo "server: https://127.0.0.1:6443" >> "$dest_path"
            echo "name: default" >> "$dest_path"
            exit 0
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
	chmod +x "${MOCK_BIN_DIR}/podman"

	# Mock hostname -I
	cat <<'EOF' >"${MOCK_BIN_DIR}/hostname"
#!/usr/bin/env bash
if [[ "$1" == "-I" ]]; then
    echo "192.168.1.100 172.17.0.1"
fi
EOF
	chmod +x "${MOCK_BIN_DIR}/hostname"

	# Mock awk
	cat <<'EOF' >"${MOCK_BIN_DIR}/awk"
#!/usr/bin/env bash
if [[ "$1" == "{print \$1}" ]]; then
    read -r line
    echo "$line" | /usr/bin/awk "{print \$1}"
else
    /usr/bin/awk "$@"
fi
EOF
	chmod +x "${MOCK_BIN_DIR}/awk"

	# Mock sed
	cat <<'EOF' >"${MOCK_BIN_DIR}/sed"
#!/usr/bin/env bash
# Determine state directory relative to this script
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(dirname "$BIN_DIR")"

echo "MOCK SED CALLED: $*" >> "$TEST_ROOT/sed_calls.log"
if [[ "$1" == "-i" ]]; then
    pattern="$2"
    file="$3"
    if [[ -f "$file" ]]; then
        content=$(cat "$file")
        content=$(echo "$content" | /usr/bin/sed "$pattern")
        echo "$content" > "$file"
    fi
    exit 0
fi
/usr/bin/sed "$@"
EOF
	chmod +x "${MOCK_BIN_DIR}/sed"

	# Mock head
	cat <<'EOF' >"${MOCK_BIN_DIR}/head"
#!/usr/bin/env bash
if [[ "$1" == "-c" ]]; then
    echo "RANDOMTOKEN1234567"
    exit 0
fi
/usr/bin/head "$@"
EOF
	chmod +x "${MOCK_BIN_DIR}/head"

	# Mock base64
	cat <<'EOF' >"${MOCK_BIN_DIR}/base64"
#!/usr/bin/env bash
if [[ "$1" == "" ]]; then
    read -r line
    echo "$line" | /usr/bin/base64
    exit 0
fi
/usr/bin/base64 "$@"
EOF
	chmod +x "${MOCK_BIN_DIR}/base64"

	# Mock tr
	cat <<'EOF' >"${MOCK_BIN_DIR}/tr"
#!/usr/bin/env bash
if [[ "$1" == "-d" ]]; then
    read -r line
    echo "$line" | /usr/bin/tr -d '[:space:]'
    exit 0
fi
/usr/bin/tr "$@"
EOF
	chmod +x "${MOCK_BIN_DIR}/tr"
}

teardown() {
	rm -rf "${TMP_TEST_DIR}"
}

@test "setup_k3s_ha_podman_main_host_primary_ip_used_as_external_ip_and_tls_san_in_k3s_server_configuration" {
	local expected_external_ip="192.168.1.100"
	local data_dir="${TMP_TEST_DIR}/data"
	local kubeconfig_dir="${TMP_TEST_DIR}/kubeconfig"

	run env DATA_DIR="${data_dir}" KUBECONFIG_DIR="${kubeconfig_dir}" bash "${SCRIPT_UNDER_TEST}"

	assert_success
	assert_output_partial "Using external IP: ${expected_external_ip}"

	assert_file_exist "${TMP_TEST_DIR}/podman_calls.log"
	local podman_log_content
	podman_log_content=$(cat "${TMP_TEST_DIR}/podman_calls.log")

    # The token is base64 encoded in the script: head | base64 | tr
    # Our mock head returns "RANDOMTOKEN1234567" (plus newline from echo)
    # Our mock base64 encodes that.
    # "RANDOMTOKEN1234567" + newline | base64 -> "UkFORE9NVE9LRU4xMjM0NTY3Cg=="
    # The regex needs to match this encoded token.
	assert_output_regexp "MOCK PODMAN CALLED: run --detach --name k3s-server-1 --hostname k3s-server-1 --privileged --network k3s-ha-net:ip=10.42.0.11 -v ${data_dir}/k3s-server-1:/var/lib/rancher/k3s -p 6443:6443 docker.io/rancher/k3s:v1.32.10-k3s1 server --token=UkFORE9NVE9LRU4xMjM0NTY3Cg== --tls-san=${expected_external_ip} --node-ip=10.42.0.11 --node-external-ip=${expected_external_ip} --secrets-encryption --cluster-init" "$podman_log_content"
}

@test "setup_k3s_ha_podman_main_kubeconfig_exported_from_first_server_into_host_directory_when_missing" {
	local data_dir="${TMP_TEST_DIR}/data"
	local kubeconfig_dir="${TMP_TEST_DIR}/kubeconfig"
	mkdir -p "${kubeconfig_dir}"

	# Simulate existing containers so we don't run 'podman run'
	touch "${TMP_TEST_DIR}/network_exists"
	touch "${TMP_TEST_DIR}/container_k3s-server-1_exists"
	touch "${TMP_TEST_DIR}/container_k3s-server-2_exists"
	touch "${TMP_TEST_DIR}/container_k3s-server-3_exists"
	touch "${TMP_TEST_DIR}/container_k3s-agent-1_exists"
	touch "${TMP_TEST_DIR}/container_k3s-agent-2_exists"
	touch "${TMP_TEST_DIR}/container_k3s-agent-3_exists"
    
    # IMPORTANT: Since we skip 'podman run', we must manually create the marker
    # that tells the mock 'podman exec' that kubeconfig is ready.
    touch "${TMP_TEST_DIR}/kubeconfig_ready_marker"

	local expected_external_ip="192.168.1.100"
	local expected_kubeconfig_path="${kubeconfig_dir}/k3s-server-1-kubeconfig.yaml"

	run env EXTERNAL_IP="${expected_external_ip}" DATA_DIR="${data_dir}" KUBECONFIG_DIR="${kubeconfig_dir}" bash "${SCRIPT_UNDER_TEST}"

	assert_success
	assert_output_partial "Copying kubeconfig from 'k3s-server-1' to host..."
	assert_output_partial "Updating kubeconfig server address to '${expected_external_ip}'..."

	assert_file_exist "${expected_kubeconfig_path}"

	local kubeconfig_content
	kubeconfig_content=$(cat "${expected_kubeconfig_path}")
    # Use assert_content_partial to check the file content, not the script output
	assert_content_partial "server: https://${expected_external_ip}:6443" "$kubeconfig_content"
	assert_content_partial "name: k3s-ha" "$kubeconfig_content"
}

@test "setup_k3s_ha_podman_main_kubeconfig_export_does_not_overwrite_existing_host_kubeconfig_file" {
	local data_dir="${TMP_TEST_DIR}/data"
	local kubeconfig_dir="${TMP_TEST_DIR}/kubeconfig"
	mkdir -p "${kubeconfig_dir}"

	local expected_external_ip="192.168.1.100"
	local existing_kubeconfig_path="${kubeconfig_dir}/k3s-server-1-kubeconfig.yaml"
	local original_content="original_kubeconfig_content_with_different_ip_and_name"
	echo "${original_content}" >"${existing_kubeconfig_path}"

	touch "${TMP_TEST_DIR}/network_exists"
	touch "${TMP_TEST_DIR}/container_k3s-server-1_exists"
	touch "${TMP_TEST_DIR}/container_k3s-server-2_exists"
	touch "${TMP_TEST_DIR}/container_k3s-server-3_exists"
	touch "${TMP_TEST_DIR}/container_k3s-agent-1_exists"
	touch "${TMP_TEST_DIR}/container_k3s-agent-2_exists"
	touch "${TMP_TEST_DIR}/container_k3s-agent-3_exists"

	run env EXTERNAL_IP="${expected_external_ip}" DATA_DIR="${data_dir}" KUBECONFIG_DIR="${kubeconfig_dir}" bash "${SCRIPT_UNDER_TEST}"

	assert_success
	assert_output_partial "Kubeconfig file '${existing_kubeconfig_path}' already exists, skipping retrieval."

	local current_content
	current_content=$(cat "${existing_kubeconfig_path}")
	assert_equal "${original_content}" "${current_content}"

	if [ -f "${TMP_TEST_DIR}/podman_calls.log" ]; then
	    local podman_log_content
	    podman_log_content=$(cat "${TMP_TEST_DIR}/podman_calls.log")
	    refute_output_regexp "MOCK PODMAN CALLED: cp k3s-server-1:/etc/rancher/k3s/k3s.yaml .*" "$podman_log_content"
    fi

	refute_file_exist "${TMP_TEST_DIR}/sed_calls.log"
}

@test "setup_k3s_ha_podman_main_missing_podman_binary_causes_clear_error_message_and_nonzero_exit_code" {
    local restricted_bin="${TMP_TEST_DIR}/restricted_bin"
    mkdir -p "$restricted_bin"
    
    for tool in awk sed head base64 cat mkdir rm sleep date tr cut dirname realpath bash sh grep; do
        if command -v "$tool" >/dev/null; then
            ln -s "$(command -v "$tool")" "${restricted_bin}/$tool"
        fi
    done
    ln -s "${MOCK_BIN_DIR}/hostname" "${restricted_bin}/hostname"

	local data_dir="${TMP_TEST_DIR}/data"
	local kubeconfig_dir="${TMP_TEST_DIR}/kubeconfig"

	run env PATH="${restricted_bin}" DATA_DIR="${data_dir}" KUBECONFIG_DIR="${kubeconfig_dir}" bash "${SCRIPT_UNDER_TEST}"

	assert_failure
	assert_output_regexp "Required command 'podman' is not installed or not in PATH."
}

@test "setup_k3s_ha_podman_main_failure_to_start_any_container_propagates_error_and_stops_further_container_creation" {
	touch "${TMP_TEST_DIR}/fail_k3s_server_1_run"
	local data_dir="${TMP_TEST_DIR}/data"
	local kubeconfig_dir="${TMP_TEST_DIR}/kubeconfig"

	run env DATA_DIR="${data_dir}" KUBECONFIG_DIR="${kubeconfig_dir}" bash "${SCRIPT_UNDER_TEST}"

	assert_failure
    # The script uses set -e, so it might exit without printing "ERROR" if the command fails directly.
    # However, the mock prints the failure message to stderr (which is captured in output).
	assert_output_partial "Simulating podman run failure for k3s-server-1"

	assert_file_exist "${TMP_TEST_DIR}/podman_calls.log"
	local podman_log_content
	podman_log_content=$(cat "${TMP_TEST_DIR}/podman_calls.log")

	assert_output_regexp "MOCK PODMAN CALLED: run .* --name k3s-server-1 .*" "$podman_log_content"
	refute_output_regexp "MOCK PODMAN CALLED: run .* --name k3s-server-2 .*" "$podman_log_content"
	refute_output_regexp "MOCK PODMAN CALLED: run .* --name k3s-agent-1 .*" "$podman_log_content"

	assert_file_exist "${TMP_TEST_DIR}/container_k3s-server-1_exists"
	refute_file_exist "${TMP_TEST_DIR}/container_k3s-server-2_exists"
	refute_file_exist "${TMP_TEST_DIR}/container_k3s-agent-1_exists"
}
