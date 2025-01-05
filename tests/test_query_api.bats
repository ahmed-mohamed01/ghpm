#!/usr/bin/env bats

# Load the script functions to test
load "../ghpm.sh"

# Setup and Teardown
setup() {
    export TEST_CACHE_DIR="/tmp/ghpm_test_cache"
    export TEST_INSTALL_DIR="/tmp/ghpm_test_install"
    mkdir -p "$TEST_CACHE_DIR" "$TEST_INSTALL_DIR"
}

teardown() {
    rm -rf "$TEST_CACHE_DIR" "$TEST_INSTALL_DIR"
}

# Test query_github_api: Input Validation
@test "query_github_api: valid repository format" {
    run query_github_api "owner/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"owner/repo"* ]]
}

@test "query_github_api: valid repository with binary name" {
    run query_github_api "owner/repo | binary_name"
    [ "$status" -eq 0 ]
    [[ "$output" == *"owner/repo"* ]]
    [[ "$output" == *"binary_name"* ]]
}

@test "query_github_api: invalid repository format" {
    run query_github_api "invalidrepo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid repository format"* ]]
}

# Test log function
@test "log: outputs warning messages" {
    run log "warning" "This is a test warning"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: This is a test warning"* ]]
}

@test "log: outputs error messages" {
    run log "error" "This is a test error"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ERROR: This is a test error"* ]]
}
