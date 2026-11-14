#!/bin/bash

## ==============================================================================
## BASIC VARIABLES
## ==============================================================================
ROOTDIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DOCK_DIR="$ROOTDIR/docksettings"
MAP_FILE="$DOCK_DIR/master_map.txt"
STATE_FILE="$DOCK_DIR/global_state"
SWAP_MARKER="$DOCK_DIR/.swap_in_progress"
DATE=$(date '+%d-%m-%Y %H:%M:%S')
DB="$ROOTDIR/docksettings_db.csv"
LOCKDIR="/tmp/docksettings"
TEMPFILE="/tmp/docksettings_steam_find.tmp"

## Profile Directories
IGPU_PROFILES="$DOCK_DIR/profiles/igpu"
EGPU_PROFILES="$DOCK_DIR/profiles/egpu"
BACKUP_DIR="$DOCK_DIR/backups"

## Cache Engine (symlink-swapped, same model as the fossilize cache)
CACHE_DIR="$DOCK_DIR/cachedata"
CACHE_MAP="$CACHE_DIR/cache_map.txt"
CACHE_IGPU_PROFILES="$CACHE_DIR/profiles/igpu"
CACHE_EGPU_PROFILES="$CACHE_DIR/profiles/egpu"
CACHE_DB="$ROOTDIR/cachesettings_db.csv"
CACHE_LINKED=0
CACHE_MIGRATED=0

## Target user — cache paths live under their $HOME
USER_NAME=$(getent passwd 1000 | cut -d: -f1)
[ -z "$USER_NAME" ] && USER_NAME="deck"
USER_UID=$(id -u "$USER_NAME" 2>/dev/null || echo 1000)
USER_HOME=$(getent passwd 1000 | cut -d: -f6)
[ -z "$USER_HOME" ] && USER_HOME="/home/$USER_NAME"

## Live driver cache locations (env overrides respected)
CACHE_HOME="${XDG_CACHE_HOME:-$USER_HOME/.cache}"
MESA_CACHE_LIVE="${MESA_SHADER_CACHE_DIR:-$CACHE_HOME/mesa_shader_cache}"
VKD3D_CACHE_LIVE="${VKD3D_SHADER_CACHE_PATH:-$CACHE_HOME/vkd3d}"

## Steam roots — CHANGE THIS IF YOU HAVE AN EXTERNAL DRIVE
STEAM_ROOTS=(
    "/home/deck/.steam/steam/steamapps/compatdata"
    "/run/media/system/GAMES/steamapps/compatdata"
    "/home/deck/.steam/steam/steamapps/common"
    "/run/media/system/GAMES/steamapps/common"
)

## Flags
TRUST_LIVE=1    # 1 = trust live files for backup, 0 = skip backup (crash recovery)
FORCE_APPLY=0   # 1 = re-apply even if already in target state
DRYRUN=0
SKIP_CACHE=0

## ==============================================================================
## CRASH-SAFE HELPERS
## ==============================================================================

sync_file() {
    sync "$1" 2>/dev/null || sync
}

atomic_write() {
    local content="$1"
    local file="$2"
    local tmp="${file}.tmp.$$"
    printf '%s\n' "$content" > "$tmp"
    sync_file "$tmp"
    mv "$tmp" "$file"
    sync_file "$file"
}

atomic_remove() {
    local file="$1"
    rm -f "$file"
    sync_file "$(dirname "$file")"
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Run a command as the deck user when we're root
as_user() {
    if [ "$(id -u)" -eq 0 ] && [ "$USER_NAME" != "root" ]; then
        sudo -u "$USER_NAME" "$@"
    else
        "$@"
    fi
}

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

file_hash() {
    if [ -f "$1" ]; then
        md5sum "$1" 2>/dev/null | cut -d' ' -f1
    else
        echo "FILE_NOT_FOUND"
    fi
}

## ==============================================================================
## GPU STATE DETECTION
## ==============================================================================

detect_gpu_state() {
    local render_count=$(ls /dev/dri/renderD* 2>/dev/null | wc -l)

    local gpu_count=0
    if command -v lspci &>/dev/null; then
        gpu_count=$(lspci 2>/dev/null | grep -cE "VGA compatible|3D controller|Display controller")
    fi

    debug "detect_gpu_state: render_nodes=$render_count, gpu_controllers=$gpu_count"

    if [ "$render_count" -gt 1 ] || [ "$gpu_count" -gt 1 ]; then
        echo "egpu"
    else
        echo "igpu"
    fi
}

## ==============================================================================
## CACHE ENGINE
## ==============================================================================

cache_id_for_path() {
    awk -F'|' -v p="$1" '{
        gsub(/^[ \t]+|[ \t]+$/, "", $1)
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        if ($2 == p) { print $1; exit }
    }' "$CACHE_MAP" 2>/dev/null
}

