#!/usr/bin/env bash

# Import the shared functions from ghpm.sh
source ./ghpm.sh

install_package() {
    local repo_name="$1"
    
    # Fetch and process asset data
    local api_response
    if ! api_response=$(query_github_api "$repo_name"); then
        log "ERROR" "Failed to get API response for $repo_name"
        return 1
    fi

    local processed_data
    if ! processed_data=$(process_asset_data "$api_response"); then
        log "ERROR" "Failed to process asset data for $repo_name"
        return 1
    fi

    asset_url=$(echo "$processed_data" | jq -r '.chosen_asset.url')
    man1_url=($(echo "$processed_data" | jq -r '.man_files[].url // empty'))
    completions_url=($(echo "$processed_data" | jq -r '.completions_files[].url // empty'))
    version=($(echo "$processed_data" | jq -r '.version' ))
    asset_name=$(echo "$processed_data" | jq -r '.chosen_asset.name')

    if [[ -z "$asset_url" ]]; then
        log "ERROR" "No suitable asset found for $repo_name"
        return 1
    fi

    # Prepare files for installation
    get_cache_paths "$repo_name"
    declare -A install_files
    if ! prep_install_files "$processed_data" "$asset_url" "$man1_url" "$completions_url" install_files; then
        log "ERROR" "Failed to prepare installation files"
        return 1
    fi

    # Display installation details
    echo -e "\nRepo: $repo_name"
    echo "Latest version: $version"
    echo "Release asset: $asset_name"
    echo "Files to install:"

    if [[ -n "${install_files[binary]:-}" ]]; then
        local binary_name=$(basename "${install_files[binary]}")
        printf "    %-20s --> %s\n" "$binary_name" "$INSTALL_DIR/$binary_name"
    fi

    # Display man pages (sorted by section)
    for key in "${!install_files[@]}"; do
        if [[ "$key" =~ ^man[1-9]_[0-9]+$ ]]; then
            local section="${key%%_*}"  # Extract "man1" part
            section="${section#man}"    # Extract just the number
            local man_name=$(basename "${install_files[$key]}")
            printf "    %-20s --> %s\n" "$man_name" "$MAN_DIR/man$section/$man_name"
        fi
    done

    # Display shell completions
    for shell in bash zsh fish; do
        local completion_key="${shell}-completions"
        if [[ -n "${install_files[$completion_key]:-}" ]]; then
            local comp_name=$(basename "${install_files[$completion_key]}")
            case "$shell" in
                bash) target_dir="$BASH_COMPLETION_DIR" ;;
                zsh)  target_dir="$ZSH_COMPLETION_DIR" ;;
                fish) target_dir="$FISH_COMPLETION_DIR" ;;
            esac
            printf "    %-20s --> %s\n" "$comp_name" "$target_dir/$comp_name"
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

    # Install binary
    if [[ -n "${install_files[binary]}" ]]; then
        local binary_dest="$INSTALL_DIR/$(basename "${install_files[binary]}")"
        mkdir -p "$INSTALL_DIR"
        if cp "${install_files[binary]}" "$binary_dest" && chmod +x "$binary_dest"; then
            echo "Installed binary: $binary_dest"
        fi
    fi

    # Install man pages (replaces old man page installation section)
    for key in "${!install_files[@]}"; do
        if [[ "$key" =~ ^man[1-9]_[0-9]+$ ]]; then
            local section="${key%%_*}"
            section="${section#man}"
            local man_dest="$MAN_DIR/man$section/$(basename "${install_files[$key]}")"
            mkdir -p "$MAN_DIR/man$section"
            if cp "${install_files[$key]}" "$man_dest"; then
                echo "Installed man page: $man_dest"
            fi
        fi
    done

    # Install completions
    for shell in bash zsh fish; do
        local completion_key="${shell}-completions"
        if [[ -n "${install_files[$completion_key]:-}" ]]; then
            case "$shell" in
                bash) target_dir="$BASH_COMPLETION_DIR" ;;
                zsh)  target_dir="$ZSH_COMPLETION_DIR" ;;
                fish) target_dir="$FISH_COMPLETION_DIR" ;;
            esac
            local completion_dest="$target_dir/$(basename "${install_files[$completion_key]}")"
            mkdir -p "$target_dir"
            if ! cp "${install_files[$completion_key]}" "$completion_dest"; then
                log "ERROR" "Failed to install $shell completion to $completion_dest"
                return 1
            fi
            installed_files+=("$completion_dest")
        fi
    done
    # In install_package() function, after files are installed:
    if [[ ${#installed_files[@]} -gt 0 ]]; then
        db_ops add "$binary_name" "$repo_name" "$version" install_files
    fi

    setup_paths
}

main() {
    local cmd="$1"
    shift

    case "$cmd" in
        "install")
            local repo_name="$1"
            if [[ -z "$repo_name" ]]; then
                echo "Usage: $0 install owner/repo"
                return 1
            fi
            install_package "$repo_name" ;;
        
        "--clear-cache")
            rm -rf $CACHE_DIR ;;

        "--list")
            db_ops list ;;
        
        "--version")
            echo "0.2.5" ;;

        *)
            echo "Usage: $0 <command> [options]"
            echo "Commands:"
            echo "  install <owner/repo>    Install a package from GitHub"
            echo "  --list                  List installed packages"
            echo "  --clear-cache           Clear the cache"
            echo "  --version               Show version"
            return 1 ;;
    esac
}

# Run main function with all arguments if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
