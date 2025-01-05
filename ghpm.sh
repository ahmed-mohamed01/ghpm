#! /usr/bin/env bash

#set -euo pipefail      # set -e error handling, -u undefined variable protection -o pipefail piepline faulure catching. 
DISPLAY_ISSUES=true    # make log output visible. 

# Configure folders
DATA_DIR="${PWD}/.local/share/ghpm"
INSTALL_DIR="${PWD}/.local/bin"

CACHE_DIR="${DATA_DIR}/cache"
CACHE_FILE="${CACHE_DIR}/api-cache.json"
ASSET_CACHE_DIR="${CACHE_DIR}/assets"

DB_DIR="${DATA_DIR}/db"
DB_FILE="${DB_DIR}/installed.json"

# readonly PROCESSED_CACHE_DIR="${ASSET_CACHE_DIR}/%s"         # Just the dir
# readonly PROCESSED_CACHE_FILE="%s-%s-asset-cache.json"       # Just the filename

# # Helper function
# get_processed_cache_path() {
#     local repo_dir="$(echo "$1" | sed 's|/|_|g')"
#     local version="$2"
#     local cache_dir=$(printf "$PROCESSED_CACHE_DIR" "$repo_dir")
#     printf "$cache_dir/%s" "$(printf "$PROCESSED_CACHE_FILE" "$repo_dir" "$version")"
# }

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
    local repo="$2"
    local version="$3"
    local REPO_CACHE_DIR=$(echo "$repo" | sed 's|/|_|g')
    local repo version
    read -r repo version < <(echo "$PROCESSED_CACHE" | jq -r '.repo, .version')

    local PROCESSED_CACHE="${ASSET_CACHE_DIR}/${REPO_CACHE_DIR}/processed-{REPO_CACHE_DIR}-${version}-asset-cache.json"
    if [[ -n "$PROCESSED_CACHE" ]]; then
        local cached_repo cached_version
        read -r cached_repo cached_version < <(echo "$PROCESSED_CACHE" | jq -r '.repo, .version')
        if [[ "$cached_repo" == "$repo" && "$cached_version" == "$version" ]]; then
            echo "$PROCESSED_CACHE"
            return 0
        fi
    fi

    # Initialize arrays 
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
        version=$(echo "$api_response" | jq -r '.tag_name')
        repo=$(echo "$api_response" | jq -r '.url' | cut -d'/' -f4-5)

        if [[ "$name" =~ ${EXCLUDED_PATTERNS[$system_arch]} ]]; then
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"excluded pattern\",\"url\":\"$url\"}")
            continue    
        elif [[ "$name" =~ [sS]ource[._-?][Cc]ode ]]; then
            source_files+=("{\"name\":\"$name\",\"url\":\"$url\"}")
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"source code archive\",\"url\":\"$url\"}")
            continue
        elif [[ "$name" =~ ^completions[^/]*\.(tar\.gz|tgz)$ ]]; then
            completions_files+=("{\"name\":\"$name\",\"url\":\"$url\"}")
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"completions files\",\"url\":\"$url\"}")
        elif [[ "$name" =~ ^man[^/]*\.(tar\.gz|tgz)$ ]]; then
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

    echo "{
        \"repo\": \"${repo}\",
        \"version\": \"${version}\",
        \"chosen\": ${chosen_asset:-null},
        \"viable\": [$(IFS=,; echo "${viable_assets[*]}")],
        \"excluded\": [$(IFS=,; echo "${excluded_assets[*]}")],
        \"source\": [$(IFS=,; echo "${source_files[*]}")],
        \"man\": [$(IFS=,; echo "${man_files[*]}")],
        \"completions\": [$(IFS=,; echo "${completions_files[*]}")]
    }" | jq '.'
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
    local asset_download_url="$2"
    local output_file="$3"
    local asset_name=$(basename "$asset_download_url")
    local cache_dir="${ASSET_CACHE_DIR}/${repo_name}"
    local cached_asset="${cache_dir}/${asset_name}"
    local metadata_file="${cached_asset}.metadata"

    # Ensure the cache directory exists
    mkdir -p "$cache_dir"

    # Check if asset is already cached
     if [[ -f "$cached_asset" && -f "$metadata_file" ]]; then
        local cached_url=$(jq -r '.url' "$metadata_file")
        local cached_hash=$(jq -r '.hash' "$metadata_file")
        local current_hash=$(sha256sum "$cached_asset" | awk '{print $1}')

        if [[ "$cached_url" == "$asset_download_url" && "$current_hash" == "$cached_hash" ]]; then
            echo "Using cached asset: $cached_asset"
            # Copy cached asset to output location if different
            if [[ "$cached_asset" != "$output_file" ]]; then
                cp "$cached_asset" "$output_file"
            fi
            return 0
        fi
    fi

    # Download the asset
    echo "Downloading asset: $asset_download_url"
    curl -sSL -o "$output_file" "$asset_download_url" || { echo "Failed to download asset." >&2; return 1; }

    # Cache the downloaded asset
    cp "$output_file" "$cached_asset"

    # Create metadata file
    local hash=$(sha256sum "$cached_asset" | awk '{print $1}')
    local date_created=$(date -Iseconds)
    jq -n \
            --arg url "$asset_download_url" \
            --arg hash "$hash" \
            --arg date_created "$date_created" \
            '{url: $url, hash: $hash, date_created: $date_created}' > "$metadata_file"

    echo "Downloaded and cached: $cached_asset"
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

    echo "Extraction complete: $extract_dir"
    return 0
}