ensure_cache_profile() {
    local cid="$1" type="$2" st="$3"
    local base="$CACHE_IGPU_PROFILES"
    [ "$st" = "egpu" ] && base="$CACHE_EGPU_PROFILES"

    if [ "$type" = "dir" ]; then
        as_user mkdir -p "$base/$cid" 2>/dev/null
    else
        [ -f "$base/$cid" ] || as_user touch "$base/$cid" 2>/dev/null
    fi
}

# Register a cache path once: seed the current GPU's profile with whatever is
# live right now, then convert the live path into a symlink into that profile.
register_cache_entry() {
    local path
    path=$(trim "$1")
    local type="$2"
    [ -z "$path" ] && return 0

    local existing
    existing=$(cache_id_for_path "$path")
    if [ -n "$existing" ]; then
        debug "  CACHE already tracked: [$existing] $path"
        return 0
    fi

    # Allocate a non-colliding cache ID
    local n
    n=$(grep -c '^C_' "$CACHE_MAP" 2>/dev/null)
    [ -z "$n" ] && n=0
    local cid="C_$((n + 1))"
    while grep -q "^${cid} |" "$CACHE_MAP" 2>/dev/null; do
        n=$((n + 1))
        cid="C_$((n + 1))"
    done

    if [ "$DRYRUN" = "1" ]; then
        info "  DRY RUN: Would register cache [$cid] ($type) $path"
        echo "$cid | $path | $type" >> "$CACHE_MAP"
        return 0
    fi

    debug "REGISTERING CACHE: ($type) $path -> [$cid]"

    as_user mkdir -p "$(dirname "$path")" 2>/dev/null

    local hw
    hw=$(detect_gpu_state)
    local state_dir="$CACHE_EGPU_PROFILES"
    [ "$hw" = "igpu" ] && state_dir="$CACHE_IGPU_PROFILES"

    ensure_cache_profile "$cid" "$type" "igpu"
    ensure_cache_profile "$cid" "$type" "egpu"

    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ "$type" = "dir" ]; then
            as_user rsync -a "$path/" "$state_dir/$cid/" 2>/dev/null && \
                debug "  -> Seeded $hw profile" || \
                warn "  -> Seed FAILED for: $path"
        else
            as_user cp -p "$path" "$state_dir/$cid" 2>/dev/null && \
                debug "  -> Seeded $hw cache file" || \
                warn "  -> Seed FAILED for: $path"
        fi
        as_user rm -rf "$path" 2>/dev/null
    else
        debug "  -> Live path absent, will be created as symlink"
    fi

    if as_user ln -sfn "$state_dir/$cid" "$path" 2>/dev/null; then
        debug "  -> Symlinked: $path -> $state_dir/$cid"
    else
        warn "  -> Symlink FAILED for: $path"
    fi

    chown -R "$USER_UID:$USER_UID" "$state_dir/$cid" 2>/dev/null
    echo "$cid | $path | $type" >> "$CACHE_MAP"
}

