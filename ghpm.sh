#! /usr/bin/env bash

set -uo pipefail      # set -e error handling, -u undefined variable protection -o pipefail piepline faulure catching. 
DISPLAY_ISSUES=true # make log output visible. 

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
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

# Declare SHELL_STATUS as global associative array
declare -A SHELL_STATUS=([bash]=0 [zsh]=0 [fish]=0)

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

# Log function will append debeug info to arrays for easier output, display can be toggled with DISPLAY_ISSUES=true
log() {
    local severity="" message="" mode=""

    # Handle different argument patterns
    if [[ "${1^^}" == "QUIET" ]]; then  # We already convert to uppercase
        mode="quiet" && severity="${2^^}" && message="$3"
    else
        severity="${1^^}" && message="$2"
    fi

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local LOG_DIR="${PWD}/.local/share/ghpm/logs"
    local LOG_FILE="$LOG_DIR/ghpm.log"
    mkdir -p "$LOG_DIR"

    # Add to ISSUES array for summary
    ISSUES+=("${severity}:${message}")
    
    # Log to file
    echo "[$timestamp] ${severity}: ${message}" >> "$LOG_FILE"
    
    # Log to console if display is enabled
    if [[ "$DISPLAY_ISSUES" = true && "$mode" != "quiet" ]]; then
        local color
        case "$severity" in
            "ERROR") color="$RED" ;;
            "INFO") color="$GREEN" ;;
            "DEBUG") color="$YELLOW" ;;
            *) color="$NC" ;;
        esac
        printf "${color}%s: %s${NC}\n" "$severity" "$message" >&2
    fi
}

validate_input() {
    local type="$1"    # 'repo' or 'binary'
    local input="$2"
    
    case "$type" in
        "repo")
            # Check if input is empty
            if [[ -z "$input" ]]; then
                echo "Error: Missing repository name. Usage: ghpm install owner/repo" >&2
                return 1
            fi

            local repo_name binary_name
            # Check and split on pipe if present
            if [[ "$input" == *"|"* ]]; then
                repo_name=$(echo "$input" | cut -d'|' -f1 | tr -d ' ')
                binary_name=$(echo "$input" | cut -d'|' -f2 | tr -d ' ')
                
                if [[ -z "$binary_name" ]]; then
                    echo "Error: Empty binary name after '|'" >&2
                    return 1
                fi
            else
                repo_name="$input"
                binary_name=$(basename "$repo_name")
            fi

            # Basic owner/repo format check
            if [[ ! "$repo_name" =~ ^[^/]+/[^/]+$ ]]; then
                echo "Error: Invalid repository format '$repo_name'" >&2
                echo "Usage: ghpm install owner/repo" >&2
                echo "Tip: If you're looking for a package, try: ghpm search <name>" >&2
                return 1
            fi

            # Declare latest_version at the start
            local latest_version=""

            # Check if already installed
            local installed_info
            if installed_info=$(db_ops get "$binary_name" 2>/dev/null); then
                local current_version=$(echo "$installed_info" | jq -r '.version')
                local github_data
                github_data=$(query_github_api "$repo_name") || { handle_repo_error $? "$repo_name" || return $?; }
                latest_version=$(echo "$github_data" | jq -r '.tag_name')
                
                if [[ "${current_version#v}" == "${latest_version#v}" ]]; then
                    echo "Package $binary_name is already installed and up to date (version $current_version)" >&2
                    return 3 
                else
                    echo "Note: $binary_name is installed (version $current_version). Latest version is $latest_version" >&2
                    echo "Run $0 update $binary_name to update"
                    return 1
                fi
            fi

            # Get GitHub data to verify repo and get latest version
            local github_data ret
            github_data=$(query_github_api "$repo_name")
            ret=$?
            if [[ $ret -ne 0 ]]; then
                if [[ $ret -eq 2 ]]; then
                    echo "Error: Repository $repo_name not found. Please check the repository name and try again." >&2
                    exit 2
                else 
                    echo "Error: Failed to access GitHub API. Please check your connection and try again." >&2
                    exit 1
                fi
            fi

            echo "${repo_name}:${binary_name}:${latest_version}"
            ;;
            
    esac
    
    return 0
    # return 2 if not found
    # return 3 if installed and up to date
}