validate_binary() {
    local binary_path="$1"
    local system_info=$(uname -m)

    # Find the executable
    local executable
    executable=$(find "$binary_path" -type f -executable -print -quit)
    if [[ -z "$executable" ]]; then
        echo "Error: No executable binary found" >&2
        return 1
    fi

    # Verify executable is actually a binary
    local file_type
    file_type=$(file -b "$executable")
    if [[ "$file_type" != *"ELF"* ]] || [[ "$file_type" != *"Linux"* ]]; then
        echo "Error: Incompatible binary. Only Linux ELF binaries are supported." >&2
        return 1
    fi

    # Check for system-specific exclusions (Darwin, FreeBSD, OpenBSD)
    if [[ "$file_type" == *"Mach-O"* ]] || [[ "$file_type" == *"FreeBSD"* ]] || [[ "$file_type" == *"OpenBSD"* ]]; then
        echo "Error: Incompatible binary for Darwin/BSD systems." >&2
        return 1
    fi

    # Convert architecture names for comparison
    local file_arch
    if [[ "$file_type" == *"x86-64"* ]]; then
        file_arch="x86_64"
    elif [[ "$file_type" == *"aarch64"* ]]; then
        file_arch="arm64"
    else
        file_arch=$(echo "$file_type" | grep -o -E 'arm(v[0-9])?|x86[-_]64|amd64|i386|i686')
    fi

    # Verify the binary is compatible with Linux (ELF format)
    if [[ "$file_type" != *"ELF"* ]] && [[ "$file_type" != *"Linux"* ]]; then
        echo "Error: Binary is not a Linux executable" >&2
        echo "Binary details: $file_type" >&2
        return 1
    fi

    # Map architecture for comparison
    local file_arch
    if [[ "$file_type" == *"x86-64"* ]]; then
        file_arch="x86_64"
    elif [[ "$file_type" == *"aarch64"* ]]; then
        file_arch="arm64"
    else
        file_arch=$(echo "$file_type" | grep -o -E 'arm(v[0-9])?|x86[_-]64|amd64|i386|i686')
    fi

    # Verify architecture compatibility
    if [[ "$file_arch" != "$system_arch" ]] && [[ "$file_arch" != "amd64" ]]; then
        echo "Error: Binary architecture ($file_arch) incompatible with system architecture ($system_arch)." >&2
        return 1
    fi

    # Check dependencies if dynamically linked
    local ldd_output
    ldd_output=$(ldd "$executable" 2>&1)
    if [[ $? -eq 0 && "$ldd_output" == *"not found"* ]]; then
        echo "Error: Missing dependencies for $executable:" >&2
        echo "$ldd_output" >&2
        return 1
    fi

    echo "Binary $executable is valid and compatible."
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

install_man_pages_completions() {
    local extract_dir="$1"
    local package_name=$(basename "$extract_dir")
    
    # Create completion directories if they don't exist
    local bash_comp_dir="$HOME/.local/share/bash-completion/completions"
    local zsh_comp_dir="$HOME/.local/share/zsh/site-functions"
    local man_dir="$HOME/.local/share/man"
    
    mkdir -p "$bash_comp_dir" "$zsh_comp_dir" "$man_dir"
    
    # Find all potential completions and man pages in the extracted directory
    local found_files=$(find "$extract_dir" \( -name "*completion*" -o -name "*completions*" -o -name "*.1" -o -name "*.1.gz" \) -type f)
    
    if [ -z "$found_files" ]; then
        echo "No completions or man pages found in extracted files" >&2
        return 0
    fi
    
    local installed_count=0
    while IFS= read -r file; do
        case "$file" in
            *bash-completion*|*bash_completion*|*completion.bash|*completions.bash)
                echo "Installing bash completion: $file" >&2
                cp "$file" "$bash_comp_dir/$package_name"
                ((installed_count++))
                ;;
            *zsh-completion*|*zsh_completion*|*_*)
                echo "Installing zsh completion: $file" >&2
                cp "$file" "$zsh_comp_dir/_$package_name"
                ((installed_count++))
                ;;
            *.1|*.1.gz)
                local section_dir="$man_dir/man1"
                echo "Installing man page: $file to $section_dir" >&2
                mkdir -p "$section_dir"
                cp "$file" "$section_dir/"
                ((installed_count++))
                ;;
        esac
    done <<< "$found_files"
    
    if [ $installed_count -gt 0 ]; then
        echo "Installed $installed_count completion/man files" >&2
    else
        echo "No completions or man pages found to install" >&2
    fi
    
    return 0
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
       --arg comp "$comparison" \
       --arg time "$(date +%s)" \
       '. + {
           apt_info: {
               version: $apt,
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
    # # Use process_api_response to get latest version
    # latest_version=$(process_api_response "latest-version" "$api_response")

    # # Fetch download url for an asset:
    # file="zoxide-0.9.6-i686-unknown-linux-musl.tar.gz"
    # download_url_for_asset=$(process_api_response "download-url" "$api_response" "$file")
    # raw_asset_data=$(process_asset_data "$api_response")
    # if [[ $? -ne 0 ]]; then
    #     log "ERROR" "Unable to process"
    # fi
    # best_asset=$(process_api_response "choose-best-asset" "$api_response")
    # assets=$(process_api_response "asset-names" "$api_response")
    # best_asset_url=$(process_api_response "chosen-asset-url" "$api_response")
    # completions=$(process_api_response "completions" "$api_response")
    # if [[ -z "$completions" ]]; then
    #     completions="not found"
    # fi
    # local response_source=$(echo "$api_response" | jq -r '._source')
    # local completions_url=$(echo "$raw_asset_data" | jq -r '.completions[].url')

    # # Print summary: 
    # echo "Repo: $repo_name (Source: $response_source)"
    # echo "Latest version: $latest_version"
    # echo "Download URL for $file is $download_url_for_asset"
    # echo "Best asset: $best_asset"
    # echo "Best asset is at: $best_asset_url"
    # echo "Assets: $assets"
    # echo "Completions: $completions"
    # echo "$completions_url"
    # #echo "$raw_asset_data" | jq '.'
    local repo_name="$1"

    # if ! api_response=$(query_github_api "$repo_name"); then
    #     log "ERROR" "Unable to fetch response"
    #     return 1
    # fi

    # # Get version directly from api_response (this doesn't need asset processing)
    # latest_version=$(echo "$api_response" | jq -r '.tag_name | sub("^v"; "")')
    
    # # Process assets once
    # local asset_data=$(process_asset_data "$api_response")
    
    # # Extract everything we need from the single processed result
    # local best_asset=$(echo "$asset_data" | jq -r '.chosen.name')
    # local best_asset_url=$(echo "$asset_data" | jq -r '.chosen.url')
    # local completions=$(echo "$asset_data" | jq -r '
    #     if (.completions | length) == 0 then
    #         "not found"
    #     else
    #         .completions[].url
    #     end')
    # local response_source=$(echo "$api_response" | jq -r '._source')
    # local asset_list=$(echo "$api_response" | jq -r '.assets[].name')

    # # Print summary
    # echo "Repo: $repo_name (Source: $response_source)"
    # echo "Latest version: $latest_version"
    # echo "Best asset: $best_asset"
    # echo "Best asset is at: $best_asset_url"
    # echo "Completions: $completions"
    # echo "Name: $asset_list"
    if ! api_response=$(query_github_api "$repo_name"); then
        log "ERROR" "Unable to fetch response"
        return 1
    fi

    # Get all system info up front
    local system_arch=$(uname -m)
    local os_type=$(uname -s)
    local libc_type="unknown"      
    local bit_arch=$(getconf LONG_BIT)
    local distro=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')

    # Single jq pass - store root object first
    eval "$(echo "$api_response" | jq -r --arg arch "$system_arch" \
                                      --arg libc "$libc_type" \
                                      --arg bits "$bit_arch" \
                                      --arg distro "$distro" '
        # Store root context
        . as $root |
        
        # Scoring function
        def score_asset($name):
          0 +
          (if $name | test("\\.tar\\.gz$") then 15 else 0 end) +
          (if $name | test("[Ll]inux") then 10 else 0 end) +
          (if $arch == "x86_64" and $name | test("x86[-_.]64|amd64") then 30 else 0 end);

        # Process everything and output shell assignments
        .assets
        | map(. + {score: score_asset(.name)})
        | sort_by(-.score)
        | "version=\"\($root.tag_name | sub("^v"; ""))\"
           best_asset=\"\(.[0].name)\"
           best_url=\"\(.[0].browser_download_url)\"
           completions=\"\(map(select(.name | startswith("completions"))) | if length > 0 then .[0].url else "not found" end)\"
           source=\"\($root._source)\""
    ')"

    printf "Repo: %s (Source: %s)\nLatest version: %s\nBest asset: %s\nBest asset URL: %s\nCompletions: %s\n" \
        "$repo_name" "$source" "$version" "$best_asset" "$best_url" "$completions"

}

# Run main function with all arguments only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
