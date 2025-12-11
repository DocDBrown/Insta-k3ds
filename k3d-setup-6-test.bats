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

assert_dir_exist() {
	if [ ! -d "$1" ]; then
		echo "Directory does not exist: $1"
		return 1
	fi
}

assert_empty() {
	if [ -n "$1" ]; then
		echo "Expected empty string, got: $1"
		return 1
	fi
}

# --- Test Setup ---

SCRIPT_UNDER_TEST="${BATS_TEST_DIRNAME}/setup_k3s_ha_podman.sh"

setup() {
	TMP_TEST_DIR=$(mktemp -d)
	MOCK_BIN_DIR="${TMP_TEST_DIR}/bin"
	mkdir -p "${MOCK_BIN_DIR}"

	export DATA_DIR="${TMP_TEST_DIR}/k3s-data"
	export KUBECONFIG_DIR="${TMP_TEST_DIR}/kubeconfig"
	export CLUSTER_NAME="test-k3s-ha"
	export K3S_IMAGE="test/k3s:latest"
	export PODMAN_NETWORK="test-k3s-ha-net"
	export PODMAN_SUBNET="10.42.0.0/24"
	export EXTERNAL_IP="192.168.1.100"

	# Mock awk
	cat <<'EOF' >"${MOCK_BIN_DIR}/awk"
#!/usr/bin/env bash
if [[ "$*" == *"{print $1}"* ]]; then echo "192.168.1.100"; else /usr/bin/awk "$@"; fi
EOF
	chmod +x "${MOCK_BIN_DIR}/awk"

	# Mock sed
	cat <<'EOF' >"${MOCK_BIN_DIR}/sed"
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ -f "$arg" ]]; then file="$arg"; fi
done
if [[ -n "$file" ]]; then
    # Simulate replacement
    content=$(cat "$file")
    content="${content//127.0.0.1/192.168.1.100}"
    content="${content//default/test-k3s-ha}"
    echo "$content" > "$file"
fi
EOF
	chmod +x "${MOCK_BIN_DIR}/sed"

	# Mock head/base64
	echo '#!/bin/bash' > "${MOCK_BIN_DIR}/head"
	echo 'echo rawtoken' >> "${MOCK_BIN_DIR}/head"
	chmod +x "${MOCK_BIN_DIR}/head"
	echo '#!/bin/bash' > "${MOCK_BIN_DIR}/base64"
	echo 'echo encodedtoken' >> "${MOCK_BIN_DIR}/base64"
	chmod +x "${MOCK_BIN_DIR}/base64"

	# Mock hostname
	echo '#!/bin/bash' > "${MOCK_BIN_DIR}/hostname"
	echo 'echo 192.168.1.100' >> "${MOCK_BIN_DIR}/hostname"
	chmod +x "${MOCK_BIN_DIR}/hostname"

	# Mock podman
    # Make the mock self-aware of its location to find the state dir
	cat <<'EOF' >"${MOCK_BIN_DIR}/podman"
#!/usr/bin/env bash
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$(dirname "$BIN_DIR")/state"
mkdir -p "$STATE"

case "$1" in
    network)
        if [[ "$2" == "inspect" ]]; then
            if [[ -f "$STATE/net" ]]; then exit 0; else exit 1; fi
        elif [[ "$2" == "create" ]]; then
            touch "$STATE/net"
            exit 0
        fi
        ;;
    container)
        if [[ "$2" == "exists" ]]; then
            if [[ -f "$STATE/cont_$3" ]]; then exit 0; else exit 1; fi
        fi
        ;;
    run)
        name=""
        args="$@"
        for arg in "$@"; do
            if [[ "$prev" == "--name" ]]; then name="$arg"; fi
            prev="$arg"
        done
        if [[ -n "$name" ]]; then
            touch "$STATE/cont_$name"
            if [[ "$name" == "k3s-server-1" ]]; then
                touch "$STATE/ready"
                # Create dummy kubeconfig for cp
                mkdir -p "$STATE/vols/k3s-server-1/etc/rancher/k3s"
                echo "dummy" > "$STATE/vols/k3s-server-1/etc/rancher/k3s/k3s.yaml"
            fi
        fi
        exit 0
        ;;
    exec)
        if [[ "$3" == "test" ]]; then
            if [[ -f "$STATE/ready" ]]; then exit 0; else exit 1; fi
        fi
        exit 0
        ;;
    cp)
        # cp k3s-server-1:/etc/rancher/k3s/k3s.yaml dest
        dest="$3"
        mkdir -p "$(dirname "$dest")"
        if [[ ! -w "$(dirname "$dest")" ]]; then
            echo "Permission denied" >&2
            exit 1
        fi
        echo "server: https://127.0.0.1:6443" > "$dest"
        echo "name: default" >> "$dest"
        exit 0
        ;;