swap_cache() {
    local target="$1"
    local target_base="$CACHE_IGPU_PROFILES"
    [ "$target" = "egpu" ] && target_base="$CACHE_EGPU_PROFILES"

    CACHE_LINKED=0
    CACHE_MIGRATED=0

    if [ ! -s "$CACHE_MAP" ]; then
        info "No cache entries registered — nothing to swap"
        return 0
    fi

    while IFS='|' read -r cid path type; do
        cid=$(trim "$cid")
        path=$(trim "$path")
        type=$(trim "$type")
        [ -z "$cid" ] && continue
        [ -z "$path" ] && continue
        [ "$type" = "file" ] || type="dir"

        debug "CACHE: [$cid] ($type) $path -> $target"

        if [ "$DRYRUN" = "1" ]; then
            info "  DRY RUN: Would point $path -> $target_base/$cid"
            CACHE_LINKED=$((CACHE_LINKED + 1))
            continue
        fi

        ensure_cache_profile "$cid" "$type" "$target"
        as_user mkdir -p "$(dirname "$path")" 2>/dev/null

        if [ -L "$path" ]; then
            as_user ln -sfn "$target_base/$cid" "$path" 2>/dev/null && \
                debug "  -> Repointed symlink" || \
                warn "  -> Repoint FAILED for: $path"
            CACHE_LINKED=$((CACHE_LINKED + 1))
        elif [ -e "$path" ]; then
            debug "  -> Real path present (crash/unregistered) — migrating into target profile"
            if [ "$type" = "dir" ]; then
                as_user rsync -a "$path/" "$target_base/$cid/" 2>/dev/null
            else
                as_user cp -p "$path" "$target_base/$cid" 2>/dev/null
            fi
            as_user rm -rf "$path" 2>/dev/null
            as_user ln -sfn "$target_base/$cid" "$path" 2>/dev/null
            CACHE_MIGRATED=$((CACHE_MIGRATED + 1))
        else
            as_user ln -sfn "$target_base/$cid" "$path" 2>/dev/null && \
                debug "  -> Created new symlink" || \
                warn "  -> Symlink FAILED for: $path"
            CACHE_LINKED=$((CACHE_LINKED + 1))
        fi
    done < "$CACHE_MAP"

    info "Cache swap summary: $CACHE_LINKED linked, $CACHE_MIGRATED migrated"
}

crawl_and_register_caches() {
    info "========== PHASE 6: CACHE REGISTRATION =========="

    mkdir -p "$CACHE_DIR"
    as_user mkdir -p "$CACHE_IGPU_PROFILES" "$CACHE_EGPU_PROFILES" 2>/dev/null
    touch "$CACHE_MAP"
    chown -R "$USER_UID:$USER_UID" "$CACHE_DIR" 2>/dev/null

    if [ ! -f "$CACHE_DB" ]; then
        cat > "$CACHE_DB" <<'EOF'
# cachesettings_db.csv — one cache path per line (directory or file).
# Lines starting with # are ignored.
#
# Always tracked automatically:
#   mesa shader cache(s), vkd3d cache, steam fossilize cache,
#   every *.dxvk-cache / *.vkd3d.cache found in Steam prefixes/game dirs.
#
# Add emulator / custom caches below (uncomment the ones you use):
#/home/deck/.cache/yuzu
#/home/deck/.cache/rpcs3
#/home/deck/.local/share/Cemu/shaderCache
#/home/deck/.cache/dolphin-emu
#/home/deck/.config/Ryujinx/games
#/home/deck/.cache/PCSX2
EOF
        info "Created cache DB template: $CACHE_DB"
    fi

    # Built-in driver caches (covers both old and new Mesa cache dir names)
    for m in "$CACHE_HOME"/mesa_shader_cache*; do
        [ -e "$m" ] && register_cache_entry "$m" "dir"
    done
    register_cache_entry "$VKD3D_CACHE_LIVE" "dir"
    [ -n "$DXVK_STATE_CACHE_PATH" ] && register_cache_entry "$DXVK_STATE_CACHE_PATH" "dir"

    # User-supplied cache list
    if [ -f "$CACHE_DB" ]; then
        while IFS= read -r entry || [ -n "$entry" ]; do
            entry=$(trim "$entry")
            [ -z "$entry" ] && continue
            [[ "$entry" == \#* ]] && continue
            if [ -d "$entry" ]; then
                register_cache_entry "$entry" "dir"
            elif [ -f "$entry" ]; then
                register_cache_entry "$entry" "file"
            else
                warn "Cache entry not found (will be created on swap): $entry"
                register_cache_entry "$entry" "dir"
            fi
        done < "$CACHE_DB"
    fi

    # Auto-discover per-game DXVK / VKD3D pipeline caches
    for root in "${STEAM_ROOTS[@]}"; do
        [ -d "$root" ] || continue
        debug "Cache scan: $root"
        while IFS= read -r -d '' cfile; do
            [[ "${cfile,,}" == *steamlinuxruntime* ]] && continue
            register_cache_entry "$cfile" "file"
        done < <(find "$root" -type f $$ -iname "*.dxvk-cache" -o -iname "*.vkd3d.cache" $$ -print0 2>/dev/null)
    done

    info "Cache registration complete. Tracked entries: $(grep -c '^C_' "$CACHE_MAP" 2>/dev/null || true)"
}

## ==============================================================================
## THE ENGINE: DISCOVERY & MAPPING
## ==============================================================================

crawl_and_register() {
    > "$DOCK_DIR/global.log"
    info "========== STARTING SCAN =========="

    local found_files=()
    local scanned_count=0
    local excluded_count=0

    # =====================================================================
    # 1. CRAWL THE STEAM PREFIXS
    # =====================================================================
    info "========== PHASE 1: STEAM ZONE SCAN =========="
    > "$TEMPFILE"

    for root in "${STEAM_ROOTS[@]}"; do
        debug "Scanning: $root"

        [ ! -d "$root" ] && {
            warn "Directory not found: $root"
            continue
        }

        find "$root" \
            -type f \
            -path "*/pfx/drive_c/users/steamuser/*" \
            $$ -iname "*.ini" -o -iname "*.cfg" -o -iname "*.json" -o -iname "*.xml" $$ \
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

            if [ -f "$file_path" ]; then
                cp -p "$file_path" "$BACKUP_DIR/${id}_${filename}" 2>/dev/null && \
                    debug "  -> Backup created: ${id}_${filename}" || \
                    warn "  -> Backup FAILED: ${id}_${filename}"

                if [ ! -f "$IGPU_PROFILES/$id" ]; then
                    cp -p "$file_path" "$IGPU_PROFILES/$id" 2>/dev/null && \
                        debug "  -> iGPU profile created (NEW)" || \
                        warn "  -> iGPU profile FAILED"
                else
                    debug "  -> iGPU profile EXISTS, preserving"
                fi

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
    # 4. DRIFT DETECTION
    # =====================================================================
    local file_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    local hw_state=$(detect_gpu_state)

    if [ "$FORCE_APPLY" = "1" ]; then
        info "========== DRIFT DETECTION SKIPPED (force/recovery mode) =========="
    elif [ "$file_state" != "$hw_state" ]; then
        info "========== DRIFT DETECTION SKIPPED (state mismatch: file=$file_state hw=$hw_state) =========="
    elif [ "$file_state" = "unknown" ]; then
        info "========== DRIFT DETECTION SKIPPED (unknown state) =========="
    else
        info "========== PHASE 5: DRIFT DETECTION =========="

        local sync_dir=""
        [ "$file_state" = "igpu" ] && sync_dir="$IGPU_PROFILES"
        [ "$file_state" = "egpu" ] && sync_dir="$EGPU_PROFILES"

        if [ -n "$sync_dir" ]; then
            local drift_count=0
            local synced_count=0

            while IFS='|' read -r id filepath; do
                id=$(trim "$id")
                filepath=$(trim "$filepath")

                [ -z "$id" ] && continue
                [ -z "$filepath" ] && continue

                if [ -f "$filepath" ] && [ -f "$sync_dir/$id" ]; then
                    local live_hash=$(file_hash "$filepath")
                    local profile_hash=$(file_hash "$sync_dir/$id")

                    if [ "$live_hash" != "$profile_hash" ]; then
                        debug "  DRIFT: [$id] $filepath -> syncing profile"
                        if cp -p "$filepath" "$sync_dir/$id" 2>/dev/null; then
                            synced_count=$((synced_count + 1))
                        else
                            warn "      -> Sync FAILED"
                        fi
                        drift_count=$((drift_count + 1))
                    fi
                fi
            done < "$MAP_FILE"

            info "Drift detection complete. $drift_count drifted, $synced_count synced."
        fi
    fi

    # =====================================================================
    # 5. DISPLAY ALL TRACKED FILES WITH HASHES
    # =====================================================================
    info "========== ALL TRACKED FILES =========="

    if [ -f "$MAP_FILE" ]; then
        while IFS='|' read -r id filepath; do
            id=$(trim "$id")
            filepath=$(trim "$filepath")

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

    info "========== ALL TRACKED CACHES =========="
    if [ -s "$CACHE_MAP" ]; then
        while IFS='|' read -r cid path type; do
            cid=$(trim "$cid")
            path=$(trim "$path")
            type=$(trim "$type")
            [ -z "$cid" ] && continue

            local link_target="<not linked>"
            [ -L "$path" ] && link_target=$(readlink "$path")

            echo "  [$cid] ($type) $path -> $link_target"
        done < "$CACHE_MAP"
    else
        warn "No cache entries"
    fi
}

## ==============================================================================
## SHADER / FOSSILIZE CACHE SWAP
## ==============================================================================
swap_steam_fossilize() {
    local GPU_TAG="$1"

    local SUDO=""
    if [ "$(id -u)" -ne "$USER_UID" ]; then
        SUDO="sudo -u $USER_NAME"
    fi

    local STEAM_ROOT
    STEAM_ROOT=$($SUDO bash -c 'readlink -f ~/.steam/root' 2>/dev/null || echo "$USER_HOME/.local/share/Steam")
    local SHADERCACHE="${STEAM_ROOT}/steamapps/shadercache"

    debug "swap_steam_fossilize: GPU_TAG=$GPU_TAG, STEAM_ROOT=$STEAM_ROOT"

    $SUDO mkdir -p "${SHADERCACHE}.${GPU_TAG}"

    if [ -L "$SHADERCACHE" ] || [ -d "$SHADERCACHE" ]; then
        if [ -d "$SHADERCACHE" ] && [ ! -L "$SHADERCACHE" ]; then
            if [ "$TRUST_LIVE" = "0" ]; then
                debug "  -> Skipping shader cache backup (live not trusted)"
            else
                local CURRENT_TAG
                if [ "$GPU_TAG" = "egpu" ]; then
                    CURRENT_TAG="igpu"
                else
                    CURRENT_TAG="egpu"
                fi
                $SUDO mkdir -p "${SHADERCACHE}.${CURRENT_TAG}"
                $SUDO rsync -a --remove-source-files "$SHADERCACHE/" "${SHADERCACHE}.${CURRENT_TAG}/" 2>/dev/null
                $SUDO find "$SHADERCACHE" -type d -empty -delete 2>/dev/null
            fi
        fi
        $SUDO rm -rf "$SHADERCACHE"
    fi

    $SUDO ln -s "${SHADERCACHE}.${GPU_TAG}" "$SHADERCACHE"
    $SUDO chown -R "$USER_UID:$USER_UID" "${SHADERCACHE}.${GPU_TAG}" 2>/dev/null
}

## ==============================================================================
## SWAP
## ==============================================================================

perform_swap() {
    local target_state="$1"
    local current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

    info "========== PERFORMING SWAP =========="
    debug "Target: $target_state / Current: $current_state / TRUST_LIVE: $TRUST_LIVE / FORCE_APPLY: $FORCE_APPLY"

    if [ "$target_state" = "$current_state" ] && [ "$current_state" != "unknown" ]; then
        if [ "$FORCE_APPLY" != "1" ]; then
            echo "Already in $target_state mode — nothing to do. Use -f to force re-apply."
            return 0
        fi
        info "Force re-apply requested — reloading $target_state profiles"
    fi

    local save_to_dir=""
    local load_from_dir=""

    if [ "$target_state" = "egpu" ]; then
        load_from_dir="$EGPU_PROFILES"
        if [ "$current_state" = "igpu" ]; then
            save_to_dir="$IGPU_PROFILES"
        elif [ "$current_state" = "unknown" ]; then
            debug "First run — backing up to BOTH profiles"
        fi
    else
        load_from_dir="$IGPU_PROFILES"
        if [ "$current_state" = "egpu" ]; then
            save_to_dir="$EGPU_PROFILES"
        elif [ "$current_state" = "unknown" ]; then
            debug "First run — backing up to BOTH profiles"
        fi
    fi

    if [ "$DRYRUN" != "1" ]; then
        atomic_write "$target_state" "$SWAP_MARKER"
        info "Swap marker set: target=$target_state"
    fi

    local backup_count=0
    local apply_count=0
    local missing_count=0
    local unknown_backups=0
    local skipped_backup_count=0

    while IFS='|' read -r id filepath; do
        id=$(trim "$id")
        filepath=$(trim "$filepath")

        [ -z "$id" ] && continue
        [ -z "$filepath" ] && continue

        debug "Processing: [$id] $filepath"
        local live_hash=$(file_hash "$filepath")

        if [ "$current_state" = "unknown" ] && [ -f "$filepath" ]; then
            if [ "$DRYRUN" = "1" ]; then
                info "  DRY RUN: Would backup to BOTH profiles (first run)"
            else
                cp -p "$filepath" "$IGPU_PROFILES/$id" 2>/dev/null || warn "  -> iGPU backup FAILED"
                cp -p "$filepath" "$EGPU_PROFILES/$id" 2>/dev/null || warn "  -> eGPU backup FAILED"
                unknown_backups=$((unknown_backups + 1))
            fi
        fi

        if [ -n "$save_to_dir" ] && [ -f "$filepath" ]; then
            local target_hash=$(file_hash "$save_to_dir/$id")

            if [ "$TRUST_LIVE" = "0" ]; then
                debug "  -> Skipping backup (live not trusted)"
                skipped_backup_count=$((skipped_backup_count + 1))
            elif [ "$DRYRUN" = "1" ]; then
                info "  DRY RUN: Would backup $filepath to $save_to_dir/$id"
            elif [ "$live_hash" = "$target_hash" ]; then
                debug "  -> Already in sync, skipping backup"
            else
                if cp -p "$filepath" "$save_to_dir/$id" 2>/dev/null; then
                    debug "  -> Backed up to: $save_to_dir/$id"
                    backup_count=$((backup_count + 1))
                else
                    warn "  -> Backup FAILED for: $filepath"
                fi
            fi
        elif [ ! -f "$filepath" ]; then
            warn "  -> Source file missing: $filepath"
            missing_count=$((missing_count + 1))
        fi

        if [ -f "$load_from_dir/$id" ]; then
            local profile_hash=$(file_hash "$load_from_dir/$id")

            if [ "$DRYRUN" = "1" ]; then
                info "  DRY RUN: Would apply $load_from_dir/$id to $filepath"
            else
                local live_hash_now=$(file_hash "$filepath")
                if [ "$live_hash_now" = "$profile_hash" ] && [ "$FORCE_APPLY" != "1" ]; then
                    debug "  -> Already matches profile, skipping apply"
                else
                    if cp -p "$load_from_dir/$id" "$filepath" 2>/dev/null; then
                        debug "  -> Applied profile: $load_from_dir/$id"
                        apply_count=$((apply_count + 1))
                    else
                        warn "  -> Apply FAILED for: $filepath"
                    fi
                fi
            fi
        else
            warn "  -> No profile found at: $load_from_dir/$id"
        fi
    done < "$MAP_FILE"

    info "Swap summary:"
    info "  - Files backed up (normal): $backup_count"
    info "  - Files backed up (first run): $unknown_backups"
    info "  - Backups skipped (crash recovery): $skipped_backup_count"
    info "  - Files applied: $apply_count"
    info "  - Files missing: $missing_count"

    # ---- Cache swap (symlink repoint) ----
    if [ "$SKIP_CACHE" = "1" ]; then
        info "Cache swap skipped (-n)"
    else
        swap_cache "$target_state"
    fi

    if [ "$DRYRUN" = "1" ]; then
        info "DRY RUN: Would swap steam fossilize shader cache to $target_state"
    else
        swap_steam_fossilize "$target_state"
    fi

    if [ "$DRYRUN" != "1" ]; then
        atomic_write "$target_state" "$STATE_FILE"
        info "State updated: Now in $target_state mode"
        atomic_remove "$SWAP_MARKER"
        info "Swap marker removed (swap complete)"
    fi
}

## ==============================================================================
## HELP
## ==============================================================================

help() {
    echo "ROG Ally X Absolute GPU Automation v1.30"
    echo "-----------------------------------------"
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -g [state]  Target GPU state (igpu/egpu)"
    echo "  -f          Force re-apply even if already in target state"
    echo "  -d          Dry run: log changes without writing"
    echo "  -n          Skip cache swap (configs + shader cache only)"
    echo "  -h          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -g egpu         # Switch to eGPU (configs + all caches)"
    echo "  $0 -g igpu         # Switch to iGPU (configs + all caches)"
    echo "  $0 -g igpu -f      # Force re-apply iGPU profiles"
    echo "  $0 -g egpu -d      # Dry run (test without changes)"
    echo ""
    echo "Caches:"
    echo "  Shader/pipeline caches are swapped via symlinks (no copies)."
    echo "  Always tracked: mesa, vkd3d, steam fossilize, per-game dxvk caches."
    echo "  Add emulator/custom caches to: $CACHE_DB"
    echo ""
    echo "State file: $STATE_FILE"
    echo "  Current state: $(cat "$STATE_FILE" 2>/dev/null || echo "unknown")"
}

## ==============================================================================
## ARGUMENT PARSING
## ==============================================================================

while getopts "hufg:dn" option; do
    case $option in
        h) help; exit 0;;
        u) ;;
        f) FORCE_APPLY=1;;
        g) GPU_OVERRIDE="$OPTARG";;
        d) DRYRUN=1;;
        n) SKIP_CACHE=1;;
        \?) error "Invalid option"; exit 1;;
    esac