# this will accept a repo name, and fetch api input with a local cache validation. 
query_github_api() {
    local repo_name="$1"
    local ttl=36000    # Cache ttl/valid period, set at 600min
    local current_time=$(date +%s)

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
                log quiet "INFO" "Using cached data for $repo_name" quiet
                return 0
            else
                log "INFO" "Cache expired for $repo_name. Refreshing..."
            fi
        else
            log "INFO" "No cache entry found for $repo_name" quiet
        fi
    else
        log "INFO" "Cache file not found, creating a new file at $CACHE_FILE" 
    fi

    # Fetch from GitHub API
    local api_url="https://api.github.com/repos/$repo_name/releases/latest"
    local auth_header=""
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth_header="Authorization: token $GITHUB_TOKEN"

    local http_code api_response
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
            log quiet "INFO" "GitHub api response obtained and cached for $repo_name"
            echo "$api_response"
            ;;
        401) log "ERROR" "Authentication failed for $repo_name. Check GITHUB_TOKEN."; return 1 ;;
        403) log "ERROR" "Rate limit exceeded or access forbidden for $repo_name."; return 1 ;;
        404) log "ERROR" "Repository $repo_name not found."; return 2 ;;
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
            log quiet "INFO" "Using cached asset data: $cache_file"
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
    ["x86_64"]="[Aa]arch64|[Aa]rm64|[Aa]rmv[0-9]|i386|i686|[Dd]arwin|[Mm]ac[Oo][Ss]|[Oo][Ss][Xx]|[Ww]in(dows|[0-9]{2})|[Aa]ndroid|\
        [Ff]ree[Bb][Ss][Dd]|[Oo]pen[Bb][Ss][Dd]|[Nn]et[Bb][Ss][Dd]|[Dd]ragon[Ff]ly|[Bb][Ss][Dd]|checksums?|sha256|sha512|sig|\
        asc|deb|rpm|\.(zip|xz|tbz|deb|rpm|apk|msi|pkg|exe)$|[Gg]nu[Ee][Aa][Bb][Ii][Hh][Ff]|[Mm]usl[Ee][Aa][Bb][Ii][Hh][Ff]|\
        powerpc64|[Pp][Pp][Cc]|[Pp][Pp][Cc]64|[Pp]ower[Pp][Cc]64|[Rr][Ii][Ss][Cc][Vv]|[Ss]390[Xx]|[Mm]ips|[Mm]ips64"

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
        elif [[ "$name" =~ [Ss]ource([._-]?)[Cc]ode|[Ss]ource([._-]?[Ff]iles?)?|[Ss]ource\.(tar\.gz|tgz)$ ]]; then
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
    local has_source=false
    [[ ${#source_files[@]} -gt 0 ]] && has_source=true

    local final_json
    final_json=$(echo "{
        \"repo\": \"${repo}\",
        \"version\": \"${version}\",
        \"chosen_asset\": ${chosen_asset:-null},
        \"viable_assets\": [$(IFS=,; echo "${viable_assets[*]:-}")],
        \"excluded_assets\": [$(IFS=,; echo "${excluded_assets[*]:-}")],
        \"source_files\": [$(IFS=,; echo "${source_files[*]:-}")],
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

download_asset() {
    local repo_name="$1"
    local asset_input="$2"
    get_cache_paths "$repo_name"

    local asset_name
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
                log quiet "INFO" "Using cached asset: $cached_asset"
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
    [[ ! -f "$package_archive" ]] && echo "Error: Package archive does not exist: $package_archive" >&2 && return 1

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
    local binary_name=$(basename $binary_path)
    local file_info=$(file -b "$binary_path")
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
        dependencies=($(ldd "$binary_path" | awk '/=>/ {print $3}' | xargs -n1 basename | sort -u))
        if [[ ${#dependencies[@]} -gt 0 ]]; then
            log quiet "INFO" "Binary [$binary_name] has dependencies: ${dependencies[*]}"
        fi
    else
        log quiet "INFO" "Binary $binary_name is statically linked or does not require dynamic dependencies."
    fi

    echo "$binary_path"
    return 0
}

prep_install_files() {
    local repo_name="$1"
    local main_url="$2"
    local man_url="$3" 
    local completions_url="$4"
    local -n return_sorted_files=$5
    local -n return_install_map=$6

    rm -rf "$REPO_EXTRACTED_DIR"
    mkdir -p "$REPO_EXTRACTED_DIR"
    
    # Clear the return arrays
    return_sorted_files=()
    return_install_map=()

    # Type-specific counters to handle multiple files of same type
    declare -A type_counters=()

    if downloaded_main_asset=$(download_asset "$repo_name" "$main_url"); then
        if extract_package "$downloaded_main_asset" "$REPO_EXTRACTED_DIR"; then
            if binary_location=$(validate_binary "$REPO_EXTRACTED_DIR"); then
                binary_name=$(basename "$binary_location")
                return_sorted_files["binary_0"]="$binary_location"
                return_install_map["binary_0"]="$INSTALL_DIR/$binary_name"
            else
                log "ERROR" "No valid binary found in package"
                return 1
            fi
        else
            log "ERROR" "Unable to extract main asset"
            return 1
        fi
    else
        log "ERROR" "Unable to download main asset"
        return 1
    fi

    # Download and extract all provided URLs
    local urls=("$man_url" "$completions_url")
    for url in "${urls[@]}"; do
        [[ -z "$url" ]] && continue
        
        if ! local file=$(download_asset "$repo_name" "$url"); then
            continue
        fi
        
        if ! extract_package "$file" "$REPO_EXTRACTED_DIR"; then
            continue
        fi
    done

    # Define completion file patterns for each shell
    local -A completion_patterns=(
        ["bash_completion"]='.*completion.*bash$|.*\.bash$|.*\.bash-completion$'
        ["zsh_completion"]='.*completion.*zsh$|^_[^.]*$|.*\.zsh$|.*/_[^.]*$'
        ["fish_completion"]='.*completion.*fish$|.*\.fish$'
    )

    local -A completion_dirs=(
        ["bash_completion"]="$BASH_COMPLETION_DIR"
        ["zsh_completion"]="$ZSH_COMPLETION_DIR"
        ["fish_completion"]="$FISH_COMPLETION_DIR"
    )

    # Process all files in extracted directory
    while IFS= read -r file; do
        local filename=$(basename "$file")
        local file_type="" target_path=""
        
        # Skip if this is the binary we already processed
        [[ "$file" == "$binary_location" ]] && continue

        # Check for man pages
        if [[ "$filename" =~ ^.*\.([1-9])$ ]]; then
            local section=${BASH_REMATCH[1]}
            file_type="man${section}"
            target_path="$MAN_DIR/man${section}/$filename"
        else
            # Check for shell completions
            for shell_type in "${!completion_patterns[@]}"; do
                if [[ "$file" =~ ${completion_patterns[$shell_type]} ]]; then
                    file_type="$shell_type"
                    target_path="${completion_dirs[$shell_type]}/$filename"
                    break
                fi
            done
        fi

        # Add file to arrays if type was identified
        if [[ -n "$file_type" && -n "$target_path" ]]; then
            : ${type_counters[$file_type]:=0}
            return_sorted_files["${file_type}_${type_counters[$file_type]}"]="$file"
            return_install_map["${file_type}_${type_counters[$file_type]}"]="$target_path"
            ((type_counters[$file_type]++))
        fi
    done < <(find "$REPO_EXTRACTED_DIR" -type f)
    
    return 0
}

db_ops() {
    local operation="$1"
    local binary_name="${2:-}"
    shift 2

    # Ensure DB exists
    mkdir -p "$DB_DIR"
    [[ ! -f "$DB_FILE" ]] && echo '{}' > "$DB_FILE"

    case "$operation" in
        "add")
            local repo_name="$1"
            local version="$2"
            local -n files_ref="$3"
            local -n types_ref="$4"
            
            local ghpm_id=$(uuidgen 2>/dev/null || date +%s%N)
            local current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            # Convert install_files to JSON
            local files_json="["
            local first=true
            
            for key in "${!types_ref[@]}"; do
                [[ "$first" = true ]] || files_json+=","
                first=false
                local base_type=$(echo "$key" | sed 's/_[0-9]\+$//')
                
                files_json+=$(jq -n \
                    --arg name "$(basename "${types_ref[$key]}")" \
                    --arg path "${files_ref[$key]}" \
                    --arg type "$base_type" \
                    '{name: $name, location: $path, type: $type}')
            done
            files_json+="]"

            if ! jq --arg name "$binary_name" \
                   --arg repo "$repo_name" \
                   --arg id "$ghpm_id" \
                   --arg ver "$version" \
                   --arg time "$current_time" \
                   --argjson files "$files_json" \
                   '.[$name] = {
                       repo: $repo,
                       ghpm_id: $id,
                       version: $ver,
                       installed_date: $time,
                       last_updated: $time,
                       installed_files: $files
                   }' "$DB_FILE" > "${DB_FILE}.tmp"; then
                log "ERROR" "Failed to update database file"
                rm -f "${DB_FILE}.tmp"
                return 1
            fi
            mv "${DB_FILE}.tmp" "$DB_FILE"
            ;;
            
        "remove")
            # Get and remove files, then remove DB entry
            local files_to_remove=$(jq -r --arg name "$binary_name" \
                '.[$name].installed_files[].location // empty' "$DB_FILE")
            
            if [[ -n "$files_to_remove" ]]; then
                echo "$files_to_remove" | while read -r file; do
                    [[ -f "$file" ]] && rm -f "$file"
                done
            fi
            
            if ! jq --arg name "$binary_name" 'del(.[$name])' "$DB_FILE" > "${DB_FILE}.tmp"; then
                log "ERROR" "Failed to update database file"
                rm -f "${DB_FILE}.tmp"
                return 1
            fi
            mv "${DB_FILE}.tmp" "$DB_FILE"
            ;;
            
        "list")
            if [[ ! -f "$DB_FILE" ]] || [[ "$(jq 'length' "$DB_FILE")" -eq 0 ]]; then
                echo "No packages installed via GHPM."
                return 0
            fi

            echo
            echo "Packages managed by this script:"
            echo
            printf "%-15s %-12s %-s\n" "Package" "Version" "Location"
            printf "%s\n" "-------------------------------------------------------"

            jq -r '
                to_entries[] |
                select(.value.installed_files != null) |
                . as $root |
                .value.installed_files[] |
                select(.type == "binary") |
                [
                    $root.key,
                    $root.value.version,
                    .location
                ] |
                @tsv
            ' "$DB_FILE" | while IFS=$'\t' read -r package version location; do
                printf "%-15s %-12s %-s\n" "$package" "$version" "$location"
            done
            ;;
            
        "get")
            # Check if the key exists first
            if ! jq -e --arg name "$binary_name" 'has($name)' "$DB_FILE" >/dev/null; then
                return 1
            fi
            # If it exists, output the value
            jq --arg name "$binary_name" '.[$name]' "$DB_FILE"
            ;;
    esac
}

setup_paths() {
    local -A shell_configs=(
        ["bash"]="$HOME/.bashrc"
        ["zsh"]="$HOME/.zshrc"
        ["fish"]="$HOME/.config/fish/config.fish"
    )
    
    local -A path_commands=(
        ["bash"]="export PATH=\"\$PATH:$INSTALL_DIR\""
        ["zsh"]="export PATH=\"\$PATH:$INSTALL_DIR\""
        ["fish"]="fish_add_path $INSTALL_DIR"
    )
    
    local -A manpath_commands=(
        ["bash"]="export MANPATH=\"\$MANPATH:$MAN_DIR\""
        ["zsh"]="export MANPATH=\"\$MANPATH:$MAN_DIR\""
        ["fish"]="set -x MANPATH \$MANPATH $MAN_DIR"
    )
    
    # Process each supported shell
    for shell in "${!shell_configs[@]}"; do
        local config_file="${shell_configs[$shell]}"
        
        # Skip if shell binary not found or config doesn't exist
        [[ ! $(command -v "$shell" 2>/dev/null) || ! -f "$config_file" ]] && continue
        
        # Ensure newline at end of file
        [[ "$(tail -c1 "$config_file" | wc -l)" -eq 0 ]] || echo "" >> "$config_file"
        
        # Update PATH if needed
        if ! grep -q "${path_commands[$shell]}" "$config_file"; then
            echo "${path_commands[$shell]}" >> "$config_file"
            log "INFO" "Added $INSTALL_DIR to PATH in $config_file"
            echo "$INSTALL_DIR added to PATH. Please run: source $(basename "$config_file")"
        fi
        
        # Update MANPATH if needed
        if ! grep -q "${manpath_commands[$shell]}" "$config_file"; then
            echo "${manpath_commands[$shell]}" >> "$config_file"
            log "INFO" "Added $MAN_DIR to MANPATH in $config_file"
            echo "$MAN_DIR added to MANPATH. Please run: source $(basename "$config_file")"
        fi
    done
}

standalone_install() {
    local repo_name="$1"
    local silent=${2:-false}

    local repo_name binary_name latest_version
    if ! validation_output=$(validate_input repo "$repo_name"); then
        [[ "$silent" == "false" ]] && echo "$validation_output" >&2
        return 1
    fi
    IFS=':' read -r repo_name binary_name latest_version <<< "$validation_output"
    
    # Process repo release data
    local api_response=$(query_github_api "$repo_name") || return 1
    local processed_data=$(process_asset_data "$api_response") || return 1

    # Extract necessary URLs and information
    local asset_url=$(echo "$processed_data" | jq -r '.chosen_asset.url')
    local man1_url=$(echo "$processed_data" | jq -r '.man_files[0].url // empty')
    local completions_url=$(echo "$processed_data" | jq -r '.completions_files[0].url // empty')
    local version=$(echo "$processed_data" | jq -r '.version')
    local asset_name=$(echo "$processed_data" | jq -r '.chosen_asset.name')

    # Prepare files for installation
    get_cache_paths "$repo_name"
    declare -A sorted_files
    declare -A sorted_install_map
    
    prep_install_files "$repo_name" "$asset_url" "$man1_url" "$completions_url" sorted_files sorted_install_map || return 1

    if [[ "$silent" == "false" ]]; then
        # Display installation details    
        echo -e "\nRepo: $repo_name"
        echo "Latest version: $version"
        echo "Release asset: $asset_name"
        echo "Files to install:"

        for key in "${!sorted_files[@]}"; do
            printf "    %-20s --> %s\n" "$(basename "${sorted_files[$key]}")" "${sorted_install_map[$key]}"
        done
        echo

        # Confirm installation
        read -p "Proceed with installation? [y/N]: " -r
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            echo "Installation canceled."
            return 1
        fi
        echo "Installing files..."
        echo
    fi

    # Get binary name for database operations
    local binary_name=$(basename "${sorted_files[binary_0]}")
    
    # Install all files
    local success=true
    for key in "${!sorted_files[@]}"; do
        mkdir -p "$(dirname "${sorted_install_map[$key]}")"
        [[ "$silent" == "false" ]] && echo "Installing $(basename "${sorted_files[$key]}"): ${sorted_install_map[$key]}"
        
        if ! mv "${sorted_files[$key]}" "${sorted_install_map[$key]}"; then
            log "ERROR" "Failed to move ${sorted_files[$key]} to ${sorted_install_map[$key]}"
            success=false
        fi
    done
    
    if ! $success; then
        log "ERROR" "One or more files failed to install"
        return 1
    fi

    db_ops add "$binary_name" "$repo_name" "$version" "sorted_install_map" "sorted_files" || return 1
    setup_paths

    [[ "$silent" == "false" ]] && echo -e "\nInstalled $binary_name to $INSTALL_DIR\n"

    return 0
}

batch_install() {
    local repos_file="$1"
    local silent="${2:-false}"

    [[ ! -f "$repos_file" ]] && log "ERROR" "Repositories file '$repos_file' not found." && return 1

    if [[ "$silent" == "false" ]]; then
        echo "Processing repositories from $repos_file:"
        echo
        echo "Checking versions..."
        printf "%-15s %-12s %-12s %-50s\n" "Binary" "Github" "APT" "Asset"
        echo "------------------------------------------------------------------------------------------------"
    fi

    # Initialize package arrays
    local repo_list=() binary_names=() gh_versions=() apt_versions=() assets=() total_repos=()
    local skipped_repos=() skipped_reasons=()
    local valid_packages=0 needs_update=false
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        ((total_repos++))
        local repo_name binary_name
        if [[ "$line" == *"|"* ]]; then
            IFS='|' read -r repo_name binary_name <<< "$line"
            repo_name=$(echo "$repo_name" | xargs)
            binary_name=$(echo "$binary_name" | xargs)
        else
            repo_name=$(echo "$line" | xargs)
            binary_name=$(echo "$repo_name" | cut -d'/' -f2)
        fi
        get_cache_paths "$repo_name"

        # Query github api for the repo, and process it
        local gh_response=$(query_github_api "$repo_name") || continue
        local processed_data=$(process_asset_data "$gh_response") || continue
        
        # Extract info in one jq call
        local gh_version chosen_asset has_source
        gh_version=$(echo "$processed_data" | jq -r '.version')
        chosen_asset=$(echo "$processed_data" | jq -r '.chosen_asset.name')
        has_source=$(echo "$processed_data" | jq -r '.has_source_files')
        
        # Find apt version
        local apt_version="not found"
        if command -v apt-cache >/dev/null 2>&1; then
            apt_version=$(apt-cache policy "$binary_name" 2>/dev/null | grep 'Candidate:' | sed -E 's/.*Candidate: //; s/-[^-]*ubuntu[^-]*//; s/-$//; s/[^0-9.].*//; s/^/v/')
            [[ -z "$apt_version" || "$apt_version" == "none" ]] && apt_version="not found"
        fi
        
        if [[ "$chosen_asset" == "null" || -z "$chosen_asset" ]]; then
            skipped_repos+=("$repo_name")
            [[ "$has_source" == "true" ]] && skipped_reasons+=("source only") || skipped_reasons+=("no viable assets")
            continue
        fi

        # Store repo info
        ((valid_packages++))
        binary_names+=("$binary_name")
        repo_list+=("$repo_name")
        gh_versions+=("$gh_version")
        apt_versions+=("$apt_version")
        assets+=("$chosen_asset")

        if [[ "$silent" == "false" ]]; then
            printf "%-15s %-12s %-12s %-50s\n" "$binary_name" "$gh_version" "$apt_version" "$chosen_asset"
        fi
    done < "$repos_file"

    [[ ${#repo_list[@]} -eq 0 ]] && log "ERROR" "No valid repositories found in $repos_file" && return 1

    if [[ "$silent" == "false" && ${#skipped_repos[@]} -gt 0 ]]; then
        echo -e "\nSkipped repositories:"
        for i in "${!skipped_repos[@]}"; do
            echo "  - ${skipped_repos[$i]} (${skipped_reasons[$i]})"
        done
    fi

    # In silent mode, automatically choose GitHub installation
    choice=1
    if [[ "$silent" == "false" ]]; then
        echo -e "\nInstallation options:"
        echo "1. Install all GitHub versions (to $INSTALL_DIR)"
        echo "2. Install all APT versions"
        echo "3. Cancel"
        read -rp "Select installation method [1-3]: " choice
    fi

    case $choice in
        1)
            [[ "$silent" == "false" ]] && echo "Installing ${#repo_list[@]} packages from GitHub..."
            [[ "$silent" == "false" ]] && echo
            local success_count=0
            for i in "${!repo_list[@]}"; do
                if standalone_install "${repo_list[i]}" --silent; then
                    ((success_count++))
                else
                    log quiet "ERROR" "Failed to install ${repo_list[i]}"
                fi
            done
            
            [[ "$silent" == "false" ]] && echo
            [[ "$silent" == "false" ]] && echo "Installation complete: $success_count/$total_repos repository packages installed successfully"  ;;
        2)
            apt_install binary_names[@]
            ;;
        3)
            [[ "$silent" == "false" ]] && echo "Installation cancelled."
            return 0 
            ;;
        *)
            echo "Invalid option. Exiting."
            return 1
            ;;
    esac
}

remove_package() {
    local binary_name="$1"
    local silent_mode="${2:-false}"
    local tmp_dir="${DATA_DIR}/tmp"
    local backup_dir="${tmp_dir}/backup_$(date +%s)"
    local db_backup="${backup_dir}/db_backup.json"
    # First check if package was installed by ghpm
    if ! package_info=$(db_ops get "$binary_name"); then
        log quiet "ERROR" "$binary_name cannot be removed as it is not managed by the script"
        [[ "$silent_mode" == "false" ]] && echo "Error: Package $binary_name is not managed by this script"
        return 1
    fi
    local repo_name=$(echo "$package_info" | jq -r '.repo')
    local version=$(echo "$package_info" | jq -r '.version')
    local files_to_remove=($(echo "$package_info" | jq -r '.installed_files[].location'))
    if [[ ${#files_to_remove[@]} -eq 0 ]]; then
        log "ERROR" "No installed files found for $binary_name"
        return 1
    fi

    if [[ "$silent_mode" == "false" ]]; then
        echo -e "\nRemoving package: $binary_name"
        echo "Repository: $repo_name"
        echo "Installed version: $version"
        echo -e "\nFiles to be removed:"
        printf '%s\n' "${files_to_remove[@]/#/    }"

        read -p $'\nProceed with removal? [y/N]: ' -r
        [[ ! "$REPLY" =~ ^[Yy]$ ]] && echo "Removal cancelled." && return 1
    fi

    # Backup db
    mkdir -p "$backup_dir" || { log "ERROR" "Failed to create backup directory: $backup_dir"; return 1; }
    cp "$DB_FILE" "$db_backup" || { log "ERROR" "Failed to create database backup"; rm -rf "$backup_dir"; return 1; }

    # Move files to backup location instead of deleting
    local move_failed=false
    for file in "${files_to_remove[@]}"; do
        if [[ -f "$file" ]]; then
            local backup_path="${backup_dir}/${file##*/}"
            if ! mv "$file" "$backup_path" 2>/dev/null; then
                log "ERROR" "Failed to Remove file: $file"
                move_failed=true
                break
            fi
            [[ "$silent_mode" == "false" ]] && echo "Removed: $file"
        else
            log "WARNING" "File not found: $file"
        fi
    done

    # If any moves failed, restore from backup and exit
    if [[ "$move_failed" == "true" ]]; then
        log "ERROR" "Failed to remove all files, restoring from backup"
        for file in "$backup_dir"/*; do
            [[ -f "$file" ]] && mv "$file" "${files_to_remove[0]%/*}/"
        done
        rm -rf "$backup_dir"
        return 1
    fi

    # Update database
    if ! db_ops remove "$binary_name"; then
        log "ERROR" "Failed to update database, restoring from backup"
        # Restore database
        cp "$db_backup" "$DB_FILE"
        # Restore moved files
        for file in "$backup_dir"/*; do
            [[ -f "$file" ]] && mv "$file" "${files_to_remove[0]%/*}/"
        done
        rm -rf "$backup_dir"
        return 1
    fi

    if [[ "$silent_mode" == "false" ]]; then
        echo -e "\nPackage $binary_name removed successfully"
    fi
    log "INFO" "Successfully removed package: $binary_name"

    # Clean up backup directory and files
    rm -rf "$backup_dir"
    return 0
}

update_package() {
    local package_name="${1:-all}"
    local -a packages_to_update=()
    
    if [[ "$package_name" == "all" || "$package_name" == "" ]]; then
        if ! all_packages=$(jq -r 'keys[]' "$DB_FILE"); then
            echo " No packages installed via GHPM."
            return 0
        fi
        readarray -t packages_to_update <<< "$all_packages"
    else
        # Check if package exists and is managed by ghpm
        if ! package_info=$(db_ops get "$package_name"); then
            echo "Error: $package_name is not installed"
            return 1
        fi
        packages_to_update=("$package_name")
    fi

    # Only continue if we have packages to update
    [[ ${#packages_to_update[@]} -eq 0 ]] && return 0

    echo "Checking for updates ..."
    echo
    printf "        %-12s %-10s %-10s %-50s\n" "Package" "Current" "Latest" "Release asset"
    echo "        --------------------------------------------------------------------------------"
    
    local updates_available=false
    declare -A update_info
    
    for pkg in "${packages_to_update[@]}"; do
        local pkg_info current_version latest_version asset_name
        
        # Get installed package info
        pkg_info=$(db_ops get "$pkg")
        current_version=$(echo "$pkg_info" | jq -r '.version')
        repo_name=$(echo "$pkg_info" | jq -r '.repo')
        
        # Get latest version from GitHub
        local github_response processed_data
        github_response=$(query_github_api "$repo_name")
        processed_data=$(process_asset_data "$github_response")
        
        latest_version=$(echo "$processed_data" | jq -r '.version')
        asset_name=$(echo "$processed_data" | jq -r '.chosen_asset.name')
        
        # Compare versions (strip v prefix for proper comparison)
        local curr_ver="${current_version#v}"
        local latest_ver="${latest_version#v}"
        printf "        %-12s %-10s %-10s %-50s\n" "$pkg" "$current_version" "$latest_version" "$asset_name"
        
        if [[ "$(echo -e "$curr_ver\n$latest_ver" | sort -V | tail -n1)" != "$curr_ver" ]]; then
            updates_available=true
            update_info["$pkg"]="$repo_name|$current_version|$latest_version|$asset_name"
        fi
    done
    echo
    if ! $updates_available; then
        if [[ ${#packages_to_update[@]} -eq 1 ]]; then
            echo "        ${packages_to_update[0]} is up to date!"
        else
            echo "        All packages are up to date!"
        fi
        return 0
    fi
    
    if [[ ${#packages_to_update[@]} -eq 1 ]]; then
        echo
        echo "Update found:"
        for pkg in "${!update_info[@]}"; do
            IFS='|' read -r repo_name current_version new_version asset_name <<< "${update_info[$pkg]}"
            echo "        $pkg $current_version --> $new_version"
        done
        echo
        echo -n "Proceed? [y/N] "
        read -r REPLY
    else
        echo
        echo "Updates found:"
        for pkg in "${!update_info[@]}"; do
            IFS='|' read -r repo_name current_version new_version asset_name <<< "${update_info[$pkg]}"
            echo "        $pkg $current_version --> $new_version"
        done
        echo
        echo -n "Proceed with all updates? [y/N] "
        read -r REPLY
    fi
    
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Update cancelled."
        return 0
    fi
    
    # Perform updates
    local success_count=0
    for pkg in "${!update_info[@]}"; do
        IFS='|' read -r repo_name current_version new_version asset_name <<< "${update_info[$pkg]}"
        
        echo -n " Updating $pkg to $new_version..."
        echo -n " Removing old version..."
        if ! remove_package "$pkg" --silent; then
            echo " Failed!"
            log "ERROR" "Failed to remove old version of $pkg"
            continue
        fi
        
        echo -n " Installing $pkg $new_version to $INSTALL_DIR..."
        if ! standalone_install "$repo_name" --silent; then
            echo " Failed!"
            log "ERROR" "Failed to install new version of $pkg"
            continue
        fi
        echo " Success!"
        
        ((success_count++))
    done
    return 0
}

# search for repositories using /search/repositories api endpoint. 
search_packages() {
    local query="$1"
    local page_size=15
    local current_page=${2:-1}  # Default to page 1 if not specified
    [[ -z "$query" ]] && { echo "Usage: ghpm search <query>"; return 1; }

    # Store example repo name for later use
    local example_repo=""

    while true; do
        # Get search results for current page
        local encoded_query=$(echo "$query in:name,description language:rust,go,python,c,cpp fork:false" | sed 's/ /%20/g')
        local api_url="https://api.github.com/search/repositories?q=${encoded_query}&sort=stars&order=desc&per_page=${page_size}&page=${current_page}"
        
        local auth_header=""
        [[ -n "${GITHUB_TOKEN:-}" ]] && auth_header="Authorization: token $GITHUB_TOKEN"

        local items_response
        if [[ -n "$auth_header" ]]; then
            items_response=$(curl -sS -H "$auth_header" -H "Accept: application/vnd.github.v3+json" "$api_url")
        else
            items_response=$(curl -sS -H "Accept: application/vnd.github.v3+json" "$api_url")
        fi

        # Check for API errors
        if [[ $(echo "$items_response" | jq -r '.message // empty') ]]; then
            log "ERROR" "GitHub API error: $(echo "$items_response" | jq -r '.message')"
            return 1
        fi

        # Calculate total pages
        local total_count=$(echo "$items_response" | jq -r '.total_count')
        [[ "$total_count" -eq 0 ]] && { echo "No matches found for '$query'"; return 0; }
        local total_pages=$(( (total_count + page_size - 1) / page_size ))

        # Display results
        echo "Found $total_count repositories matching '$query'"
        echo "Showing page $current_page of $total_pages (${page_size} results per page)"
        echo
        printf "%-30s %-8s %-8s %-8s %-40s\n" "Repository" "Stars" "Latest" "Assets" "Description"
        printf "%$(tput cols)s\n" | tr ' ' '-'

        echo "$items_response" | jq -r '.items[] | . as $repo | 
            ($repo.full_name[:30]) as $name |
            ($repo.description[:60] // "No description") as $desc |
            ($repo.stargazers_count | tostring) as $stars |
            $repo.full_name as $full_name |
            [$name, $stars, "checking..", $desc, $full_name] | @tsv' | \
        while IFS=$'\t' read -r name stars _ desc full_name; do
            [[ -z "$example_repo" ]] && example_repo="$full_name"
            
            local latest_ver="N/A"
            local asset_count="0"
            if release_info=$(query_github_api "$name" 2>/dev/null); then
                latest_ver=$(echo "$release_info" | jq -r '.tag_name // "N/A"')
                # Format version string
                if [[ "$latest_ver" != "N/A" ]]; then
                    latest_ver="${latest_ver#v}"
                    if [[ "$latest_ver" =~ [0-9] ]]; then
                        latest_ver="${latest_ver:0:8}"
                    else
                        latest_ver="${latest_ver:0:5}..."
                    fi
                fi
                asset_count=$(echo "$release_info" | jq -r '.assets | length')
            fi
            printf "%-30s %-8s %-8s %-8s %-40s\n" "$name" "$stars" "$latest_ver" "$asset_count" "$desc"
        done

        echo
        echo "Navigation:"
        [[ $current_page -gt 1 ]] && echo "  [p] Previous page"
        [[ $current_page -lt $total_pages ]] && echo "  [n] Next page"
        echo "  [q] Quit"
        echo "  Current: Page $current_page of $total_pages"
        echo
        echo "To install any of these packages, use: ghpm install owner/repo"
        [[ -n "$example_repo" ]] && echo "For example: ghpm install $example_repo"

        # Get navigation input
        echo -n "Enter navigation command (n/p/q): "
        read -n 1 -r input
        echo

        case "$input" in
            n|N)
                if [[ $current_page -lt $total_pages ]]; then
                    ((current_page++))
                fi
                ;;
            p|P)
                if [[ $current_page -gt 1 ]]; then
                    ((current_page--))
                fi
                ;;
            q|Q|*)
                return 0
                ;;
        esac
    done
}

main() {
    
    # Check dependencies
    for dep in curl jq tar unzip; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Error: Missing $dep. Please install it via your package manager."
            return 1
        fi
    done

    # Clean old cache (>90 days)
    [[ -d "$CACHE_DIR" ]] && find "$CACHE_DIR" -type f -mtime +90 -delete 2>/dev/null

    local silent=false
    [[ "$1" == "-u" ]] && silent=true && shift

    local cmd="$1"
    shift

    case "$cmd" in
        "install")
            local repo_name="$1"
            if [[ -z "$repo_name" ]]; then
                echo "Usage: $0 install owner/repo"
                return 1
            fi
            standalone_install "$repo_name" ;;

        "remove")
            local binary_name="$1"
            if [[ -z "$binary_name" ]]; then
                echo "Usage: $0 remove <package-name>"
                return 1
            fi
            remove_package "$binary_name" ;;
        
        "update")
            local package_name="$1"
            update_package "$package_name" ;;
        
        "search")
           local query="$1"
           search_packages "$query" ;;
        
        "--clear-cache")
            rm -rf $CACHE_DIR 
            echo "Purging cache.."
            echo "Cache claered"
            echo 
            [[ "$?" -ne 1 ]] && log quiet "INFO" "Cache cleared";;
 
        "--file")
            local repos_file="$1"
            batch_install "$repos_file" "$silent" ;;

        "list")
            db_ops list ;;

        "--version")
            echo "0.0.7" ;;

        *)
            echo "GitHub Package Manager - a script to download and manage precompiled binaries from Github"
            echo
            echo "Usage: $0 [-u] <command> [options]"
            echo
            echo "Options:"
            echo "  -u                      Run in unattended mode (no prompts)"
            echo
            echo "Commands:"
            echo "  install <owner/repo>    Install a package from GitHub"
            echo "  remove <package>        Uninstalls a package."
            echo "  update                  Checks and updates all installed packages"
            echo "  update <package>        Checks and updates <package>"
            echo "  search <package>        Searches GitHub for mathcing repository for the <package>"
            echo "  --file <file.txt>       Accepts a list of repositories from a file."
            echo "  --list                  List installed packages"
            echo "  --clear-cache           Clear the cache"
            echo "  --version               Show version"
            return 1 ;;
    esac
}

# Run main function with all arguments only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi