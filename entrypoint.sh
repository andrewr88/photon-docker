#!/bin/bash

set -euo pipefail

# Configuration
DATA_DIR="/photon/photon_data"
NODE_DIR="$DATA_DIR/node_1"
TEMP_DIR="$DATA_DIR/temp_download"
MD5_FILE="$DATA_DIR/current.md5"
JAVA_PID_FILE="/tmp/photon.pid"
LAST_MD5_FILE="$DATA_DIR/last_known.md5"

# URLs
USER_AGENT="docker: tonsnoei/photon-geocoder"
INDEX_URL="https://download1.graphhopper.com/public/experimental/photon-db-latest.tar.bz2"
MD5_URL="${INDEX_URL}.md5"

# Global variables for signal handling
BACKGROUND_PID=""
MAIN_PID=""

# Function to check available disk space
check_disk_space() {
    local required_space_gb=250  # Conservative estimate: 100GB download + 100GB extract + 50GB buffer
    local available_kb
    available_kb=$(df "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    local available_gb=$((available_kb / 1024 / 1024))

    echo "Available disk space: ${available_gb}GB"
    if [ "$available_gb" -lt "$required_space_gb" ]; then
        echo "ERROR: Insufficient disk space. Need at least ${required_space_gb}GB, have ${available_gb}GB"
        return 1
    fi
    return 0
}

# Function to validate PID
is_process_running() {
    local pid="$1"
    [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null
}

# Function to safely read MD5 file
read_md5_file() {
    local file="$1"
    if [ -f "$file" ] && [ -s "$file" ]; then
        local md5_value
        md5_value=$(cat "$file" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "")
        if [[ "$md5_value" =~ ^[a-fA-F0-9]{32}$ ]]; then
            echo "$md5_value"
            return 0
        fi
    fi
    return 1
}

# Function to download and extract index with better error handling
download_and_extract() {
    local target_dir="$1"
    local is_temp="$2"

    echo "Downloading search index to $target_dir"

    # Check disk space before starting
    if ! check_disk_space; then
        return 1
    fi

    # Create target directory
    if ! mkdir -p "$target_dir"; then
        echo "ERROR: Failed to create target directory: $target_dir"
        return 1
    fi

    # For streaming downloads, we can't use --continue with piping
    # Download to file first, then extract
    local temp_file="$target_dir/photon-db.tar.bz2"

    # Download with better options for large files
    echo "Starting download of $(basename "$INDEX_URL")..."
    if wget --user-agent="$USER_AGENT" \
           --timeout=300 \
           --tries=3 \
           --continue \
           --progress=dot:giga \
           -O "$temp_file" "$INDEX_URL"; then

        echo "Download completed, extracting..."
        if bzip2 -dc "$temp_file" | tar x -C "$target_dir"; then
            echo "Successfully downloaded and extracted index"
            rm -f "$temp_file"
            return 0
        else
            echo "Failed to extract downloaded file"
            rm -f "$temp_file"
            rm -rf "$target_dir"
            return 1
        fi
    else
        local exit_code=$?
        echo "Failed to download index (exit code: $exit_code)"
        rm -f "$temp_file"
        rm -rf "$target_dir"
        return 1
    fi
}

# Function to download MD5 with retry logic
download_md5() {
    echo "Downloading MD5 checksum"
    local temp_md5="$MD5_FILE.tmp"
    local retries=3
    local count=0

    while [ "$count" -lt "$retries" ]; do
        if wget --user-agent="$USER_AGENT" --timeout=30 --tries=2 -q -O "$temp_md5" "$MD5_URL"; then
            # Validate MD5 format (32 hex characters)
            local md5_value
            md5_value=$(awk '{print $1}' "$temp_md5" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "")
            if [[ "$md5_value" =~ ^[a-fA-F0-9]{32}$ ]]; then
                echo "$md5_value" > "$MD5_FILE"
                rm -f "$temp_md5"
                echo "MD5 checksum downloaded: $md5_value"
                return 0
            else
                echo "Invalid MD5 format received: '$md5_value'"
            fi
        fi
        count=$((count + 1))
        if [ "$count" -lt "$retries" ]; then
            echo "MD5 download attempt $count failed, retrying in 2 seconds..."
            sleep 2
        fi
    done

    rm -f "$temp_md5"
    echo "Failed to download MD5 checksum after $retries attempts"
    return 1
}

# Function to start Photon in background
start_photon() {
    echo "Starting Photon..."

    # Check if photon.jar exists
    if [ ! -f "photon.jar" ]; then
        echo "ERROR: photon.jar not found in current directory: $(pwd)"
        echo "Directory contents:"
        ls -la
        return 1
    fi

    # Check if Java is available
    if ! command -v java >/dev/null 2>&1; then
        echo "ERROR: Java is not installed or not in PATH"
        return 1
    fi

    # Clean up any stale PID file
    if [ -f "$JAVA_PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$JAVA_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && ! is_process_running "$old_pid"; then
            rm -f "$JAVA_PID_FILE"
        elif [ -n "$old_pid" ]; then
            echo "Warning: Photon already running with PID $old_pid"
            return 1
        fi
    fi

    # Start Java process - correct syntax for background processes
    echo "Executing: java -jar photon.jar $*"
    java -jar photon.jar "$@" &
    local java_pid=$!

    # Check if the background process was started successfully
    if [ -z "$java_pid" ] || [ "$java_pid" -le 0 ]; then
        echo "ERROR: Failed to start Java process - invalid PID"
        return 1
    fi

    echo "$java_pid" > "$JAVA_PID_FILE"
    echo "Java process started with PID $java_pid, waiting for startup..."

    # Wait a moment and verify it started
    sleep 3
    if is_process_running "$java_pid"; then
        echo "Photon started successfully with PID $java_pid"
        return 0
    else
        echo "ERROR: Photon process died shortly after startup"
        echo "Checking if process exited with error..."
        wait "$java_pid" 2>/dev/null || local exit_code=$?
        if [ -n "${exit_code:-}" ]; then
            echo "Java process exited with code: $exit_code"
        fi
        rm -f "$JAVA_PID_FILE"
        return 1
    fi
}

# Function to stop Photon gracefully
stop_photon() {
    if [ -f "$JAVA_PID_FILE" ]; then
        local pid
        pid=$(cat "$JAVA_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && is_process_running "$pid"; then
            echo "Stopping Photon gracefully (PID: $pid)"
            kill -TERM "$pid"  # Use TERM signal first

            # Wait for graceful shutdown (up to 60 seconds for large index)
            local count=0
            while is_process_running "$pid" && [ "$count" -lt 60 ]; do
                sleep 1
                count=$((count + 1))
                if [ $((count % 15)) -eq 0 ]; then
                    echo "Waiting for graceful shutdown... (${count}s)"
                fi
            done

            # Force kill if still running
            if is_process_running "$pid"; then
                echo "Force killing Photon (PID: $pid)"
                kill -KILL "$pid" 2>/dev/null || true
                sleep 2

                # Final check
                if is_process_running "$pid"; then
                    echo "Warning: Process $pid may still be running"
                fi
            fi
        fi
        rm -f "$JAVA_PID_FILE"
        echo "Photon stopped"
    else
        echo "No Photon PID file found"
    fi
}

# Function to perform hot swap with enhanced safety
perform_hot_swap() {
    echo "Performing hot swap of search index"

    # Clean up any previous failed attempts
    rm -rf "$TEMP_DIR"

    echo "Downloading new index to temporary location..."
    if download_and_extract "$TEMP_DIR" "true"; then
        # Debug: Show what was actually extracted
        echo "Contents of temp directory after extraction:"
        ls -la "$TEMP_DIR" || echo "Failed to list temp directory"

        # Look for node directory with more flexibility
        local node_source=""
        if [ -d "$TEMP_DIR/node_1" ]; then
            node_source="$TEMP_DIR/node_1"
        elif [ -d "$TEMP_DIR/photon_data/node_1" ]; then
            node_source="$TEMP_DIR/photon_data/node_1"
        else
            # Look for any directory that might contain the index data
            local found_dirs
            found_dirs=$(find "$TEMP_DIR" -name "node_*" -type d 2>/dev/null | head -1)
            if [ -n "$found_dirs" ]; then
                node_source="$found_dirs"
                echo "Found alternative node directory: $node_source"
            fi
        fi

        # Verify we found a valid node directory
        if [ -n "$node_source" ] && [ -d "$node_source" ] && [ -n "$(ls -A "$node_source" 2>/dev/null)" ]; then
            echo "Download successful, found valid node directory at: $node_source"
            echo "Contents of node directory:"
            ls -la "$node_source" | head -10

            # Stop current Photon instance
            stop_photon

            # Atomic directory swap with backup
            echo "Performing atomic directory swap"
            local backup_dir="${NODE_DIR}.backup.$(date +%s)"

            # Create backup of current directory
            if [ -d "$NODE_DIR" ]; then
                echo "Creating backup at $backup_dir"
                if ! mv "$NODE_DIR" "$backup_dir"; then
                    echo "ERROR: Failed to create backup"
                    rm -rf "$TEMP_DIR"
                    return 1
                fi
            fi

            # Move new directory into place
            echo "Moving new index into place from $node_source to $NODE_DIR"
            if ! mv "$node_source" "$NODE_DIR"; then
                echo "ERROR: Failed to move new directory, restoring backup"
                if [ -d "$backup_dir" ]; then
                    if ! mv "$backup_dir" "$NODE_DIR"; then
                        echo "CRITICAL: Failed to restore backup! Manual intervention required."
                    fi
                fi
                rm -rf "$TEMP_DIR"
                return 1
            fi

            # Verify the new directory is valid
            if [ -d "$NODE_DIR" ] && [ -n "$(ls -A "$NODE_DIR" 2>/dev/null)" ]; then
                echo "Hot swap completed successfully"
                # Clean up temp and old backup
                rm -rf "$TEMP_DIR"
                if [ -d "$backup_dir" ]; then
                    rm -rf "$backup_dir"
                fi
                return 0
            else
                echo "ERROR: New directory is invalid, restoring backup"
                rm -rf "$NODE_DIR"
                if [ -d "$backup_dir" ]; then
                    if ! mv "$backup_dir" "$NODE_DIR"; then
                        echo "CRITICAL: Failed to restore backup! Manual intervention required."
                    fi
                fi
                rm -rf "$TEMP_DIR"
                return 1
            fi
        else
            echo "Downloaded index structure is invalid"
            echo "Expected to find node directory in temp location, but found:"
            find "$TEMP_DIR" -type d 2>/dev/null | head -20
            rm -rf "$TEMP_DIR"
            return 1
        fi
    else
        echo "Failed to download new index"
        rm -rf "$TEMP_DIR"
        return 1
    fi
}

# Function to handle background update process
run_background_update() {
    local current_md5="$1"
    shift  # Remove first argument, keep the rest for start_photon

    echo "Waiting 15 seconds for service to stabilize before update..."
    sleep 15
    echo "Starting background update process"

    if perform_hot_swap; then
        echo "Update downloaded successfully, restarting service"
        echo "$current_md5" > "$LAST_MD5_FILE"
        if start_photon "$@"; then
            echo "Service restarted with new index"
            # Background process completed successfully
            exit 0
        else
            echo "Failed to restart service after update"
            # Don't exit 1 here as it would kill the container - just log the error
            echo "Background update failed during service restart, keeping current version running"
            exit 1
        fi
    else
        echo "Hot swap failed, service continues with current version"
        echo "Background update process completed - no changes made"
        # Background process completed (failed but handled gracefully)
        exit 0
    fi
}

# Signal handlers for graceful shutdown
cleanup_and_exit() {
    echo "Received shutdown signal, cleaning up..."

    # Stop background process if running
    if [ -n "$BACKGROUND_PID" ] && is_process_running "$BACKGROUND_PID"; then
        echo "Stopping background update process..."
        kill -TERM "$BACKGROUND_PID" 2>/dev/null || true
        # Wait briefly for background process to exit
        local count=0
        while is_process_running "$BACKGROUND_PID" && [ "$count" -lt 10 ]; do
            sleep 1
            count=$((count + 1))
        done
        if is_process_running "$BACKGROUND_PID"; then
            kill -KILL "$BACKGROUND_PID" 2>/dev/null || true
        fi
    fi

    # Stop Photon
    stop_photon

    # Clean up temp files
    rm -rf "$TEMP_DIR"

    exit 0
}

trap cleanup_and_exit SIGTERM SIGINT

# Main logic
echo "=== Photon Docker Entrypoint ==="

# Ensure data directory exists
if ! mkdir -p "$DATA_DIR"; then
    echo "ERROR: Failed to create data directory: $DATA_DIR"
    exit 1
fi

# Try to download the current MD5 (non-fatal if it fails)
if ! download_md5; then
    echo "Warning: Could not download MD5, will proceed without version checking"
fi

# Check if index exists
if [ -d "$NODE_DIR" ] && [ -n "$(ls -A "$NODE_DIR" 2>/dev/null)" ]; then
    echo "Search index exists, checking for updates"

    # Compare MD5 if we have both files
    current_md5=""
    last_md5=""

    if current_md5=$(read_md5_file "$MD5_FILE") && last_md5=$(read_md5_file "$LAST_MD5_FILE"); then
        echo "Current MD5: $current_md5"
        echo "Last known MD5: $last_md5"

        if [ "$current_md5" != "$last_md5" ]; then
            echo "MD5 mismatch detected - new version available"
            echo "Starting current instance while preparing update"

            # Start current instance
            if start_photon "$@"; then
                MAIN_PID=$(cat "$JAVA_PID_FILE")

                # Perform hot swap in background
                run_background_update "$current_md5" "$@" &
                BACKGROUND_PID=$!

                # Wait for main Java process only (let background update run independently)
                wait "$MAIN_PID"
            else
                echo "Failed to start Photon with existing index"
                exit 1
            fi
        else
            echo "Index is up to date"
            if start_photon "$@"; then
                MAIN_PID=$(cat "$JAVA_PID_FILE")
                wait "$MAIN_PID"
            else
                echo "Failed to start Photon"
                exit 1
            fi
        fi
    elif current_md5=$(read_md5_file "$MD5_FILE"); then
        # First time with MD5 - mark current version
        echo "First time setup - marking current version"
        echo "$current_md5" > "$LAST_MD5_FILE"
        if start_photon "$@"; then
            MAIN_PID=$(cat "$JAVA_PID_FILE")
            wait "$MAIN_PID"
        else
            echo "Failed to start Photon"
            exit 1
        fi
    else
        echo "Could not verify MD5, starting with existing index"
        if start_photon "$@"; then
            MAIN_PID=$(cat "$JAVA_PID_FILE")
            wait "$MAIN_PID"
        else
            echo "Failed to start Photon"
            exit 1
        fi
    fi
else
    echo "No search index found, downloading initial version"

    if download_and_extract "$DATA_DIR" "false"; then
        current_md5=""
        if current_md5=$(read_md5_file "$MD5_FILE"); then
            echo "$current_md5" > "$LAST_MD5_FILE"
        fi

        if [ -d "$NODE_DIR" ] && [ -n "$(ls -A "$NODE_DIR" 2>/dev/null)" ]; then
            echo "Initial download completed, starting Photon"
            if start_photon "$@"; then
                MAIN_PID=$(cat "$JAVA_PID_FILE")
                wait "$MAIN_PID"
            else
                echo "Failed to start Photon after initial download"
                exit 1
            fi
        else
            echo "Could not start photon, the search index could not be found after download"
            exit 1
        fi
    else
        echo "Could not download search index"
        exit 1
    fi
fi