done

## ==============================================================================
## MAIN EXECUTION
## ==============================================================================

debug "========== SCRIPT STARTING =========="
debug "Arguments: $* / GPU_OVERRIDE: ${GPU_OVERRIDE:-not set} / DRYRUN: $DRYRUN / FORCE_APPLY: $FORCE_APPLY"

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

if [ ! -f "$STATE_FILE" ]; then
    warn "No state file found, initializing to 'unknown'"
    atomic_write "unknown" "$STATE_FILE"
fi

HARDWARE_STATE=$(detect_gpu_state)
FILE_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

debug "Hardware state: $HARDWARE_STATE / State file: $FILE_STATE"

if [ -f "$SWAP_MARKER" ]; then
    INTERRUPTED_TARGET=$(cat "$SWAP_MARKER" 2>/dev/null || echo "unknown")
    warn "=== CRASH RECOVERY ==="
    warn "  Previous swap to '$INTERRUPTED_TARGET' was interrupted!"
    warn "  Hardware currently reports: $HARDWARE_STATE"
    atomic_remove "$SWAP_MARKER"

    if [ "$INTERRUPTED_TARGET" = "$HARDWARE_STATE" ]; then
        warn "  Target GPU present — completing swap. Live files not trusted."
        TRUST_LIVE=0
        FORCE_APPLY=1
        GPU_OVERRIDE="$INTERRUPTED_TARGET"
    else
        warn "  Target GPU NOT present — reverting to $HARDWARE_STATE. Live files not trusted."
        TRUST_LIVE=0
        FORCE_APPLY=1
        GPU_OVERRIDE="$HARDWARE_STATE"
    fi

elif [ "$FILE_STATE" != "$HARDWARE_STATE" ] && [ "$FILE_STATE" != "unknown" ]; then
    warn "=== STATE MISMATCH ==="
    warn "  Hardware: $HARDWARE_STATE / State file: $FILE_STATE — forcing re-sync."
    FORCE_APPLY=1
    GPU_OVERRIDE="$HARDWARE_STATE"
fi

# 1. Crawl + register config files
crawl_and_register

# 2. Crawl + register cache paths
crawl_and_register_caches

# 3. Swap
if [ -n "$GPU_OVERRIDE" ]; then
    perform_swap "$GPU_OVERRIDE"
else
    help
fi

info "========== SCRIPT COMPLETE =========="
exit 0
