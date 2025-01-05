#!/usr/bin/env bash

# Default configuration


# Import the existing scoring and API functions from gpm.sh
source ./ghpm.sh

install_package() {
    local repo="$1"
    local REPO_CACHE_DIR=$(echo "$repo" | sed 's|/|_|g')
    local cache_dir="${ASSET_CACHE_DIR}/${REPO_CACHE_DIR}"
    
    local install_dir="${INSTALL_DIR}"
    local man_dir="${HOME}/.local/share/man"
    local completion_dir="${HOME}/.local/share/bash-completion/completions"
    
    # Ensure directories exist
    mkdir -p "$cache_dir" "$install_dir" "$man_dir" "$completion_dir" "$DB_DIR"

    # 1. Get API response
    local api_response
    if ! api_response=$(query_github_api "$repo"); then
        log "ERROR" "Failed to get API response for $repo"
        return 1
    fi

    # 2. Process and select assets
    local version=$(process_api_response "latest-version" "$api_response")
    local asset_data=$(process_asset_data "$api_response")
    local best_asset=$(echo "$asset_data" | jq -r '.chosen.name')
    local best_url=$(echo "$asset_data" | jq -r '.chosen.url')

    if [[ -z "$best_asset" || "$best_asset" == "null" ]]; then
        log "ERROR" "No suitable asset found for $repo"
        return 1
    fi

    # Display installation preview
    echo
    echo "Repo: $repo"
    echo "Latest version: $version"
    echo "Release asset: $best_asset"
    echo

    # 3. Download asset
    if ! download_asset "$repo" "$best_url" "$asset_path"; then
        log "ERROR" "Failed to download asset"
        rm -rf "$temp_dir"
        return 1
    fi

    # 4. Extract and validate
    local extract_dir="${temp_dir}/extract"
    mkdir -p "$extract_dir"
    
    if ! extract_package "$asset_path" "$extract_dir"; then
        log "ERROR" "Failed to extract package"
        rm -rf "$temp_dir"
        return 1
    fi

    # 5. Find and validate binary
    local binary_path=""
    local binary_name="${repo##*/}"  # Default to repo name
    while IFS= read -r -d '' file; do
        if [[ -x "$file" && -f "$file" ]]; then
            if validate_binary "$file"; then
                binary_path="$file"
                binary_name=$(basename "$file")
                break
            fi
        fi
    done < <(find "$extract_dir" -type f -executable -print0)

    if [[ -z "$binary_path" ]]; then
        log "ERROR" "No valid binary found in package"
        rm -rf "$temp_dir"
        return 1
    fi

    # 6. Show files to be installed
    echo "Files to install:"
    echo "    $binary_name --> $install_dir/$binary_name"
    
    # Check for man pages and completions
    local man_files=$(process_api_response "man-files" "$api_response")
    local completion_files=$(process_api_response "completions" "$api_response")
    
    [[ -n "$man_files" ]] && echo "    man pages --> $man_dir"
    [[ -n "$completion_files" ]] && echo "    completions --> $completion_dir"
    
    echo
    read -p "Proceed to install? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        rm -rf "$temp_dir"
        return 1
    fi

    # 7. Install files
    if ! install -m 755 "$binary_path" "$install_dir/$binary_name"; then
        log "ERROR" "Failed to install binary"
        rm -rf "$temp_dir"
        return 1
    fi

    # 8. Install man pages and completions
    if [[ -n "$man_files" || -n "$completion_files" ]]; then
        install_man_pages_completions "$extract_dir"
    fi

    # 9. Update installation database
    local db_entry=$(jq -n \
        --arg repo "$repo" \
        --arg version "$version" \
        --arg binary "$binary_name" \
        --arg path "$install_dir/$binary_name" \
        '{
            repo: $repo,
            version: $version,
            binary: $binary,
            install_path: $path,
            install_date: now | strftime("%Y-%m-%d %H:%M:%S")
        }')

    if [[ -f "$DB_FILE" ]]; then
        jq --arg repo "$repo" \
           --argjson entry "$db_entry" \
           'del(.[$repo]) + {($repo): $entry}' "$DB_FILE" > "${DB_FILE}.tmp" && \
        mv "${DB_FILE}.tmp" "$DB_FILE"
    else
        echo "{\"$repo\": $db_entry}" > "$DB_FILE"
    fi

    echo "Installation complete: $binary_name installed to $install_dir"
    rm -rf "$temp_dir"
    return 0
}

main() {
    local cmd="$1"
    shift

    case "$cmd" in
        "install")
            local repo="$1"
            if [[ -z "$repo" ]]; then
                echo "Usage: $0 install owner/repo"
                return 1
            fi
            install_package "$repo"
            ;;
        *)
            echo "Usage: $0 install owner/repo"
            return 1
            ;;
    esac
}

# Run main function with all arguments only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi