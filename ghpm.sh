#! /usr/bin/env bash

#set -euo pipefail      # set -e error handling, -u undefined variable protection -o pipefail piepline faulure catching. 
DISPLAY_ISSUES=true    # make log output visible. 

# Configure folders
DATA_DIR="${PWD}/.local/share/ghpm"
INSTALL_DIR="${PWD}/.local/bin"

CACHE_DIR="${DATA_DIR}/cache"
CACHE_FILE="${CACHE_DIR}/api-cache.json"
ASSET_CACHE_DIR="${CACHE_DIR}/repos"

DB_DIR="${DATA_DIR}/db"
DB_FILE="${DB_DIR}/installed.json"

BASH_COMPLETION_DIR="${PWD}/.local/share/bash-completion/completions"
ZSH_COMPLETION_DIR="${PWD}/.local/share/zsh/site-functions"
FISH_COMPLETION_DIR="${PWD}/.config/fish/completions"
MAN_DIR="${PWD}/.local/share/man"

get_cache_paths() {
    local repo_name="$1"
    local repo_dir="$(echo "$repo_name" | sed 's|/|_|g')"
    
    # Base paths for the repo
    REPO_CACHE_DIR="${ASSET_CACHE_DIR}/${repo_dir}"
    REPO_ASSETS_DIR="${REPO_CACHE_DIR}/assets"
    REPO_EXTRACTED_DIR="${REPO_CACHE_DIR}/extracted"
    PROCESSED_CACHE_PATH="${REPO_CACHE_DIR}/processed-${repo_dir}-assets-cache.json"

    # Create the directory structure
    mkdir -p "$REPO_CACHE_DIR" "$REPO_ASSETS_DIR" "$REPO_EXTRACTED_DIR"
}


# Colors to be used in output
declare -a ISSUES=()
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Store important 
declare -g system_arch=$(uname -m)
declare -g os_type=$(uname -s)
declare -g bit_arch=$(getconf LONG_BIT)
declare -g distro=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
declare -g libc_type="unknown"      
    # Detect libc type
if [[ "$os_type" == "Linux" ]]; then
    if ldd --version 2>&1 | grep -qE "musl"; then
        libc_type="musl"
    elif ldd --version 2>&1 | grep -qE "GNU|GLIBC"; then
        libc_type="gnu"
    fi
fi

# Log function will append debeug info to arrays for easier output. 
log() {
    local severity="${1^^}"  # Uppercase severity
    local message="$2"
    ISSUES+=("${severity}:${message}")
    
    if [[ "$DISPLAY_ISSUES" = true ]]; then
        local color
        [[ "$severity" == "WARNING" ]] && color="$YELLOW" || color="$RED"
        printf "${color}%s: %s${NC}\n" "$severity" "$message" >&2
    fi
}

# This will ensure input is valid, check cache to see if it exists, otherwise fetch and cache api_response.
# Output is full output from github api

query_github_api() {
    local input="$1"
    local ttl=36000    # Cache ttl/valid period, set at 600min
    local current_time=$(date +%s)


    # Parse and validate input
    local repo_name
    local binary_name
    if [[ "$input" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$ ]] || [[ "$input" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+\s*\|\s*[a-zA-Z0-9_-]+$ ]]; then
        if [[ "$input" == *"|"* ]]; then
            repo_name=$(echo "$input" | cut -d'|' -f1 | tr -d ' ')
            binary_name=$(echo "$input" | cut -d'|' -f2 | tr -d ' ')
        else
            repo_name="$input"
            binary_name=${repo_name##*/}
        fi
        
        # Verify repo exists with GitHub API
        local test_url="https://api.github.com/repos/$repo_name"
        local repo_check=$(curl -sI "$test_url" | head -n 1 | cut -d' ' -f2)
        
        if [[ "$repo_check" != "200" ]]; then
            log "ERROR" "Repository $repo_name not found or inaccessible"
            return 1
        fi
    else
        log "ERROR" "Invalid format. Use 'owner/repo' or 'owner/repo | alias'"
        return 1
    fi

    # Create cache dir
    mkdir -p "$CACHE_DIR"

    # Validate cache
    if [[ -f "$CACHE_FILE" ]]; then
        local repo_cached_data
        # Use -r to get raw output and check if it's null
        repo_cached_data=$(jq -r --arg repo "$repo_name" 'if has($repo) then .[$repo] else "null" end' "$CACHE_FILE" 2>/dev/null)

        if [[ "$repo_cached_data" != "null" && -n "$repo_cached_data" ]]; then
            # If repo entry exists, proceed to check ttl
            local cache_timestamp
            cache_timestamp=$(echo "$repo_cached_data" | jq -r '.timestamp')

            # Check TTL
            if (( current_time - cache_timestamp < ttl )); then
                # Extract the 'data' field to pass to response processing
                echo "$repo_cached_data" | jq -c '.data | . + {_source: "cache"}'
                return 0
            else
                log "WARNING" "Cache expired for $repo_name. Refreshing..." >&2
            fi
        else
            log "WARNING" "No cache entry found for $repo_name"
        fi
    else
        log "WARNING" "Cache file not found, creating a new file at $CACHE_FILE"
    fi

    # Fetch from GitHub API
    local api_url="https://api.github.com/repos/$repo_name/releases/latest"
    local auth_header=""
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth_header="Authorization: token $GITHUB_TOKEN"

    local http_code
    local api_response
    if [[ -n "$auth_header" ]]; then
        http_code=$(curl -sI -H "$auth_header" -H "Accept: application/vnd.github.v3+json" "$api_url" | head -n1 | cut -d' ' -f2)
        [[ "$http_code" == "200" ]] && api_response=$(curl -sS -H "$auth_header" -H "Accept: application/vnd.github.v3+json" "$api_url")
    else
        http_code=$(curl -sI -H "Accept: application/vnd.github.v3+json" "$api_url" | head -n1 | cut -d' ' -f2)
        [[ "$http_code" == "200" ]] && api_response=$(curl -sS -H "Accept: application/vnd.github.v3+json" "$api_url")
    fi
    
    case $http_code in
        200)
            # Verify we got valid JSON 
            if ! echo "$api_response" | jq empty 2>/dev/null; then
                log "ERROR" "Invalid JSON response from GitHub API"
                return 1
            fi

            api_response=$(echo "$api_response" | jq '. + {_source: "github"}')   # add source info
            
            # Cache the response with a timestamp
            local new_cache_data
            new_cache_data=$(jq -n --argjson data "$api_response" --arg time "$current_time" \
                '{timestamp: $time | tonumber, data: $data}')
            if [[ -f "$CACHE_FILE" ]]; then
                jq --arg repo "$repo_name" --argjson new_data "$new_cache_data" \
                   '.[$repo] = $new_data' "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
            else
                jq -n --arg repo "$repo_name" --argjson new_data "$new_cache_data" \
                   '{($repo): $new_data}' > "$CACHE_FILE"
            fi
            echo "$api_response"
            ;;
        401) log "ERROR" "Authentication failed for $repo_name. Check GITHUB_TOKEN."; return 1 ;;
        403) log "ERROR" "Rate limit exceeded or access forbidden for $repo_name."; return 1 ;;
        404) log "ERROR" "Repository $repo_name not found."; return 1 ;;
        *) log "ERROR" "GitHub API request failed with status $http_code."; return 1 ;;
    esac
    
}

# TODO: Add caching. 
process_asset_data() {
    local api_response="$1"

    # 1. Extract repo and version from API response and construct cache path
    local repo version
    if ! read -r repo version < <(echo "$api_response" | jq -r '
        .html_url as $html | $html | capture("github\\.com/(?<repo>[^/]+/[^/]+)/releases/tag/(?<version>[^/]+)") |
        "\(.repo)\t\(.version)"
    '); then
        log "ERROR" "Failed to extract repo and version from API response"
        return 1
    fi
    # set the cache path
    get_cache_paths "$repo"
    local cache_file="$PROCESSED_CACHE_PATH"

    # 2. Check if valid cache exists and matches current request
    if [[ -f "$cache_file" ]]; then
        if cached_data=$(jq -r --arg repo "$repo" --arg version "$version" \
            'select(.repo == $repo and .version == $version)' "$cache_file" 2>/dev/null) && \
            [[ "$cached_data" != "null" ]] && [[ -n "$cached_data" ]]; then
            echo "$cached_data"
            return 0
        fi
    fi
    

    # 3. If no cache matches, process the repo and output a json. 
    local chosen_asset=""
    local chosen_score=0
    local chosen_reason=""
    declare -a viable_assets=()
    declare -a source_files=()
    declare -a excluded_assets=()
    declare -a man_files=()
    declare -a completions_files=()

    local -A EXCLUDED_PATTERNS=(
    ["x86_64"]="[Aa]arch64|[Aa]rm64|[Aa]rmv[0-9]|i386|[Dd]arwin|[Mm]ac[Oo][Ss]|[Oo][Ss][Xx]|[Ww]in(dows|[0-9]{2})|[Aa]ndroid|\
        [Ff]ree[Bb][Ss][Dd]|[Oo]pen[Bb][Ss][Dd]|[Nn]et[Bb][Ss][Dd]|[Dd]ragon[Ff]ly|[Bb][Ss][Dd]|checksums?|sha256|sha512|sig|\
        asc|deb|rpm|\.(zip|xz|tbz|deb|rpm|apk|msi|pkg|exe)$|[Gg]nu[Ee][Aa][Bb][Ii][Hh][Ff]|[Mm]usl[Ee][Aa][Bb][Ii][Hh][Ff]|\
        [Pp][Pp][Cc]|[Pp][Pp][Cc]64|[Rr][Ii][Ss][Cc][Vv]|[Ss]390[Xx]|[Mm]ips|[Mm]ips64"

    ["aarch64"]="[Xx]86[-_]64|[Aa][Mm][Dd]64|i386|i686|[Dd]arwin|[Mm]ac[Oo][Ss]|[Oo][Ss][Xx]|[Ww]in(dows|[0-9]{2})|[Aa]ndroid|\
        [Ff]ree[Bb][Ss][Dd]|[Oo]pen[Bb][Ss][Dd]|[Nn]et[Bb][Ss][Dd]|[Dd]ragon[Ff]ly|[Bb][Ss][Dd]|checksums?|sha256|sha512|sig|\
        asc|deb|rpm|\.(zip|xz|tbz|deb|rpm|apk|msi|pkg|exe)$|[Gg]nu[Ee][Aa][Bb][Ii][Hh][Ff]|[Mm]usl[Ee][Aa][Bb][Ii][Hh][Ff]|\
        [Pp][Pp][Cc]|[Pp][Pp][Cc]64|[Rr][Ii][Ss][Cc][Vv]|[Ss]390[Xx]|[Mm]ips|[Mm]ips64"
    )

    while IFS= read -r asset_info; do
        name=$(echo "$asset_info" | jq -r '.name')
        url=$(echo "$asset_info" | jq -r '.url')

        if [[ "$name" =~ ${EXCLUDED_PATTERNS[$system_arch]} ]]; then
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"excluded pattern\",\"url\":\"$url\"}")
            continue    
        elif [[ "$name" =~ [Ss]ource([._-]?)[Cc]ode|[Ss]ource([._-]?[Ff]iles?)?|[Ss]ource\.(tar\.gz|tgz|zip)$ ]]; then
            source_files+=("{\"name\":\"$name\",\"url\":\"$url\"}")
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"source code archive\",\"url\":\"$url\"}")
            continue
        elif [[ "$name" =~ ^(completions|auto[-_]complete)[^/]*\.(tar\.gz|tgz)$ ]]; then
            completions_files+=("{\"name\":\"$name\",\"url\":\"$url\"}")
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"completions files\",\"url\":\"$url\"}")
        elif [[ "$name" =~ ^(man(page|-[0-9]+(\.[0-9]+)*)|[^/]+_man_page[^/]*)\.(tar\.gz|tgz)$  ]]; then
            man_files+=("{\"name\":\"$name\",\"url\":\"$url\"}")
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"man files\",\"url\":\"$url\"}")
        else
            local reason=""
            local score=0
            
            [[ "$name" =~ \.(tar\.gz)$ ]] && ((score+=15)) && reason+="tar.gz file (+15); "    
            [[ "$name" =~ \.(tgz)$ ]] && ((score+=5)) && reason+="tgz file (+5); "      
            [[ "$name" =~ \.(zip)$ ]] && ((score+=5)) && reason+="zip file (+5); "    
            [[ "$name" =~ [Ll]inux ]] && ((score+=10 )) && reason+="contains -linux (+10); "      
            [[ "$name" =~ [uU]nknown[-_.][Ll]inux ]] && ((score+=20)) && reason+="unknown-linux (+20); "     

            [[ "$system_arch" =~ (x86_64|amd64) && "$name" =~ (x86[-_.]64|amd64) ]] && ((score+=30)) && reason+="x64 architecture (+30); "       
            [[ "$system_arch" =~ (aarch64|arm64) && "$name" =~ (aarch64|arm64) ]] && ((score+=30)) && reason+="arm64 architecture (+30); "       
            [[ "$bit_arch" =~ 32 && "$name" =~ [Ll]inux32 ]] && ((score+=10)) && reason+="linux32 on 32bit architecture (+10); "        
            [[ "$bit_arch" =~ 64 && "$name" =~ [Ll]inux64 ]] && ((score+=10)) && reason+="linux64 on 64bit architecture (+10); "        
            
            [[ "$name" =~ static ]] && ((score+=25)) && reason+="static binary (+25); "     

            [[ "$libc_type" == "musl" && "$name" =~ musl ]] && ((score+=30)) && reason+="musl matched on a $libc_type system (+30); "
            [[ "$libc_type" == "gnu" && "$name" =~ musl ]] && ((score-=30)) && reason+="musl matched on a $libc_type system (-30); "      
            [[ "$libc_type" == "gnu" && "$name" =~ gnu ]] && ((score+=30)) && reason+="gnu matched on a $libc_type system (+30); "

            [[ "$distro" == "debian" && "$name" =~ debian ]] && ((score+=25)) && reason+="debian matched on $distro (+25); "
            [[ "$distro" == "ubuntu" && "$name" =~ ubuntu ]] && ((score+=25)) && reason+="ubuntu matched on $distro (+25); "
            [[ "$distro" == "fedora" && "$name" =~ fedora ]] && ((score+=25)) && reason+="fedora matched on $distro (+25); "

            local asset_json="{\"name\":\"$name\",\"score\":$score,\"reason\":\"${reason%%; }\",\"url\":\"$url\"}"
            viable_assets+=("$asset_json")
            
            if [[ $score -gt $chosen_score ]]; then
                chosen_asset="$asset_json"
                chosen_score=$score
                chosen_reason="$reason"
            fi
        fi
    done < <(echo "$api_response" | jq -r '.assets[] | {name: .name, url: .browser_download_url} | @json')

    # Construct the final JSON with proper formatting
    # Set existence flags
    local has_manfiles=false
    local has_completions=false
    local has_source=false
    [[ ${#man_files[@]} -gt 0 ]] && has_manfiles=true
    [[ ${#completions_files[@]} -gt 0 ]] && has_completions=true
    [[ ${#source_files[@]} -gt 0 ]] && has_source=true

    local final_json
    final_json=$(echo "{
        \"repo\": \"${repo}\",
        \"version\": \"${version}\",
        \"chosen_asset\": ${chosen_asset:-null},
        \"viable_assets\": [$(IFS=,; echo "${viable_assets[*]:-}")],
        \"excluded_assets\": [$(IFS=,; echo "${excluded_assets[*]:-}")],
        \"source_files\": [$(IFS=,; echo "${source_files[*]:-}")],
        \"has_man_files\": ${has_manfiles},
        \"has_completions_files\": ${has_completions},
        \"has_source_files\": ${has_source},
        \"man_files\": [$(IFS=,; echo "${man_files[*]:-}")],
        \"completions_files\": [$(IFS=,; echo "${completions_files[*]:-}")]
    }" | jq '.')

    # 4. Save processed data to cache 
    if [[ -n "$final_json" ]]; then
        if ! { echo "$final_json" > "${cache_file}.tmp" && mv "${cache_file}.tmp" "$cache_file"; }; then
            log "WARNING" "Failed to write or move cache file"
            rm -f "${cache_file}.tmp"  # Clean up temp file
            return 1
        fi
        echo "$final_json"
        return 0
    else
        log "WARNING" "Failed to generate valid JSON output"
        return 1
    fi
}

process_api_response() {
    local operation="$1"
    local api_response="$2"
    local extra_arg="${3:-}"

    # Ensure a valid json is provided 
    if [[ -z "$api_response" || ! "$api_response" =~ ^\{ ]]; then
        log "ERROR" "Invalid or empty JSON response"
        return 1
    fi

    case "$operation" in

        "latest-version") 
            echo "$api_response" | jq -r '.tag_name | sub("^v"; "")' ;;
        
        "asset-names")
            echo "$api_response" | jq -r '.assets[].name' ;;

        "download-url")
            [[ -z "$extra_arg" ]] && { log "ERROR" "You need to provde the name of the asset"; return 1; } 
            echo "$api_response" | jq -r --arg name "$extra_arg" '.assets[] | select(.name == $name) | .browser_download_url' ;; 

        "asset-info")
            [[ -z "$extra_arg" ]] && { log "ERROR" "You need to provde the name of the asset"; return 1; }
            echo "$api_response" | jq -r --arg name "$extra_arg" '.assets[] | select(.name == $name) | {name, size, download_count, created_at, updated_at, url: .browser_download_url}' ;;

        "choose-best-asset")
            process_asset_data "$api_response" | jq -r '.chosen.name' ;;
        
        "viable-assets")
            process_asset_data "$api_response" | jq -r '.viable[] | "\(.score)\t\(.name)\t\(.url)"' | sort -rn ;;

        "chosen-asset-url")
            process_asset_data "$api_response" | jq -r '.chosen.url' ;;

        "next-best-asset")
            [[ -z "$extra_arg" ]] && { log "ERROR" "Current asset name required"; return 1; }
            process_asset_data "$api_response" | jq -r --arg current "$extra_arg" '
            .viable[] | fromjson | .name |
            select(. != $current) | first' ;;
            
        "completions")
            process_asset_data "$api_response" | jq -r '
                if (.completions | length) == 0 then
                    empty
                else 
                    .completions[] | "\(.name)\t\(.url)"
                end' ;;
        
        "man-files")
            process_asset_data "$api_response" | jq -r '
                if (.man | length) == 0 then
                    empty
                else 
                    .man[] | "\(.name)\t\(.url)"
                end' ;;

        *)
            log "ERROR" "Unknown operation $operation" 
            return 1 ;;
    esac
}

