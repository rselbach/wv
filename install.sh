#!/usr/bin/env bash
set -euo pipefail

# Enable dry run mode by setting this to true
DRY_RUN=false

# --- Logging --------------------------------------------------------------- #

log() {
    local msg="$1"
    local important="${2:-false}"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"

    if [[ "$important" == "true" ]]; then
        printf '\033[1;33m[%s] %s\033[0m\n' "$timestamp" "$msg"
    else
        printf '[%s] %s\n' "$timestamp" "$msg"
    fi
}

# --- Stop Zen browser ------------------------------------------------------- #

stop_zen() {
    if pgrep -x "zen" > /dev/null 2>&1; then
        log "zen is running. Attempting to stop it gracefully."
        if [[ "$DRY_RUN" == "true" ]]; then
            log "Dry run enabled. Skipping stopping zen."
        else
            pkill -x "zen" || true
            sleep 5
        fi
    else
        log "zen is not running."
    fi
}

# --- Detect OS and architecture --------------------------------------------- #

detect_platform() {
    local uname_s uname_m
    uname_s="$(uname -s)"
    uname_m="$(uname -m)"

    case "$uname_s" in
        Linux)
            OS="Linux"
            ARCH="x86_64-gcc3"
            PROFILES_DIR="$HOME/.zen/Profiles"
            ;;
        Darwin)
            OS="Darwin"
            case "$uname_m" in
                arm64|aarch64) ARCH="aarch64-gcc3" ;;
                *)             ARCH="x86_64-gcc3"  ;;
            esac
            PROFILES_DIR="$HOME/Library/Application Support/zen/Profiles"
            ;;
        *)
            log "Unsupported operating system: $uname_s. Exiting." true
            exit 1
            ;;
    esac

    PLATFORM_KEY="${OS}_${ARCH}"
    log "Detected OS: $OS, Architecture: $ARCH."
}

# --- Main ------------------------------------------------------------------- #

main() {
    log "Starting Widevine CDM installation script."

    stop_zen
    detect_platform

    local json_url="https://raw.githubusercontent.com/mozilla/gecko-dev/master/toolkit/content/gmp-sources/widevinecdm.json"

    log "Downloading and parsing JSON file from $json_url."
    local json_data
    json_data="$(curl -fsSL "$json_url")"

    local vendor_path=".vendors.\"gmp-widevinecdm\""

    # Check for alias and resolve if needed
    local alias_val
    alias_val="$(echo "$json_data" | jq -r "${vendor_path}.platforms.\"${PLATFORM_KEY}\".alias // empty")"

    local resolved_key="$PLATFORM_KEY"
    if [[ -n "$alias_val" ]]; then
        log "Alias detected for $PLATFORM_KEY. Resolving to $alias_val."
        resolved_key="$alias_val"
    fi

    local zip_url version
    zip_url="$(echo "$json_data" | jq -r "${vendor_path}.platforms.\"${resolved_key}\".fileUrl")"
    version="$(echo "$json_data" | jq -r "${vendor_path}.version")"

    log "Will download ZIP file from: $zip_url"
    log "Widevine version: $version"

    local zip_file
    zip_file="$(mktemp /tmp/widevine-XXXXXX.zip)"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry run enabled. Skipping download of $zip_url."
    else
        log "Downloading ZIP file to $zip_file."
        curl -fsSL "$zip_url" -o "$zip_file"
    fi

    log "Searching for profiles in $PROFILES_DIR."

    if [[ ! -d "$PROFILES_DIR" ]]; then
        log "Profiles directory not found: $PROFILES_DIR. Exiting." true
        rm -f "$zip_file"
        exit 1
    fi

    for profile_dir in "$PROFILES_DIR"/*/; do
        [[ -d "$profile_dir" ]] || continue

        local target_dir="${profile_dir}gmp-widevinecdm/${version}"

        # Clean out existing files
        if [[ -d "$target_dir" ]]; then
            log "Cleaning out existing files in $target_dir"
            if [[ "$DRY_RUN" == "true" ]]; then
                log "Dry run enabled. Skipping cleaning of $target_dir."
            else
                rm -rf "${target_dir:?}"/*
            fi
        fi

        # Create directory
        log "Preparing to create directory: $target_dir"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "Dry run enabled. Skipping directory creation."
        else
            if [[ ! -d "$target_dir" ]]; then
                log "Creating directory: $target_dir"
                mkdir -p "$target_dir"
            else
                log "Directory already exists: $target_dir"
            fi
        fi

        # Extract ZIP
        log "Preparing to extract ZIP to: $target_dir"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "Dry run enabled. Skipping ZIP extraction."
        else
            unzip -o "$zip_file" -d "$target_dir"
        fi

        # Update user.js
        local user_js="${profile_dir}user.js"
        log "Preparing to update user.js at: $user_js"

        if [[ "$DRY_RUN" == "true" ]]; then
            log "Dry run enabled. Skipping user.js modification."
        else
            local -a prefs=(
                "user_pref('media.gmp-widevinecdm.visible', true);"
                "user_pref('media.gmp-widevinecdm.enabled', true);"
                "user_pref('media.gmp-manager.url', 'https://aus5.mozilla.org/update/3/GMP/%VERSION%/%BUILD_ID%/%BUILD_TARGET%/%LOCALE%/%CHANNEL%/%OS_VERSION%/%DISTRIBUTION%/%DISTRIBUTION_VERSION%/update.xml');"
                "user_pref('media.gmp-provider.enabled', true);"
            )

            for pref in "${prefs[@]}"; do
                if [[ -f "$user_js" ]] && grep -qF "$pref" "$user_js"; then
                    continue
                fi
                log "Adding preference: $pref"
                echo "$pref" >> "$user_js"
            done

            if [[ -f "$user_js" ]]; then
                log "Preferences already exist or have been added to user.js."
            fi
        fi
    done

    # Clean up
    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry run enabled. Skipping ZIP file cleanup."
    else
        log "Cleaning up ZIP file: $zip_file"
        rm -f "$zip_file"
    fi

    log "Widevine CDM installation script completed."
}

main "$@"