esac
EOF
	chmod +x "${MOCK_BIN_DIR}/podman"
}

teardown() {
	rm -rf "${TMP_TEST_DIR}"
}

@test "setup_k3s_ha_podman_Integration_missing_podman_binary_simulated_failure_results_in_expected_error_output_and_exit_code" {
    # Create a restricted bin directory
    local restricted_bin="${TMP_TEST_DIR}/restricted_bin"
    mkdir -p "$restricted_bin"
    
    # Symlink required tools EXCEPT podman
    # We need tools for the script (awk, sed, head, base64, hostname) and basic shell tools
    for tool in awk sed head base64 hostname cat mkdir rm sleep date tr cut dirname realpath bash sh grep; do
        # Prefer our mocks if they exist
        if [[ -f "${MOCK_BIN_DIR}/$tool" ]]; then
            ln -s "${MOCK_BIN_DIR}/$tool" "${restricted_bin}/$tool"
        elif command -v "$tool" >/dev/null; then
            ln -s "$(command -v "$tool")" "${restricted_bin}/$tool"
        fi
    done

    # Run with restricted PATH
	run env PATH="${restricted_bin}" bash "${SCRIPT_UNDER_TEST}"
    
	assert_failure
	assert_output_partial "Required command 'podman' is not installed or not in PATH."
}

@test "setup_k3s_ha_podman_Integration_unwritable_kubeconfig_directory_in_temp_path_causes_script_to_fail_without_affecting_other_files" {
	mkdir -p "${KUBECONFIG_DIR}"
	chmod 000 "${KUBECONFIG_DIR}"

	run env PATH="${MOCK_BIN_DIR}:${PATH}" bash "${SCRIPT_UNDER_TEST}"

	assert_failure
	refute_file_exist "${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml"
	assert_output_partial "Permission denied"
}

@test "setup_k3s_ha_podman_Integration_script_operates_entirely_within_test_temporary_directories_without_modifying_repository_files" {
	run env PATH="${MOCK_BIN_DIR}:${PATH}" bash "${SCRIPT_UNDER_TEST}"

	assert_success
	assert_output_partial "K3s HA cluster setup complete!"

	assert_dir_exist "${DATA_DIR}"
	assert_dir_exist "${KUBECONFIG_DIR}"
	assert_file_exist "${DATA_DIR}/cluster-token"
	assert_file_exist "${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml"

	local kubeconfig_content
	kubeconfig_content=$(cat "${KUBECONFIG_DIR}/k3s-server-1-kubeconfig.yaml")
    
    # Use assert_content_partial to check the file content variable
	assert_content_partial "server: https://${EXTERNAL_IP}:6443" "$kubeconfig_content"
	assert_content_partial "name: ${CLUSTER_NAME}" "$kubeconfig_content"

	# Check for unexpected files
	local unexpected_files
	unexpected_files=$(find "${TMP_TEST_DIR}" -maxdepth 1 -mindepth 1 \
		-not -name "bin" \
		-not -name "k3s-data" \
		-not -name "kubeconfig" \
		-not -name "state" \
		-print)
	assert_empty "${unexpected_files}"
}