download_asset() {
    local repo_name="$1"
    local asset_input="$2"
    get_cache_paths "$repo_name"

    local asset_name
    # Determine asset name first
    if [[ "$asset_input" =~ ^https?:// ]]; then
        asset_name=$(basename "$asset_input")
    else
        asset_name="$asset_input"
    fi

    # Check cache first - before any other processing
    local cached_asset="${REPO_ASSETS_DIR}/${asset_name}"
    local metadata_file="${cached_asset}.metadata"

    if [[ -f "$cached_asset" && -f "$metadata_file" ]]; then
        local cached_url cached_hash current_hash
        cached_url=$(jq -r '.url' "$metadata_file")
        cached_hash=$(jq -r '.hash' "$metadata_file")
        current_hash=$(sha256sum "$cached_asset" | awk '{print $1}')
        
        if [[ -n "$cached_url" && -n "$cached_hash" && "$current_hash" == "$cached_hash" ]]; then
                #log "INFO" "Using cached asset: $cached_asset"
                echo "$cached_asset"  # Return path to cached asset
                return 0
            fi
    fi
    

    # If we get here, we need to get/verify the URL and download
    local asset_url
    if [[ "$asset_input" =~ ^https?:// ]]; then
        asset_url="$asset_input"
    else
        # Find URL from processed assets cache
        if [[ ! -f "$PROCESSED_CACHE_PATH" ]]; then
            log "WARNING" "No processed assets cache found for ${repo_name}. fetching from github api.."
            if ! process_asset_data "$(query_github_api "$repo_name")"; then
                log "ERROR" "Failed to process asset data"
                return 1
            fi
        fi
        
        # Extract URL for the given filename
        asset_url=$(jq -r --arg name "$asset_input" '.viable_assets[] | select(.name == $name) | .url' "$PROCESSED_CACHE_PATH")
        if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
            log "ERROR" "Asset ${asset_input} not found in processed cache"
            return 1
        fi
    fi

    # Download the asset
    log "INFO" "Downloading asset: $asset_url"
    if ! curl -sSL -o "${cached_asset}.tmp" "$asset_url"; then
        rm -f "${cached_asset}.tmp"
        log "ERROR" "Failed to download asset"
        return 1
    fi

    # Create metadata
    local hash=$(sha256sum "${cached_asset}.tmp" | awk '{print $1}')
    local date_created=$(date -Iseconds)
    if ! jq -n \
            --arg url "$asset_url" \
            --arg hash "$hash" \
            --arg date_created "$date_created" \
            '{url: $url, hash: $hash, date_created: $date_created}' > "${metadata_file}.tmp"; then
        rm -f "${cached_asset}.tmp" "${metadata_file}.tmp"
        log "ERROR" "Failed to create metadata"
        return 1
    fi

    # Move files to final location
    if ! { mv "${cached_asset}.tmp" "$cached_asset" && mv "${metadata_file}.tmp" "$metadata_file"; }; then
        rm -f "${cached_asset}.tmp" "${metadata_file}.tmp" "$cached_asset" "$metadata_file"
        log "ERROR" "Failed to move files to final location"
        return 1
    fi

    log "INFO" "Downloaded and cached: $cached_asset"
    echo "$cached_asset"  # Return path to downloaded asset
    return 0
}

extract_package() {
    local package_archive="$1"
    local extract_dir="$2"

    # Check if archive exists
    if [[ ! -f "$package_archive" ]]; then
        echo "Error: Package archive does not exist: $package_archive" >&2
        return 1
    fi

    # Create extraction directory if it doesn't exist
    mkdir -p "$extract_dir"

    # Determine archive type and extract
    local extract_cmd
    case "$package_archive" in
        *.tar.gz|*.tgz) extract_cmd="tar -xzf" ;;
        *.zip) extract_cmd="unzip -q" ;;
        *) echo "Error: Unsupported archive type for $package_archive" >&2; return 1 ;;
    esac

    # Perform extraction with detailed error logging
    if ! $extract_cmd "$package_archive" -C "$extract_dir"; then
        echo "Error: Failed to extract $package_archive" >&2
        return 1
    fi

    #echo "$extract_dir"
    return 0
}

validate_binary() {
    local given_path="$1"
    local dependencies=()

    # Find the executable
    local binary_path
    binary_path=$(find "$given_path" -type f -executable -print -quit)
    if [[ -z "$binary_path" ]]; then
        log "ERROR" "No executable binary found"
        return 1
    fi

    declare -A FILE_PATTERNS=(
        [x86_64]="ELF|x86[-_ ]64|LSB" 
        [aarch64]="ELF|*aarch64.*LSB.*"
    )

    # Verify executable is actually a binary
    local file_info
    file_info=$(file -b "$binary_path")
    if [[ ! "$file_info" =~ ${FILE_PATTERNS[$system_arch]} ]]; then
        log "ERROR" "Incompatible binary. Expected pattern: ${FILE_PATTERNS[$system_arch]} but got: $file_info"
        return 1
    fi
    # Check dependencies if dynamically linked
    if ldd "$binary_path" &>/dev/null; then
        local missing_deps
        missing_deps=$(ldd "$binary_path" | grep "not found")
        if [[ -n "$missing_deps" ]]; then
            log "ERROR" "Missing dependencies for $binary_path:\n$missing_deps"
            return 1
        fi
        # Collect dependencies
        dependencies=($(ldd "$binary_path" | awk '/=>/ {print $3}' | sort -u))
        export DEPENDENCIES=("${dependencies[@]}")
    else
        log "INFO" "Binary is statically linked or does not require dynamic dependencies."
    fi

    echo "$binary_path"
    return 0
}

get_dependencies() {
    local binary_path="$1"
    
    # Check if ldd is available
    if command -v ldd &> /dev/null; then
        local deps=$(ldd "$binary_path" 2>/dev/null | grep "=>" | awk '{print $1}')
        echo "$deps"
        return 0
    fi
    
    echo "Warning: ldd not available to check dependencies" >&2
    return 1
}

prep_install_files() {
    local processed_json="$1"
    local main_url="$2"
    local man_url="$3"      # Optional
    local completions_url="$4"   # Optional
    local -n return_files=$5  # nameref for returning the associative array

    # Download and process main asset (required)
    log "DEBUG" "Processing main asset: $main_url"
    local downloaded_asset
    if ! downloaded_asset=$(download_asset "$repo_name" "$main_url") || \
       ! extract_package "$downloaded_asset" "$REPO_EXTRACTED_DIR" || \
       ! local binary_path=$(validate_binary "$REPO_EXTRACTED_DIR"); then
        log "ERROR" "Binary validation failed for $main_url"
        return 1
    fi
    return_files[binary]="$binary_path"

    # Download and process man file if URL provided
    if [[ -n "$man_url" ]]; then
        log "DEBUG" "Processing man file: $man_url"
        local man_file
        if man_file=$(download_asset "$repo_name" "$man_url"); then
            extract_package "$man_file" "$REPO_EXTRACTED_DIR"
            log "DEBUG" "Extracted man file to $REPO_EXTRACTED_DIR"
        else
            log "WARNING" "Failed to download man file from $man_url"
        fi
    fi

    # Download and process completions if URL provided
    if [[ -n "$completions_url" ]]; then
        log "DEBUG" "Processing completions: $completions_url"
        local completions_file
        if completions_file=$(download_asset "$repo_name" "$completions_url"); then
            extract_package "$completions_file" "$REPO_EXTRACTED_DIR"
            log "DEBUG" "Extracted completions to $REPO_EXTRACTED_DIR"
        else
            log "WARNING" "Failed to download completions from $completions_url"
        fi
    fi

    # Search extracted directory for installable files
    # This happens regardless of whether auxiliary files were downloaded
    # as they might be bundled with the main asset
    local man_page_counter=0
    log "DEBUG" "Searching $REPO_EXTRACTED_DIR for installable files"
    while IFS= read -r file; do
        case "$file" in
            *.1|*.2|*.3|*.4|*.5|*.6|*.7|*.8|*.9)
                local section=${file##*.}
                return_files["man${section}_${man_page_counter}"]="$file"
                ((man_page_counter++))
                log "DEBUG" "Found man page (section $section): $file" ;;
            */bash-completion/*|*.bash)
                return_files[bash-completions]="$file"
                log "DEBUG" "Found bash completion: $file" ;;
            */zsh-completion/*|*/_*)
                return_files[zsh-completions]="$file"
                log "DEBUG" "Found zsh completion: $file" ;;
            *.fish|*/fish-completion/*)
                return_files[fish-completions]="$file"
                log "DEBUG" "Found fish completion: $file" ;;
        esac
    done < <(find "$REPO_EXTRACTED_DIR" -type f)

    # Return success
    return 0
    # Output is an associative array 
    # # install_files=(
    #     [binary]="path/to/extracted/eza"
    #     [man1]="path/to/extracted/eza.1"
    #     [bash-completions]="path/to/extracted/eza.bash"   )

}

## ---- for use in --file mode ----- ##### 
clean_version() {
    local version="$1"
    # Remove 'v' prefix, any trailing non-numeric characters, and Ubuntu-specific suffixes
    echo "$version" | sed -E 's/^v//; s/-[^-]*ubuntu[^-]*//; s/-$//; s/[^0-9.]//g'
}

# TODO: Improve caching. 
compare_versions() {
    local input="$1"
    local binary_name
    local gh_version="$2"
    local cache_dir="${CACHE_DIR}/repos/${repo}"
    local apt_version

    if [[ "$input" == *"|"* ]]; then    # if input contails a | this is parsed differently. 
        repo_name=$(echo "$input" | cut -d'|' -f1 | tr -d ' ')
        binary_name=$(echo "$input" | cut -d'|' -f2 | tr -d ' ')
    else
        repo_name="$input"
        binary_name=${repo_name##*/}
    fi

    local comparison
    gh_version=$(clean_version "$gh_version")
    apt_version=$(apt-cache policy "$binary_name" 2>/dev/null | grep -oP 'Candidate: \K[^ ]+' | head -n1)
    apt_version=$(clean_version "$apt_version")
    if [ -z "$apt_version" ]; then
        echo "github"
        return 0
    elif [ -z "$gh_version" ]; then
        echo "apt"
    elif [ "$(printf '%s\n' "$gh_version" "$apt_version" | sort -V | head -n1)" = "$gh_version" ]; then
            if [ "$gh_version" = "$apt_version" ]; then
                echo "equal"
            else
                echo "apt"  # GitHub version is lower, so apt has the newer version
            fi
    else
        echo "github"  # GitHub has the newer version
    fi

    # Update cache with version info
    jq --arg apt "$apt_version" \
       --arg gh "$gh_version" \
       --arg comp "$comparison" \
       --arg time "$(date +%s)" \
       '. + {
           version_info: {
               github: $gh
               apt: $apt,
               comparison: $comp,
               check_time: ($time | tonumber)
           }
       }' "$processed_cache" > "${processed_cache}.tmp" && \
    mv "${processed_cache}.tmp" "$processed_cache"
    echo "$comparison"
    return 0
}

main() {
    local repo_name="$1"

    if ! api_response=$(query_github_api "$repo_name"); then
        log "ERROR" "Unable to fetch response"
        return 1
    fi
    # Get version directly from api_response (this doesn't need asset processing)
    latest_version=$(echo "$api_response" | jq -r '.tag_name | sub("^v"; "")')
    local repo version
    #read -r repo version < <(echo "$api_response" | jq -r '[.url | split("/")[4:6] | join("/"), .tag_name] | @tsv')
    
    #Process assets once
    local asset_data=$(process_asset_data "$api_response")
    
    # Extract everything we need from the single processed result
    local best_asset=$(echo "$asset_data" | jq -r '.chosen_asset.name')
    local best_asset_url=$(echo "$asset_data" | jq -r '.chosen_asset.url')
    local completions=$(echo "$asset_data" | jq -r '
        if (.completions_files | length) == 0 then
            "not found"
        else
            .completions_files[].url
        end')
    local response_source=$(echo "$api_response" | jq -r '._source')
    local asset_list=$(echo "$api_response" | jq -r '.assets[].name')

    # Download a file
    if ! downloaded_asset=$(download_asset "$repo_name" "$best_asset_url"); then
        log "ERROR" "Failed to download asset"
        return 1
    fi
    get_cache_paths "$repo_name"
    # Extract the downloaded asset to the repo's extraction directory
    if ! extract_package "$downloaded_asset" "$REPO_EXTRACTED_DIR"; then
        log "ERROR" "Failed to extract package"
        return 1
    fi
    
    if validate_binary "$REPO_EXTRACTED_DIR"; then
        local validation="PASSED"
    fi



    # Print summary
    echo "Repo: $repo_name (Source: $response_source)"
    echo "Latest version: $latest_version"
    echo "Best asset: $best_asset"
    echo "Best asset is at: $best_asset_url"
    echo "Completions URL: $completions"
    echo "Name: $asset_list"
    #echo "$asset_data" | jq .
    #echo "$api_response" | jq .
    #echo "Testing version: $version"
    echo "Validation: $validation"

    

}

# Run main function with all arguments only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
