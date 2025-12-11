#!/usr/bin/env bats

setup() {
    # 1. Create a temporary environment for the test
    TEST_DIR=$(mktemp -d)
    TEST_BIN="$TEST_DIR/bin"
    # CHANGED: Renamed 'root_fs' to 'mock_fs' to prevent sed from recursively matching '/root'
    TEST_ROOT="$TEST_DIR/mock_fs"
    
    mkdir -p "$TEST_BIN"
    mkdir -p "$TEST_ROOT/usr/local/bin"
    
    # Add our temp bin to PATH so we can mock system commands like 'rm'
    export PATH="$TEST_BIN:$PATH"
    
    # 2. Prepare the script for testing
    cp teardown.sh "$TEST_DIR/teardown_test.sh"
    chmod +x "$TEST_DIR/teardown_test.sh"

    # 3. INJECT TEST SEAMS
    # Bypass the root check
    sed -i 's/exit 1/true/' "$TEST_DIR/teardown_test.sh"
    
    # Redirect absolute paths to our test root
    sed -i "s|/usr/local/bin|$TEST_ROOT/usr/local/bin|g" "$TEST_DIR/teardown_test.sh"
    sed -i "s|/etc|$TEST_ROOT/etc|g" "$TEST_DIR/teardown_test.sh"
    sed -i "s|/var|$TEST_ROOT/var|g" "$TEST_DIR/teardown_test.sh"
    sed -i "s|/opt|$TEST_ROOT/opt|g" "$TEST_DIR/teardown_test.sh"
    sed -i "s|/root|$TEST_ROOT/root|g" "$TEST_DIR/teardown_test.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "Fail if not root (Logic Check)" {
    if [ "$EUID" -eq 0 ]; then
        skip "Test runner is root, cannot verify non-root failure"
    fi

    run ./teardown.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
}

@test "Calls k3s-uninstall.sh if present" {
    UNINSTALLER="$TEST_ROOT/usr/local/bin/k3s-uninstall.sh"
    touch "$UNINSTALLER"
    chmod +x "$UNINSTALLER"
    
    # Mock 'rm' to avoid errors
    echo '#!/bin/bash' > "$TEST_BIN/rm"
    chmod +x "$TEST_BIN/rm"

    run "$TEST_DIR/teardown_test.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Stopping and Uninstalling K3s"* ]]
}

@test "Falls back to k3s-killall.sh if uninstall is missing" {
    rm -f "$TEST_ROOT/usr/local/bin/k3s-uninstall.sh"
    
    KILLALL="$TEST_ROOT/usr/local/bin/k3s-killall.sh"
    touch "$KILLALL"
    chmod +x "$KILLALL"

    # Mock 'rm'
    echo '#!/bin/bash' > "$TEST_BIN/rm"
    chmod +x "$TEST_BIN/rm"

    run "$TEST_DIR/teardown_test.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: "* ]]
    [[ "$output" == *"Attempting to kill k3s processes manually"* ]]
}

@test "Removes all expected data directories" {
    # Mock uninstaller
    touch "$TEST_ROOT/usr/local/bin/k3s-uninstall.sh"
    chmod +x "$TEST_ROOT/usr/local/bin/k3s-uninstall.sh"

    # Mock 'rm' to capture arguments to a log file
    LOG_FILE="$TEST_DIR/rm_log.txt"
    echo '#!/bin/bash' > "$TEST_BIN/rm"
    echo "echo \"\$@\" >> $LOG_FILE" >> "$TEST_BIN/rm"
    chmod +x "$TEST_BIN/rm"

    run "$TEST_DIR/teardown_test.sh"

    [ "$status" -eq 0 ]

    # Verify specific paths were passed to rm
    # We use 'grep -F' (fixed string) and '--' to prevent grep from interpreting '-rf' as flags
    
    grep -Fq -- "-rf $TEST_ROOT/etc/rancher/k3s" "$LOG_FILE"
    grep -Fq -- "-rf $TEST_ROOT/root/.kube" "$LOG_FILE"
    grep -Fq -- "-rf $TEST_ROOT/var/lib/rancher/k3s" "$LOG_FILE"
    grep -Fq -- "-rf $TEST_ROOT/var/lib/kubelet" "$LOG_FILE"
    grep -Fq -- "-rf $TEST_ROOT/etc/cni" "$LOG_FILE"
    grep -Fq -- "-rf $TEST_ROOT/opt/cni" "$LOG_FILE"
}
