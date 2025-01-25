#! /usr/bin/env bash

# Source the main script
source ./ghpm.sh

# Setup test environment
setup_test_env() {
    TEST_DIR=$(mktemp -d)
    export PWD=$TEST_DIR
    mkdir -p "$TEST_DIR/.local/"{bin,share/ghpm,share/bash-completion/completions,share/zsh/site-functions,config/fish/completions}
}

teardown_test_env() {
    rm -rf "$TEST_DIR"
}

# Helper to compare versions
assert_versions() {
    local current="$1"
    local latest="$2"
    local expected="$3"
    local result

    if [[ "$(echo -e "${current#v}\n${latest#v}" | sort -V | tail -n1)" != "${current#v}" ]]; then
        result="update_available"
    else
        result="up_to_date"
    fi

    if [[ "$result" != "$expected" ]]; then
        echo "FAIL: Version comparison failed"
        echo "Current: $current"
        echo "Latest: $latest"
        echo "Expected: $expected"
        echo "Got: $result"
        return 1
    fi
    return 0
}

# Test validate_input function
test_validate_input() {
    echo "Testing validate_input..."
    
    # Test valid repo format
    if ! output=$(validate_input "repo" "owner/repo"); then
        echo "FAIL: Valid repo format test failed"
        return 1
    fi

    # Test invalid repo format
    if validate_input "repo" "invalid-format" 2>/dev/null; then
        echo "FAIL: Invalid repo format was accepted"
        return 1
    fi

    # Test empty input
    if validate_input "repo" "" 2>/dev/null; then
        echo "FAIL: Empty input was accepted"
        return 1
    fi

    # Test repo with binary name
    if ! output=$(validate_input "repo" "owner/repo|binary"); then
        echo "FAIL: Valid repo with binary format test failed"
        return 1
    fi
    
    echo "validate_input tests passed"
    return 0
}

# Test process_asset_data function
test_process_asset_data() {
    echo "Testing process_asset_data..."
    
    # Mock API response
    local mock_response='{
        "html_url": "https://github.com/owner/repo/releases/tag/v1.0.0",
        "tag_name": "v1.0.0",
        "assets": [
            {
                "name": "linux_amd64.tar.gz",
                "browser_download_url": "https://example.com/linux_amd64.tar.gz"
            },
            {
                "name": "windows.exe",
                "browser_download_url": "https://example.com/windows.exe"
            }
        ]
    }'

    local result=$(process_asset_data "$mock_response")
    
    # Verify result structure
    if ! echo "$result" | jq -e '.repo == "owner/repo"' >/dev/null; then
        echo "FAIL: Incorrect repo in processed data"
        return 1
    fi

    if ! echo "$result" | jq -e '.version == "v1.0.0"' >/dev/null; then
        echo "FAIL: Incorrect version in processed data"
        return 1
    fi

    echo "process_asset_data tests passed"
    return 0
}

# Test cache functionality
test_cache_operations() {
    echo "Testing cache operations..."
    
    # Test cache creation
    local repo="test/repo"
    local mock_data='{
        "tag_name": "v1.0.0",
        "assets": []
    }'
    
    query_github_api "$repo" <<< "$mock_data"
    
    if [[ ! -f "$CACHE_FILE" ]]; then
        echo "FAIL: Cache file not created"
        return 1
    fi

    # Test cache retrieval
    local cached_data=$(query_github_api "$repo")
    if [[ -z "$cached_data" ]]; then
        echo "FAIL: Failed to retrieve cached data"
        return 1
    fi

    echo "cache_operations tests passed"
    return 0
}

# Test database operations
test_db_operations() {
    echo "Testing database operations..."
    
    local binary_name="test_binary"
    local repo_name="test/repo"
    local version="v1.0.0"
    
    # Test add operation
    declare -A test_files=([binary_0]="/test/path/binary")
    declare -A test_types=([binary_0]="binary")
    
    if ! db_ops add "$binary_name" "$repo_name" "$version" test_files test_types; then
        echo "FAIL: Failed to add entry to database"
        return 1
    fi

    # Test get operation
    if ! db_ops get "$binary_name" >/dev/null; then
        echo "FAIL: Failed to retrieve database entry"
        return 1
    fi

    # Test remove operation
    if ! db_ops remove "$binary_name"; then
        echo "FAIL: Failed to remove database entry"
        return 1
    fi

    echo "db_operations tests passed"
    return 0
}

# Test shell completion detection
test_shell_detection() {
    echo "Testing shell detection..."
    
    # Setup mock shell environment
    mkdir -p "$TEST_DIR/home"
    touch "$TEST_DIR/home/.bashrc"
    
    # Test detection
    eval $(detect_installed_shells)
    
    if [[ "${SHELL_STATUS[bash]}" != "1" ]]; then
        echo "FAIL: Bash shell not detected"
        return 1
    fi

    echo "shell_detection tests passed"
    return 0
}

# Run all tests
run_tests() {
    setup_test_env
    
    local failed=0
    
    test_validate_input || ((failed++))
    test_process_asset_data || ((failed++))
    test_cache_operations || ((failed++))
    test_db_operations || ((failed++))
    test_shell_detection || ((failed++))
    
    teardown_test_env
    
    if ((failed > 0)); then
        echo "$failed tests failed"
        return 1
    fi
    echo "All tests passed"
    return 0
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi