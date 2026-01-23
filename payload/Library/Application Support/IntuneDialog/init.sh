#!/bin/bash

# -----------------------------------------------------------------------------
# Script Name: init_intunedialog.sh
# Description: Orchestrates the Intune onboarding experience using Swift Dialog.
#              Monitors application installation logs and updates the UI.
# Author:      Tino Naumann
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# === Configuration ===

# Default debug state (can be overridden by a file check later)
DEBUG="false"

readonly PROJECT_NAME="IntuneDialog"
readonly RESOURCE_DIR="/Library/Application Support/$PROJECT_NAME"
readonly LOG_DIR="/Library/Logs/$PROJECT_NAME"
readonly DIALOG_BIN="/usr/local/bin/dialog"
readonly COMMAND_FILE="$LOG_DIR/dialog.log"
readonly CONFIG_FILE="$RESOURCE_DIR/config.csv"
readonly DIALOG_CONFIG="$RESOURCE_DIR/swiftdialog.json"
# Calculate item count from JSON config (fallback to 0 if grep fails)
readonly ITEMS_COUNT=$(( $(grep -c '"title"' "$DIALOG_CONFIG" 2>/dev/null || echo 1) - 1 ))
readonly SLEEP_TIME=60
readonly MAX_RETRIES=60

# === Logging & Output ===

# Redirects stdout and stderr to a log file for persistent tracking.
init_logging() {
  local logfile="${1:-"$LOG_DIR/$(basename "${BASH_SOURCE[1]:-$0}" | cut -d '.' -f1).log"}"
  mkdir -p "$(dirname "$logfile")"
  exec > >(tee -a "$logfile") 2>&1
}

# Prints a formatted log message with timestamp and severity level.
log() {
  local level="$1"
  local message="$2"
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $(echo "$level" | tr '[:lower:]' '[:upper:]') | $message"
}

# Appends a command to the Swift Dialog command file.
dialog_command() {
  echo "$1" >> "$COMMAND_FILE"
}

# === Utilities ===

# Searches the unified log for a specific pattern.
# Uses fixed-string search for exact matches.
check_log() {
  local pattern="$1"
  local lookback="$2"
  local pattern_escaped="${pattern//\\/\\\\}"
  pattern_escaped="${pattern_escaped//\"/\\\"}"
  /usr/bin/log show --style compact --predicate "composedMessage contains[c] \"$pattern_escaped\"" --last "$lookback" |
    grep -v "com.apple.log" |
    grep -Fq "$pattern"
}

# Performs cleanup operations upon script exit.
# Removes lock files and temporary failure markers. Reboots if not in debug mode.
cleanup() {
  shopt -s nullglob nocaseglob
  rm -f -- "$RESOURCE_DIR/$PROJECT_NAME.lock" "$LOG_DIR"/*.fail
  shopt -u nullglob nocaseglob
  log "info" "Cleanup completed."
  if [[ "$DEBUG" == "false" ]]; then
    log "info" "Rebooting system..."
    /sbin/shutdown -r now
  else
    log "info" "Skipping reboot in DEBUG mode."
  fi
}

# Checks for the existence of a debug marker file to enable verbose/debug behavior.
check_debug() {
  if [[ -f "$RESOURCE_DIR/$PROJECT_NAME.debug" ]]; then
    DEBUG="true"
  else
    DEBUG="false"
  fi
}

# === Prerequisites ===

# Validates that all necessary components (binary, config) are present
# and ensures the script isn't already running or completed.
check_prerequisites() {
  if [[ ! -x "$DIALOG_BIN" ]]; then
    log "error" "Dialog binary not found at $DIALOG_BIN. Exiting..."
    exit 1
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "error" "Config file not found at $CONFIG_FILE. Exiting..."
    exit 1
  fi

  if [[ -f "$RESOURCE_DIR/$PROJECT_NAME.done" ]]; then
    log "info" "We've already completed onboarding. Exiting."
    exit 0
  fi

  if [[ -f "$RESOURCE_DIR/$PROJECT_NAME.lock" ]]; then
    log "info" "We are already running. Exiting."
    exit 0
  fi
}

# Blocks execution until the Dock process is running, indicating an active user session.
wait_for_dock() {
  log "info" "Dock not running, waiting"
  while ! pgrep -x Dock >/dev/null 2>&1; do
    sleep 1
  done
  log "info" "Dock is running, continuing..."
}

# === Dialog Management ===

# Launches the Swift Dialog application in the background.
# Configures the UI based on the JSON config and sets up the command file.
launch_dialog() {
  local blur_flags=()
  local retries=6

  if [[ "$DEBUG" == "false" ]]; then
    blur_flags+=(--blurscreen --ontop)
  fi

  # Reset command file to ensure fresh state and avoid processing old commands
  rm -f "$COMMAND_FILE"
  touch "$COMMAND_FILE"

  # Start Dialog in background and handle errors safely
  log "info" "Launching Swift Dialog binary..."
  "$DIALOG_BIN" \
    "${blur_flags[@]:-}" \
    --jsonfile "$DIALOG_CONFIG" \
    --commandfile "$COMMAND_FILE" \
    --presentation \
    --progress "$ITEMS_COUNT" \
    --messagealignment "left" \
    --button1text "Reboot Now" \
    --width 1280 --height 500 \
    &
  readonly DIALOG_SUBSHELL_PID=$!

  # Wait for the process to initialize
  while ! kill -0 "$DIALOG_SUBSHELL_PID" 2>/dev/null && ((retries-- > 0)); do
    log "info" "wait for Swift Dialog being operational..."
    sleep 10
  done
  if ((retries == 0)); then
    log "error" "Swift Dialog did not start after waiting. Exiting."
    exit 1
  else
    touch "$RESOURCE_DIR/$PROJECT_NAME.lock"
    # Prevent system sleep while Dialog is running
    caffeinate -dimsu -w "$DIALOG_SUBSHELL_PID" &
    log "info" "Caffeinate started to prevent sleep while dialog is active"

    # Allow UI to fully render before sending commands
    sleep 5
  fi

}

# Waits for the Swift Dialog process to close (user clicked button or quit).
wait_for_dialog() {
  if [[ -n "${DIALOG_SUBSHELL_PID:-}" ]]; then
    log "info" "Waiting for Swift Dialog subshell (PID $DIALOG_SUBSHELL_PID) to exit..."
    wait "$DIALOG_SUBSHELL_PID"
  else
    log "warning" "No Swift Dialog subshell PID found to wait for."
  fi
}

# === Application Monitoring ===

# Monitors a specific application's installation progress by scanning logs.
# Runs in a background subshell for each app.
monitor_app() {
  local app_name="$1"
  local start_mode="$2"
  local start_patterns="$3"
  local success_mode="$4"
  local success_patterns="$5"
  local app_log="$LOG_DIR/$(echo "$app_name" | tr -cs 'A-Za-z0-9' '_').log"
  local start_detected=false
  local retries=0
  local lookback="7d"
  init_logging "$app_log"

  # Random delay to prevent high CPU load from simultaneous log queries
  sleep $((RANDOM % 10))

  IFS=';' read -ra start_array <<< "$start_patterns"
  IFS=';' read -ra success_array <<< "$success_patterns"

  # Track which success patterns have been met (for "all" mode)
  local success_found=()
  for ((i=0; i<${#success_array[@]}; i++)); do success_found[i]=false; done

  log "info" "Monitoring installation of $app_name..."

  # Updates Dialog UI and exits the monitor function upon success
  handle_success() {
    log "success" "All $app_name success conditions met."
    dialog_command "listitem: title: $app_name, status: success, statustext: Installed"
    dialog_command "progress: increment"
    touch "$LOG_DIR/$app_name.success"
    log "info" "Installation of $app_name...finished"
    exit 0
  }

  # Check if previously marked as successful
  if [[ -f "$LOG_DIR/$app_name.success" ]]; then
    handle_success
  fi

  while ((retries < MAX_RETRIES)); do
    # 1. Check for success patterns
    local all_found=true
    local any_found=false

    for i in "${!success_array[@]}"; do
      if [[ "${success_found[i]}" == "true" ]]; then
        any_found=true
        continue
      fi

      if check_log "${success_array[i]}" "$lookback"; then
        success_found[i]=true
        any_found=true
      else
        all_found=false
      fi
    done

    if [[ "$success_mode" == "any" && "$any_found" == "true" ]]; then
      handle_success
    fi
    if [[ "$success_mode" == "all" && "$all_found" == "true" ]]; then
      handle_success
    fi

    # 2. Check for start patterns (if not yet detected)
    if ! $start_detected; then
      for pattern in "${start_array[@]}"; do
        if check_log "$pattern" "$lookback"; then
          start_detected=true
          log "info" "Detected start of $app_name installation (pattern: $pattern)"
          dialog_command "listitem: title: $app_name, status: wait, statustext: Installing..."
          break
        fi
      done
    fi

    log "info" "$app_name not yet fully installed. Rechecking in $SLEEP_TIME seconds (Attempt $retries)..."
    
    # Reduce lookback window for subsequent checks to improve performance
    lookback="$((SLEEP_TIME * 10))s"
    ((retries++))
    sleep "$SLEEP_TIME"
  done

  # Handle timeout/failure
  log "error" "$app_name failed to install after $((SLEEP_TIME * MAX_RETRIES)) seconds."
  dialog_command "listitem: title: $app_name, status: fail, statustext: Failed to install"
  touch "$LOG_DIR/$app_name.fail"
}

# Reads the config CSV and spawns a monitor process for each application.
# Waits for all monitors to complete and updates the final UI state.
wait_for_app_install() {
  log "info" "Processing scripts..."
  local app_monitor_pids=()
  while IFS=',' read -r app_name start_mode start_patterns success_mode success_patterns; do
    # Skip empty lines or comments
    [[ -z "${app_name:-}" || "${app_name:0:1}" == "#" ]] && continue

    if [[ -z "$start_mode" || -z "$start_patterns" || -z "$success_mode" || -z "$success_patterns" ]]; then
      log "warning" "Skipping invalid config line for app '$app_name'. Must have 5 fields."
      continue
    fi

    # Sanitize Windows line endings
    success_patterns="${success_patterns//$'\r'/}"

    monitor_app "$app_name" "$start_mode" "$start_patterns" "$success_mode" "$success_patterns" &
    app_monitor_pids+=($!)
  done <"$CONFIG_FILE"

  # Validate configuration count matches Dialog JSON
  if ((${#app_monitor_pids[@]} != ITEMS_COUNT)); then
    log "error" "Config mismatch: Found ${#app_monitor_pids[@]} valid config entries, but dialog expects $ITEMS_COUNT items."
    dialog_command "infobox: ❌ Config error: Only ${#app_monitor_pids[@]} of $ITEMS_COUNT apps are configured. Please review config.csv."
  fi

  # Wait for all background monitor jobs to finish
  for pid in "${app_monitor_pids[@]}"; do
    wait "$pid"
  done
  log "info" "All application monitoring jobs finished."

  # Determine final status
  if compgen -G "$LOG_DIR/*.fail" >/dev/null; then
    log "warning" "Some applications failed to install:"
    for err_file in "$LOG_DIR"/*.fail; do
      log "warning" " - $(basename "$err_file" .fail)"
    done
    dialog_command "infobox: ⚠️ Some applications failed to install. Please check the logs and try again."
  elif ((${#app_monitor_pids[@]} == ITEMS_COUNT)); then
    dialog_command "infobox: ✅ All required applications have been installed. You may now click Continue or Reboot."
    dialog_command "progress: complete"
    touch "$RESOURCE_DIR/$PROJECT_NAME.done"
    dialog_command "button1text: Reboot & Exit"
    dialog_command "button1: enable"
  fi

}

# === Main Execution ===
main() {
  init_logging
  log "info" "Starting IntuneDialog script..."
  check_debug
  check_prerequisites
  trap cleanup EXIT
  wait_for_dock
  launch_dialog
  wait_for_app_install &
  wait_for_dialog
  log "info" "Finished Setup. Exiting cleanly."
}

main "$@"
