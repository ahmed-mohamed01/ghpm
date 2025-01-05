#!/usr/bin/env bash

# Import the shared functions from ghpm.sh
source ./ghpm.sh

# Install a package from a GitHub repository
install_package() {
    local repo="$1"
    local repo_cache_dir="$(echo "$repo" | sed 's|/|_|g')"
    local cache_dir="${ASSET_CACHE_DIR}/${repo_cache_dir}"

    local install_dir="${INSTALL_DIR}"
    local man_dir="${HOME}/.local/share/man"
    local completion_dir="${HOME}/.local/share/bash-completion/completions"

    # Ensure necessary directories exist
    
    get_cache_paths "$repo"

    # Fetch API response
    local api_response
    if ! api_response=$(query_github_api "$repo"); then
        log "ERROR" "Failed to get API response for $repo"
        return 1
    fi

    # Process and select assets
    local version=$(process_api_response "latest-version" "$api_response")
    local asset_data=$(process_asset_data "$api_response")
    local best_asset=$(echo "$asset_data" | jq -r '.chosen_asset.name' )
    local best_url=$(echo "$asset_data" | jq -r '.chosen_asset.url')
    #echo "Best URL: $best_url"

    if [[ -z "$best_url" || "$best_url" == "null" ]]; then
        log "ERROR" "No suitable asset found for $repo"
        return 1
    fi

    # Find and validate binary
    downloaded_asset=$(download_asset "$repo" "$best_url")
    extract_dir=${REPO_EXTRACTED_DIR}
    extract_package "$downloaded_asset" "$extract_dir"
    

    local binary_path
    if ! binary_path=$(validate_binary "$extract_dir"); then
        log "ERROR" "Binary validation failed"
        return 1
    fi

    local binary_name=$(basename "$binary_path")

    # Display installation details
    echo -e "\nRepo: $repo"
    echo "Latest version: $version"
    echo "Release asset: $best_asset"
    echo
    echo "Files to install:"
    echo "    $binary_name  --> $install_dir/$binary_name"

    # Check for man pages and completions
    local man_files=$(echo "$asset_data" | jq -r '.man_files | join("\n")')
    local completion_files=$(echo "$asset_data" | jq -r '.completions_files | join("\n")')
    local installed_files=()

    [[ -n "$man_files" ]] && echo "    man-1 --> $man_dir/man1/${binary_name}.1"
    [[ -n "$completion_files" ]] && echo "    completions --> $completion_dir/${binary_name}"

    echo
    read -p "Proceed to install? [y/N]: " -r
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Installation canceled."
        return 1
    fi

    # Install binary
    echo "Installing binary: $binary_name --> $install_dir/$binary_name"
    if ! cp "$binary_path" "$install_dir/$binary_name"; then
        log "ERROR" "Failed to install binary"
        return 1
    fi
    installed_files+=("$install_dir/$binary_name")

    # Install man pages and completions (if applicable)
    if [[ -n "$man_files" || -n "$completion_files" ]]; then
        echo "Installing auxiliary files..."
        while IFS= read -r file; do
            if [[ "$file" == *.1 ]]; then
                cp "$file" "$man_dir/man1/${binary_name}.1"
                installed_files+=("$man_dir/man1/${binary_name}.1")
            elif [[ "$file" == *completion* ]]; then
                cp "$file" "$completion_dir/${binary_name}"
                installed_files+=("$completion_dir/${binary_name}")
            fi
        done <<< "$man_files
$completion_files"
    fi

    # Update database
    echo "Updating installation database..."
    local db_entry
    db_entry=$(jq -n \
        --arg repo "$repo" \
        --arg version "$version" \
        --argjson chosen_asset "$chosen_asset" \
        --argjson files "$(printf '%s\n' "${installed_files[@]}" | jq -R . | jq -s .)" \
        '{
            repo: $repo,
            version: $version,
            chosen_asset: $chosen_asset,
            install_files: $files,
            install_date: now | strftime("%Y-%m-%d %H:%M:%S")
        }')

    if [[ -f "$DB_FILE" ]]; then
        jq --arg repo "$repo" --argjson entry "$db_entry" 'del(.[$repo]) + {($repo): $entry}' "$DB_FILE" > "${DB_FILE}.tmp" && \
        mv "${DB_FILE}.tmp" "$DB_FILE"
    else
        echo "{\"$repo\": $db_entry}" > "$DB_FILE"
    fi

    echo "Installation complete: $binary_name installed to $install_dir"
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

# Run main function with all arguments if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
