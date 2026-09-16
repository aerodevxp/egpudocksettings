#!/bin/bash

## ==============================================================================
## BASIC VARIABLES
## ==============================================================================
ROOTDIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DOCK_DIR="$ROOTDIR/docksettings"
MAP_FILE="$DOCK_DIR/master_map.txt"
STATE_FILE="$DOCK_DIR/global_state"
DATE=$(date '+%d-%m-%Y %H:%M:%S')
DB="$ROOTDIR/docksettings_db.csv"
LOCKDIR="/tmp/docksettings"
TEMPFILE="/tmp/docksettings_steam_find.tmp"

## Profile Directories
IGPU_PROFILES="$DOCK_DIR/profiles/igpu"
EGPU_PROFILES="$DOCK_DIR/profiles/egpu"
BACKUP_DIR="$DOCK_DIR/backups"
SHADER_DIR="$DOCK_DIR/shaders"
MESA_IGPU_SHADER="$SHADER_DIR/mesa_igpu"
MESA_EGPU_SHADER="$SHADER_DIR/mesa_egpu"
DXVK_IGPU_SHADER="$SHADER_DIR/dxvk_igpu"
DXVK_EGPU_SHADER="$SHADER_DIR/dxvk_egpu"

## ==============================================================================
## DEBUG HELPERS
## ==============================================================================
debug() {
    echo "$DATE [DEBUG] $1"
    echo "$DATE [DEBUG] $1" >> "$DOCK_DIR/global.log"
}

info() {
    echo "$DATE [INFO] $1"
    echo "$DATE [INFO] $1" >> "$DOCK_DIR/global.log"
}

warn() {
    echo "$DATE [WARN] $1"
    echo "$DATE [WARN] $1" >> "$DOCK_DIR/global.log"
}

error() {
    echo "$DATE [ERROR] $1"
    echo "$DATE [ERROR] $1" >> "$DOCK_DIR/global.log"
}

# Get a quick hash of file content for comparison
file_hash() {
    if [ -f "$1" ]; then
        md5sum "$1" 2>/dev/null | cut -d' ' -f1
    else
        echo "FILE_NOT_FOUND"
    fi
}

## ==============================================================================
## THE ENGINE: DISCOVERY & MAPPING
## ==============================================================================

crawl_and_register() {
    > "$DOCK_DIR/global.log"
    info "========== STARTING SCAN =========="
    debug "Log file cleared and initialized"

    # Define the target zone patterns. CHANGE THIS IF YOU HAVE AN EXTERNAL DRIVE. My personal games partition is mount under /run/media/system/GAMES/ hence why this is here.
    local zone_patterns=(
        "/home/deck/.steam/steam/steamapps/compatdata/*/pfx/drive_c/users/steamuser/"
        "/run/media/system/GAMES/steamapps/compatdata/*/pfx/drive_c/users/steamuser/"
        "/home/deck/.steam/steam/steamapps/common/*/"
        "/run/media/system/GAMES/steamapps/common/*/"
    )

    debug "Zone patterns defined: ${#zone_patterns[@]} patterns"
    for i in "${!zone_patterns[@]}"; do
        debug "  Pattern [$i]: ${zone_patterns[$i]}"
    done

    local found_files=()
    local scanned_count=0
    local excluded_count=0

    # =====================================================================
    # 1. CRAWL THE STEAM PREFIXS
    # =====================================================================
    info "========== PHASE 1: STEAM ZONE SCAN =========="
    > "$TEMPFILE"
    # CHANGE THIS IF YOU HAVE AN EXTERNAL DRIVE
    steam_roots=(
        "/home/deck/.steam/steam/steamapps/compatdata"
        "/run/media/system/GAMES/steamapps/compatdata"
        "/home/deck/.steam/steam/steamapps/common/"
        "/run/media/system/GAMES/steamapps/common/"
    )
    
    for root in "${steam_roots[@]}"; do
        debug "Scanning: $root"
    
        [ ! -d "$root" ] && {
            warn "Directory not found: $root"
            continue
        }
    
        find "$root" \
            -type f \
            -path "*/pfx/drive_c/users/steamuser/*" \
            \( \
                -iname "*.ini" -o \
                -iname "*.cfg" -o \
                -iname "*.json" -o \
                -iname "*.xml" \
            \) \
            -print0 2>/dev/null |
        while IFS= read -r -d '' file; do
            echo "$file" >> "$TEMPFILE"
        done
    done
    
    while IFS= read -r file; do
        lower_file="${file,,}"
    
        if [[ "$lower_file" == *steamlinuxruntime* ]] ||
           [[ "$lower_file" == *proton* ]] ||
           [[ "$lower_file" == *crashreport* ]]; then
            debug "EXCLUDED: $file"
            ((excluded_count++))
        else
            found_files+=("$file")
            ((scanned_count++))
        fi
    done < "$TEMPFILE"
    
    rm -f "$TEMPFILE"
    
    info "Steam zone scan complete. Files found: $scanned_count, Excluded: $excluded_count"
    # =====================================================================
    # 2. CRAWL THE CSV (UNFILTERED - ALL FILES)
    # =====================================================================
    info "========== PHASE 2: CSV SCAN =========="
    debug "CSV file location: $DB"
    
    local csv_files=0
    local csv_excluded=0
    
    if [ -f "$DB" ]; then
        debug "CSV file exists"
        while IFS= read -r entry || [[ -n "$entry" ]]; do
            entry="${entry#"${entry%%[![:space:]]*}"}"
            entry="${entry%"${entry##*[![:space:]]}"}"
            [ -z "$entry" ] && continue

            debug "  CSV entry: '$entry'"

            if [ -d "$entry" ]; then
                debug "  -> Entry is a DIRECTORY"
                local dir_count=0

                while IFS= read -r -d '' file; do
                    if [ -n "$file" ]; then
                        local lower_file=$(echo "$file" | tr '[:upper:]' '[:lower:]')
                        
                        if [[ "$lower_file" == *"crashreport"* ]]; then
                            debug "    EXCLUDED: $file"
                            csv_excluded=$((csv_excluded + 1))
                        else
                            found_files+=("$file")
                            csv_files=$((csv_files + 1))
                            dir_count=$((dir_count + 1))
                        fi
                    fi
                done < <(find -L "$entry" -type f -print0 2>/dev/null)

                debug "  -> Directory contributed $dir_count files"

            elif [ -f "$entry" ]; then
                debug "  -> Entry is a FILE"
                found_files+=("$entry")
                csv_files=$((csv_files + 1))
            else
                warn "  -> Entry NOT FOUND: $entry"
            fi
        done < "$DB"
        
        info "CSV scan complete. Files from CSV: $csv_files, Excluded: $csv_excluded"
    else
        warn "CSV file not found: $DB"
        touch "$DB"
    fi

    info "========== PHASE 3: TOTAL FILES =========="
    info "Total unique files discovered: ${#found_files[@]}"

    # =====================================================================
    # 3. REGISTER FILES
    # =====================================================================
    info "========== PHASE 4: REGISTRATION =========="
    
    mkdir -p "$IGPU_PROFILES" "$EGPU_PROFILES" "$BACKUP_DIR"
    touch "$MAP_FILE"

    local existing_count=$(wc -l < "$MAP_FILE" 2>/dev/null || echo 0)
    debug "Existing map entries: $existing_count"

    local registered_count=0
    local skipped_count=0

    for file_path in "${found_files[@]}"; do
        [ -z "$file_path" ] && continue

        if grep -qF "$file_path" "$MAP_FILE" 2>/dev/null; then
            skipped_count=$((skipped_count + 1))
        else
            local id="ID_$(($(wc -l < "$MAP_FILE" 2>/dev/null) + 1))"
            
            debug "REGISTERING: $file_path"
            debug "  -> Assigned ID: $id"
            
            echo "$id | $file_path" >> "$MAP_FILE"

            local filename=$(basename "$file_path")
            
            # ONLY create profile files if they don't exist
            # This preserves existing configurations!
            if [ -f "$file_path" ]; then
                # Backup - always create
                cp -p "$file_path" "$BACKUP_DIR/${id}_${filename}" 2>/dev/null && \
                    debug "  -> Backup created: ${id}_${filename}" || \
                    warn "  -> Backup FAILED: ${id}_${filename}"
                
                # iGPU profile - only if doesn't exist
                if [ ! -f "$IGPU_PROFILES/$id" ]; then
                    cp -p "$file_path" "$IGPU_PROFILES/$id" 2>/dev/null && \
                        debug "  -> iGPU profile created (NEW)" || \
                        warn "  -> iGPU profile FAILED"
                else
                    debug "  -> iGPU profile EXISTS, preserving"
                fi
                
                # eGPU profile - only if doesn't exist
                if [ ! -f "$EGPU_PROFILES/$id" ]; then
                    cp -p "$file_path" "$EGPU_PROFILES/$id" 2>/dev/null && \
                        debug "  -> eGPU profile created (NEW)" || \
                        warn "  -> eGPU profile FAILED"
                else
                    debug "  -> eGPU profile EXISTS, preserving"
                fi
            else
                warn "  -> Source file does not exist: $file_path"
            fi

            registered_count=$((registered_count + 1))
            echo "TRACKED: $file_path"
        fi
    done

    info "Registration complete"
    info "  - New registrations: $registered_count"
    info "  - Already tracked: $skipped_count"
    info "  - Total in map: $(wc -l < "$MAP_FILE" 2>/dev/null || echo 0)"

    # =====================================================================
    # 4. DISPLAY ALL TRACKED FILES WITH HASHES
    # =====================================================================
    info "========== ALL TRACKED FILES =========="
    
    if [ -f "$MAP_FILE" ]; then
        while IFS='|' read -r id filepath; do
            id="${id#"${id%%[![:space:]]*}"}"
            id="${id%"${id##*[![:space:]]}"}"
            
            filepath="${filepath#"${filepath%%[![:space:]]*}"}"
            filepath="${filepath%"${filepath##*[![:space:]]}"}"
            
            local live_hash=$(file_hash "$filepath")
            local igpu_hash=$(file_hash "$IGPU_PROFILES/$id")
            local egpu_hash=$(file_hash "$EGPU_PROFILES/$id")
            
            echo "  [$id] $filepath"
            debug "      LIVE:  $live_hash"
            debug "      iGPU:  $igpu_hash"
            debug "      eGPU:  $egpu_hash"
        done < "$MAP_FILE"
    else
        warn "No map file found"
    fi
}

swap_shaders() {
    local target_state="$1"
    local mesa_target dxvk_target

    if [ "$target_state" = "egpu" ]; then
        mesa_target="$MESA_EGPU_SHADER"
        dxvk_target="$DXVK_EGPU_SHADER"
    else
        mesa_target="$MESA_IGPU_SHADER"
        dxvk_target="$DXVK_IGPU_SHADER"
    fi

    mkdir -p "$mesa_target" "$dxvk_target"

    # Write env vars to a file that gets sourced at game launch
    local env_file="$DOCK_DIR/current_gpu_env.sh"
    cat > "$env_file" <<EOF
export MESA_SHADER_CACHE_DIR="$mesa_target"
export DXVK_STATE_CACHE_PATH="\$STEAM_COMPAT_DATA_PATH/dxvk-state-cache"
EOF

    # Symlink DXVK caches per-game (this part is fine, DXVK follows symlinks)
    # But ALSO set the env var as backup
    info "Shader env written to $env_file"
    info "Mesa cache dir: $mesa_target"
    info "DXVK cache dir: $dxvk_target"
}

perform_swap() {
    local target_state="$1"
    local current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

    

    info "========== PERFORMING SWAP =========="
    debug "Target state: $target_state"
    debug "Current state (from file): $current_state"
    debug "State file location: $STATE_FILE"
    
    if [ "$target_state" = "$current_state" ] && [ "$current_state" != "unknown" ]; then
        echo "Already in $target_state mode — nothing to do. Files will not be backed up and replaced."
        return 0
    fi
    local save_to_dir=""
    local load_from_dir=""

    # Determine direction - FIXED: Handle "unknown" state
    if [ "$target_state" = "egpu" ]; then
        load_from_dir="$EGPU_PROFILES"
        if [ "$current_state" = "igpu" ]; then
            save_to_dir="$IGPU_PROFILES"
            debug "Direction: iGPU -> eGPU (backup iGPU, load eGPU)"
        elif [ "$current_state" = "unknown" ]; then
            # First run - backup to BOTH profiles, then load target
            debug "Direction: UNKNOWN -> eGPU (first run detected)"
            debug "  Will backup current files to BOTH iGPU and eGPU profiles"
        else
            debug "Direction: eGPU -> eGPU (no backup needed, just reload)"
        fi
    else
        load_from_dir="$IGPU_PROFILES"
        if [ "$current_state" = "egpu" ]; then
            save_to_dir="$EGPU_PROFILES"
            debug "Direction: eGPU -> iGPU (backup eGPU, load iGPU)"
        elif [ "$current_state" = "unknown" ]; then
            # First run - backup to BOTH profiles, then load target
            debug "Direction: UNKNOWN -> iGPU (first run detected)"
            debug "  Will backup current files to BOTH iGPU and eGPU profiles"
        else
            debug "Direction: iGPU -> iGPU (no backup needed, just reload)"
        fi
    fi

    debug "Save to: ${save_to_dir:-<none>}"
    debug "Load from: $load_from_dir"

    local backup_count=0
    local apply_count=0
    local missing_count=0
    local unknown_backups=0

    while IFS='|' read -r id filepath; do
        id="${id#"${id%%[![:space:]]*}"}"
        id="${id%"${id##*[![:space:]]}"}"
        filepath="${filepath#"${filepath%%[![:space:]]*}"}"
        filepath="${filepath%"${filepath##*[![:space:]]}"}"

        
        [ -z "$id" ] && continue
        [ -z "$filepath" ] && continue

        debug "--------------------------------------------------"
        debug "Processing: [$id] $filepath"

        local live_hash=$(file_hash "$filepath")
        debug "  LIVE file hash: $live_hash"

        # Handle "unknown" current state - backup to BOTH profiles
        if [ "$current_state" = "unknown" ] && [ -f "$filepath" ]; then
            if [ "$DRYRUN" = "1" ]; then
                info "  DRY RUN: Would backup to BOTH profiles (first run)"
            else
                local igpu_hash=$(file_hash "$IGPU_PROFILES/$id")
                local egpu_hash=$(file_hash "$EGPU_PROFILES/$id")
                
                cp -p "$filepath" "$IGPU_PROFILES/$id" 2>/dev/null && \
                    debug "  -> Backed up to iGPU profile" || \
                    warn "  -> iGPU backup FAILED"
                
                cp -p "$filepath" "$EGPU_PROFILES/$id" 2>/dev/null && \
                    debug "  -> Backed up to eGPU profile" || \
                    warn "  -> eGPU backup FAILED"
                
                unknown_backups=$((unknown_backups + 1))
            fi
        fi

        # Normal backup (when current_state is known)
        if [ -n "$save_to_dir" ] && [ -f "$filepath" ]; then
            local target_hash=$(file_hash "$save_to_dir/$id")
            
            if [ "$DRYRUN" = "1" ]; then
                info "  DRY RUN: Would backup $filepath to $save_to_dir/$id"
            else
                debug "  Current profile hash: $target_hash"
                
                if cp -p "$filepath" "$save_to_dir/$id" 2>/dev/null; then
                    local new_hash=$(file_hash "$save_to_dir/$id")
                    debug "  -> Backed up to: $save_to_dir/$id"
                    debug "  -> New profile hash: $new_hash"
                    backup_count=$((backup_count + 1))
                else
                    warn "  -> Backup FAILED for: $filepath"
                fi
            fi
        elif [ -z "$save_to_dir" ] && [ "$current_state" != "unknown" ]; then
            debug "  -> No backup needed (same mode)"
        elif [ ! -f "$filepath" ]; then
            warn "  -> Source file missing: $filepath"
            missing_count=$((missing_count + 1))
        fi

        # Apply target profile
        if [ -f "$load_from_dir/$id" ]; then
            local profile_hash=$(file_hash "$load_from_dir/$id")
            
            if [ "$DRYRUN" = "1" ]; then
                info "  DRY RUN: Would apply $load_from_dir/$id to $filepath"
            else
                debug "  Profile to apply hash: $profile_hash"
                
                if cp -p "$load_from_dir/$id" "$filepath" 2>/dev/null; then
                    local applied_hash=$(file_hash "$filepath")
                    debug "  -> Applied profile from: $load_from_dir/$id"
                    debug "  -> Applied file hash: $applied_hash"
                    apply_count=$((apply_count + 1))
                else
                    warn "  -> Apply FAILED for: $filepath"
                fi
            fi
        else
            warn "  -> No profile found at: $load_from_dir/$id"
        fi
    done < "$MAP_FILE"

    info "Swap summary:"
    info "  - Files backed up (normal): $backup_count"
    info "  - Files backed up (first run): $unknown_backups"
    info "  - Files applied: $apply_count"
    info "  - Files missing: $missing_count"
    
    #swap_shaders "$target_state"
    
    # Update state
    echo "$target_state" > "$STATE_FILE"
    info "State updated: Now in $target_state mode"
    debug "State file content: $(cat "$STATE_FILE")"
}

## ==============================================================================
## HELP & OPTIONS
## ==============================================================================

help() {
    echo "ROG Ally X Absolute GPU Automation v1.23"
    echo "-----------------------------------------"
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -g [state]  Target GPU state (igpu/egpu)"
    echo "  -d          Dry run: Log changes without writing"
    echo "  -h          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -g egpu    # Update map and switch to eGPU"
    echo "  $0 -g igpu    # Update map and switch to iGPU"
    echo "  $0 -g egpu -d # Dry run (test without changes)"
    echo ""
    echo "State file: $STATE_FILE"
    echo "  Current state: $(cat "$STATE_FILE" 2>/dev/null || echo "unknown")"
}

while getopts "hug:d" option; do
    case $option in
        h) help; exit 0;;
        g) GPU_OVERRIDE="$OPTARG";;
        d) DRYRUN=1;;
        \?) error "Invalid option"; exit 1;;
    esac
done

## ==============================================================================
## MAIN EXECUTION
## ==============================================================================

debug "========== SCRIPT STARTING =========="
debug "Arguments: $*"
debug "GPU_OVERRIDE: ${GPU_OVERRIDE:-not set}"
debug "DRYRUN: ${DRYRUN:-not set}"

# Create lock
mkdir -p "$LOCKDIR"
LOCKFILE="$LOCKDIR/global.lock"

if [ -f "$LOCKFILE" ]; then
    PID=$(cat "$LOCKFILE")
    if kill -0 "$PID" 2>/dev/null; then
        error "Another instance is running (PID: $PID)"
        exit 1
    else
        warn "Stale lock file found, removing"
        rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$LOCKFILE"
trap "rm -f '$LOCKFILE'" EXIT

# Initialize state file if missing
if [ ! -f "$STATE_FILE" ]; then
    warn "No state file found, initializing to 'unknown'"
    echo "unknown" > "$STATE_FILE"
fi

debug "Current state before processing: $(cat "$STATE_FILE")"

# 1. ALWAYS Crawl and Register
crawl_and_register

# 2. Handle Swap
if [ -n "$GPU_OVERRIDE" ]; then
    perform_swap "$GPU_OVERRIDE"
else
    help
fi

info "========== SCRIPT COMPLETE =========="
exit 0
