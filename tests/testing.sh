#!/bin/bash

# Constants
CACHE_DIR="${HOME}/.local/share/ghpm/cache"
INSTALL_DIR="${HOME}/.local/bin"
API_URL="https://api.github.com/repos"

# Include utility functions
source ./ghpm.sh

# Main Function
main() {
    local repo="$1"
    local option="$2"
    
    # Validate input
    if ! validate_input "$repo"; then
        echo "Invalid repository format: $repo"
        exit 1
    fi

    echo "Processing repository: $repo"

    # Check cache
    local cache_file="${CACHE_DIR}/api-cache.json"
    local cache_response
    if cache_valid "$repo" "$cache_file"; then
        echo "Using cached response."
        cache_response=$(get_cache "$repo" "$cache_file")
    else
        echo "Fetching from GitHub API..."
        cache_response=$(query_github_api "$repo")
        cache_api_response "$repo" "$cache_response" "$cache_file"
    fi

    # Parse API response
    echo "Processing API response..."
    local latest_version
    local assets
    latest_version=$(extract_version "$cache_response")
    assets=$(extract_assets "$cache_response")

    echo "Latest version: $latest_version"
    echo "Available assets: $assets"

    # Determine the best asset
    echo "Determining best asset for the system..."
    local best_asset
    best_asset=$(determine_best_asset "$assets")

    if [ -z "$best_asset" ]; then
        echo "No suitable assets found for the current system."
        exit 1
    fi

    echo "Best asset: $best_asset"

    # Optionally download and install
    if [ "$option" == "--install" ]; then
        echo "Downloading asset: $best_asset"
        download_asset "$best_asset"
        echo "Installing..."
        install_asset "$best_asset" "$INSTALL_DIR"
    fi

    # Provide debug output for testing API response processing
    echo "DEBUG: Latest version - $latest_version"
    echo "DEBUG: Assets - $assets"
    echo "DEBUG: Best asset - $best_asset"
}

# Call the main function
main "$@"
