#! /usr/bin/env bash

#set -euo pipefail      # set -e error handling, -u undefined variable protection -o pipefail piepline faulure catching. 
DISPLAY_ISSUES=true    # make log output visible. 

# Configure folders
DATA_DIR="${PWD}/.local/share/ghpm"
CACHE_DIR="${DATA_DIR}/cache"
CACHE_FILE="${CACHE_DIR}/api-cache.json"
ASSET_CACHE_DIR="${CACHE_DIR}/assets"

# Colors to be used in output
declare -a ISSUES=()
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

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
                echo "$repo_cached_data" | jq -c '.data'
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

process_asset_data() {
    local api_response="$1"
    local system_arch=$(uname -m)
    local os_type=$(uname -s)
    local libc_type="unknown"      
    local bit_arch=$(getconf LONG_BIT)
    local distro=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')

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

    # Detect libc type
    if [[ "$os_type" == "Linux" ]]; then
        if ldd --version 2>&1 | grep -qE "musl"; then
            libc_type="musl"
        elif ldd --version 2>&1 | grep -qE "GNU|GLIBC"; then
            libc_type="gnu"
        fi
    fi

    while IFS= read -r asset_info; do
        name=$(echo "$asset_info" | jq -r '.name')
        url=$(echo "$asset_info" | jq -r '.url')

        if [[ "$name" =~ ${EXCLUDED_PATTERNS[$system_arch]} ]]; then
            [[ ${#excluded_assets[@]} -gt 0 ]] && excluded_assets+=(",")
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"excluded pattern\",\"url\":\"$url\"}")
            continue    
        elif [[ "$name" =~ [sS]ource[._-?][Cc]ode ]]; then
            [[ ${#source_files[@]} -gt 0 ]] && source_files+=(",")
            source_files+=("{\"name\":\"$name\",\"url\":\"$url\"}")
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"source code archive\",\"url\":\"$url\"}")
            continue
        elif [[ "$name" =~ ^completions[^/]*\.(tar\.gz|tgz)$ ]]; then
            [[ ${#completions_files[@]} -gt 0 ]] && completions_files+=(",")
            completions_files+=("{\"name\":\"$name\",\"url\":\"$url\"}")
            excluded_assets+=("{\"name\":\"$name\",\"reason\":\"completions files\",\"url\":\"$url\"}")
        elif [[ "$name" =~ ^man[^/]*\.(tar\.gz|tgz)$ ]]; then
            [[ ${#man_files[@]} -gt 0 ]] && man_files+=(",")
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
            [[ ${#viable_assets[@]} -gt 0 ]] && viable_assets+=(",")
            viable_assets+=("$asset_json")
            
            if [[ $score -gt $chosen_score ]]; then
                chosen_asset="$asset_json"
                chosen_score=$score
                chosen_reason="$reason"
            fi
        fi
    done < <(echo "$api_response" | jq -r '.assets[] | {name: .name, url: .browser_download_url} | @json')

    # Construct the final JSON with proper formatting
    echo "{
        \"chosen\": ${chosen_asset:-null},
        \"viable\": [${viable_assets[*]}],
        \"excluded\": [${excluded_assets[*]}],
        \"source\": [${source_files[*]}],
        \"man\": [${man_files[*]}],
        \"completions\": [${completions_files[*]}]
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
            process_asset_data "$api_response" | jq -r '.completions[] | "\(.name)\t\(.url)"' ;;
        
        "man-files")
            process_asset_data "$api_response" | jq -r '.man[] | "\(.name)\t\(.url)"' ;;

        *)
            log "ERROR" "Unknown operation $operation" 
            return 1 ;;
    esac
}

main() {
    local repo_name="$1"

    if ! api_response=$(query_github_api "$repo_name"); then
        log "ERROR" "Unable to fetch response"
    fi 
    
    # Use process_api_response to get latest version
    latest_version=$(process_api_response "latest-version" "$api_response")

    # Fetch download url for an asset:
    file="zoxide-0.9.6-i686-unknown-linux-musl.tar.gz"
    download_url_for_asset=$(process_api_response "download-url" "$api_response" "$file")
    raw_asset_data=$(process_asset_data "$api_response")
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Unable to process"
    fi
    #best_asset=$(process_api_response "choose-best-asset" "$api_response")
    # assets=$(process_api_response "asset-names" "$api_response")



    # Print summary: 
    echo "Repo: $repo_name"
    echo "Latest version: $latest_version"
    echo "Download URL for $file is $download_url_for_asset"
    echo "Best asset: $best_asset"
    echo "Assets: $assets"
    echo "$raw_asset_data" | jq '.'
    #echo "$api_response" | jq '.'


}

# Run main function with all arguments only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
