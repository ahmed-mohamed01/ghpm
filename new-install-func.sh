#!/usr/bin/env bash

# Import the shared functions from ghpm.sh
source ./ghpm.sh

install_package() {
    local repo="$1"
    
    # Fetch and process asset data
    local api_response
    if ! api_response=$(query_github_api "$repo"); then
        log "ERROR" "Failed to get API response for $repo"
        return 1
    fi

    local processed_data
    if ! processed_data=$(process_asset_data "$api_response"); then
        log "ERROR" "Failed to process asset data for $repo"
        return 1
    fi
    # Extract key information
    local version=$(echo "$processed_data" | jq -r '.version | sub("^v"; "")')
    local asset_name=$(echo "$processed_data" | jq -r '.chosen_asset.name')
    local asset_url=$(echo "$processed_data" | jq -r '.chosen_asset.url')

    if [[ -z "$asset_url" ]]; then
        log "ERROR" "No suitable asset found for $repo"
        return 1
    fi

    # Prepare files for installation
    get_cache_paths "$repo"
    readarray -t files_to_install < <(prep_install_files "$processed_data" "$asset_url")
    
    if [[ ${#files_to_install[@]} -eq 0 ]]; then
        log "ERROR" "No files prepared for installation"
        return 1
    fi

    # Display installation details
    echo -e "\nRepo: $repo"
    echo "Latest version: $version"
    echo "Release asset: $asset_name"
    echo "Files to install:"
    
    # Create associative array for file groups
    declare -A file_groups
    
    # Process each file and group by type
    for file in "${files_to_install[@]}"; do
        if [[ -n "$file" ]]; then
            IFS=: read -r source dest type <<< "$file"
            if [[ -n "$type" ]]; then
                file_groups["$type"]+="$dest"$'\n'
            fi
        fi
    done

    # Display binary first
    if [[ -n "${file_groups[binary]:-}" ]]; then
        while IFS= read -r dest; do
            [[ -n "$dest" ]] && printf "    Binary --> %s\n" "$dest"
        done <<< "${file_groups[binary]}"
    fi

    # Display completions
    for shell in fish zsh bash; do
        if [[ -n "${file_groups[$shell]:-}" ]]; then
            while IFS= read -r dest; do
                [[ -n "$dest" ]] && printf "    %s completion --> %s\n" "$shell" "$dest"
            done <<< "${file_groups[$shell]}"
        fi
    done

    # Display man pages
    for type in "${!file_groups[@]}"; do
        if [[ "$type" =~ ^man[1-9]$ ]]; then
            while IFS= read -r dest; do
                [[ -n "$dest" ]] && printf "    %s page --> %s\n" "$type" "$dest"
            done <<< "${file_groups[$type]}"
        fi
    done
    echo

    read -p "Proceed with installation? [y/N]: " -r
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Installation canceled."
        return 1
    fi

    # Install files
    echo "Installing files..."
    local installed_files=()
    for file in "${files_to_install[@]}"; do
        if [[ -n "$file" ]]; then
            IFS=: read -r source dest type <<< "$file"
            if [[ -n "$dest" ]]; then
                mkdir -p "$(dirname "$dest")"
                if ! cp "$source" "$dest"; then
                    log "ERROR" "Failed to install $type file to $dest"
                    return 1
                fi
                [[ "$type" == "binary" ]] && chmod +x "$dest"
                installed_files+=("$dest")
            fi
        fi
    done

    # Update database
    echo "Updating installation database..."
    local db_entry
    db_entry=$(jq -n \
        --arg repo "$repo" \
        --arg version "$version" \
        --arg asset "$asset_name" \
        --argjson files "$(printf '%s\n' "${installed_files[@]}" | jq -R . | jq -s .)" \
        '{
            repo: $repo,
            version: $version,
            asset: $asset,
            install_files: $files,
            install_date: now | strftime("%Y-%m-%d %H:%M:%S")
        }')

    mkdir -p "$(dirname "$DB_FILE")"
    if [[ -f "$DB_FILE" ]]; then
        jq --arg repo "$repo" --argjson entry "$db_entry" \
            'del(.[$repo]) + {($repo): $entry}' "$DB_FILE" > "${DB_FILE}.tmp" && \
        mv "${DB_FILE}.tmp" "$DB_FILE"
    else
        echo "{\"$repo\": $db_entry}" > "$DB_FILE"
    fi

    local binary_name=$(echo "${installed_files[0]}" | xargs basename)
    echo "Installation complete: $binary_name installed to $INSTALL_DIR"
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
        
        "--clear-cache")
            rm -rf $CACHE_DIR ;;
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
