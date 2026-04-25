#!/bin/bash

set -euo pipefail

# ---------- configuration ----------

DATA_DIR="/photon/photon_data"
NODE_DIR="$DATA_DIR/node_1"
STAGED_DIR="$DATA_DIR/staged"
STAGED_NODE="$STAGED_DIR/node_1"
STAGED_MD5_FILE="$STAGED_DIR/version.md5"
LAST_MD5_FILE="$DATA_DIR/last_known.md5"
JAVA_PID_FILE="/tmp/photon.pid"

USER_AGENT="docker: tonsnoei/photon-geocoder"
INDEX_URL="https://download1.graphhopper.com/public/photon-db-planet-1.0-latest.tar.bz2"
MD5_URL="${INDEX_URL}.md5"

# How often to poll for a new index (seconds). Default: 24h.
UPDATE_CHECK_INTERVAL_SECONDS="${UPDATE_CHECK_INTERVAL_SECONDS:-86400}"

# ntfy notification config. All three must be set to enable notifications.
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"

BACKGROUND_PID=""
MAIN_PID=""

# ---------- helpers ----------

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

is_process_running() {
    local pid="$1"
    [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null
}

read_md5_file() {
    local file="$1"
    [ -f "$file" ] && [ -s "$file" ] || return 1
    local v
    v=$(awk '{print $1}' "$file" 2>/dev/null | head -1 | tr -d '[:space:]')
    [[ "$v" =~ ^[a-fA-F0-9]{32}$ ]] || return 1
    echo "$v"
}

is_node_dir_valid() {
    local d="$1"
    [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]
}

check_disk_space() {
    local required_gb=250
    local kb gb
    kb=$(df "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    gb=$((kb / 1024 / 1024))
    log "Available disk space: ${gb}GB"
    if [ "$gb" -lt "$required_gb" ]; then
        log "ERROR: need ${required_gb}GB, have ${gb}GB"
        return 1
    fi
}

# ---------- ntfy ----------

ntfy_send() {
    local title="$1"
    local message="$2"
    if [ -z "$NTFY_URL" ] || [ -z "$NTFY_TOPIC" ] || [ -z "$NTFY_TOKEN" ]; then
        return 0
    fi
    local url="${NTFY_URL%/}/$NTFY_TOPIC"
    log "Sending ntfy notification to $url"
    if ! wget --quiet \
            --method=POST \
            --header="Authorization: Bearer $NTFY_TOKEN" \
            --header="Title: $title" \
            --body-data="$message" \
            -O /dev/null \
            "$url"; then
        log "Warning: ntfy notification failed"
    fi
}

# ---------- download ----------

fetch_remote_md5() {
    local tmp tries=3 n=0 v
    tmp=$(mktemp)
    while [ "$n" -lt "$tries" ]; do
        if wget --user-agent="$USER_AGENT" --timeout=30 --tries=2 -q -O "$tmp" "$MD5_URL"; then
            v=$(awk '{print $1}' "$tmp" | head -1 | tr -d '[:space:]')
            if [[ "$v" =~ ^[a-fA-F0-9]{32}$ ]]; then
                rm -f "$tmp"
                echo "$v"
                return 0
            fi
        fi
        n=$((n + 1))
        [ "$n" -lt "$tries" ] && sleep 2
    done
    rm -f "$tmp"
    return 1
}

# Download archive into $1 and extract so $1/node_1 is populated.
download_and_extract() {
    local target_dir="$1"
    log "Downloading index into $target_dir"

    check_disk_space || return 1
    mkdir -p "$target_dir" || return 1

    local archive="$target_dir/photon-db.tar.bz2"
    log "Starting download of $(basename "$INDEX_URL")"
    if ! wget --user-agent="$USER_AGENT" \
            --timeout=300 \
            --tries=3 \
            --continue \
            --progress=dot:giga \
            -O "$archive" "$INDEX_URL"; then
        log "Download failed"
        rm -f "$archive"
        return 1
    fi

    log "Extracting..."
    if ! bzip2 -dc "$archive" | tar x -C "$target_dir"; then
        log "Extraction failed"
        rm -f "$archive"
        return 1
    fi
    rm -f "$archive"

    # Some archive layouts wrap the data in a nested photon_data/ directory.
    if [ -d "$target_dir/photon_data" ] && [ ! -d "$target_dir/node_1" ]; then
        log "Flattening nested photon_data/"
        mv "$target_dir/photon_data"/* "$target_dir/" || return 1
        rmdir "$target_dir/photon_data"
    fi

    if ! is_node_dir_valid "$target_dir/node_1"; then
        log "ERROR: extracted archive does not contain a valid node_1 directory"
        return 1
    fi
    return 0
}

# ---------- staging ----------

# If a staged index is present and valid, swap it into NODE_DIR before startup.
apply_staged_index_if_present() {
    [ -d "$STAGED_DIR" ] || return 0
    if ! is_node_dir_valid "$STAGED_NODE"; then
        log "Staged dir exists but is not valid; clearing it"
        rm -rf "$STAGED_DIR"
        return 0
    fi

    log "Staged index found; applying before startup"
    if [ -d "$NODE_DIR" ]; then
        log "Removing current index at $NODE_DIR"
        rm -rf "$NODE_DIR"
    fi
    if ! mv "$STAGED_NODE" "$NODE_DIR"; then
        log "ERROR: failed to move staged index into place"
        return 1
    fi

    if [ -f "$STAGED_MD5_FILE" ]; then
        local v
        if v=$(read_md5_file "$STAGED_MD5_FILE"); then
            echo "$v" > "$LAST_MD5_FILE"
            log "Recorded new index version: $v"
        fi
    fi

    rm -rf "$STAGED_DIR"
    log "Staged index applied"
}

stage_new_index() {
    local new_md5="$1"
    log "Staging new index (md5=$new_md5)"
    rm -rf "$STAGED_DIR"
    if ! download_and_extract "$STAGED_DIR"; then
        log "Staging failed"
        rm -rf "$STAGED_DIR"
        return 1
    fi
    echo "$new_md5" > "$STAGED_MD5_FILE"
    log "New index staged at $STAGED_DIR — will be applied on next container restart"
    ntfy_send "Photon index update available" \
        "A new Photon search index has been downloaded and staged. Restart the container to apply it. (md5=$new_md5)"
    return 0
}

# ---------- photon ----------

start_photon() {
    log "Starting Photon..."
    [ -f "photon.jar" ] || { log "ERROR: photon.jar not found in $(pwd)"; return 1; }
    command -v java >/dev/null 2>&1 || { log "ERROR: java not in PATH"; return 1; }

    if [ -f "$JAVA_PID_FILE" ]; then
        local old
        old=$(cat "$JAVA_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$old" ] && is_process_running "$old"; then
            log "Photon already running with PID $old"
            return 1
        fi
        rm -f "$JAVA_PID_FILE"
    fi

    java -XX:-UseContainerSupport \
         -XX:+UnlockDiagnosticVMOptions \
         -XX:+IgnoreUnrecognizedVMOptions \
         -Djdk.lang.Process.launchMechanism=vfork \
         -Dcom.sun.management.jmxremote=false \
         -jar photon.jar "$@" &
    local pid=$!
    [ -n "$pid" ] && [ "$pid" -gt 0 ] || { log "ERROR: failed to launch java"; return 1; }
    echo "$pid" > "$JAVA_PID_FILE"
    log "Java started (PID $pid), waiting for boot..."
    sleep 3
    if is_process_running "$pid"; then
        log "Photon up (PID $pid)"
        return 0
    fi
    log "ERROR: java exited shortly after launch"
    rm -f "$JAVA_PID_FILE"
    return 1
}

stop_photon() {
    [ -f "$JAVA_PID_FILE" ] || return 0
    local pid
    pid=$(cat "$JAVA_PID_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && is_process_running "$pid"; then
        log "Stopping Photon (PID $pid)"
        kill -TERM "$pid"
        local n=0
        while is_process_running "$pid" && [ "$n" -lt 60 ]; do
            sleep 1; n=$((n + 1))
        done
        if is_process_running "$pid"; then
            log "Force killing PID $pid"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$JAVA_PID_FILE"
}

# ---------- update worker ----------

update_check_loop() {
    sleep 30  # let Photon stabilize before first check
    while true; do
        if [ -d "$STAGED_DIR" ] && is_node_dir_valid "$STAGED_NODE"; then
            log "Update check: staged index already waiting; skipping"
        else
            log "Update check: fetching remote MD5"
            local remote_md5 last_md5
            if remote_md5=$(fetch_remote_md5); then
                last_md5=$(read_md5_file "$LAST_MD5_FILE" 2>/dev/null || echo "")
                if [ "$remote_md5" = "$last_md5" ]; then
                    log "Update check: index is up to date ($remote_md5)"
                else
                    log "Update check: new version available (current=${last_md5:-unknown} remote=$remote_md5)"
                    if ! stage_new_index "$remote_md5"; then
                        log "Update check: staging failed; will retry next interval"
                    fi
                fi
            else
                log "Update check: failed to fetch remote MD5"
            fi
        fi
        sleep "$UPDATE_CHECK_INTERVAL_SECONDS"
    done
}

# ---------- shutdown ----------

cleanup_and_exit() {
    log "Received shutdown signal"
    if [ -n "$BACKGROUND_PID" ] && is_process_running "$BACKGROUND_PID"; then
        kill -TERM "$BACKGROUND_PID" 2>/dev/null || true
    fi
    stop_photon
    exit 0
}

trap cleanup_and_exit SIGTERM SIGINT

# ---------- main ----------

log "=== Photon Docker Entrypoint ==="
mkdir -p "$DATA_DIR"

# 1. If a staged index from a prior run is present, apply it now.
apply_staged_index_if_present

# 2. If we still have no index, do the initial download in-place.
if ! is_node_dir_valid "$NODE_DIR"; then
    log "No index present — performing initial download"
    if ! download_and_extract "$DATA_DIR"; then
        log "ERROR: initial download failed"
        exit 1
    fi
    if remote_md5=$(fetch_remote_md5); then
        echo "$remote_md5" > "$LAST_MD5_FILE"
    fi
fi

# 3. Start Photon.
if ! start_photon "$@"; then
    log "ERROR: Photon failed to start"
    exit 1
fi
MAIN_PID=$(cat "$JAVA_PID_FILE")

# 4. Background loop: poll for new index versions and stage them.
update_check_loop &
BACKGROUND_PID=$!
log "Update checker running (PID $BACKGROUND_PID, interval ${UPDATE_CHECK_INTERVAL_SECONDS}s)"

# 5. Wait on Photon.
wait "$MAIN_PID"
