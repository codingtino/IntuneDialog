#!/bin/bash

# -----------------------------------------------------------------------------
# Script Name: init_intunedialog.sh
# Description: starts intunedialog to wait for intune deployed apps to be installed
# Author: Tino Naumann
# Created: 2025-05-17
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'
# for debugging
#set -x

DEBUG="false"
# Constants
readonly PROJECT_NAME="IntuneDialog"
readonly RESOURCE_DIR="/Library/Application Support/$PROJECT_NAME"
readonly LOG_DIR="/Library/Logs/$PROJECT_NAME"
readonly DIALOG_BIN="/usr/local/bin/dialog"
readonly COMMAND_FILE="$LOG_DIR/dialog.log"
readonly CONFIG_FILE="$RESOURCE_DIR/config.csv"
readonly DIALOG_CONFIG="$RESOURCE_DIR/swiftdialog.json"
readonly INSTALL_LOG="/var/log/install.log"
readonly ITEMS_COUNT=$(($(grep -c '"title"' "$DIALOG_CONFIG")-1))
readonly SLEEP_TIME=60
readonly MAX_RETRIES=60

# === Logging Functions ===
init_logging() {
  # Initializes logging by redirecting stdout and stderr to a logfile.
  local logfile="${1:-"$LOG_DIR/$(basename "${BASH_SOURCE[1]:-$0}" | cut -d '.' -f1).log"}"
  mkdir -p "$(dirname "$logfile")"
  exec > >(tee -a "$logfile") 2>&1
}

log() {
  # Simple logging function with timestamp and log level.
  local level="$1"
  local message="$2"
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $(echo "$level" | tr '[:lower:]' '[:upper:]') | $message"
}

cleanup() {
  # Deletes the lock file and logs the cleanup step.
  rm -f "$RESOURCE_DIR/$PROJECT_NAME.lock" "$LOG_DIR/*.fail"
  log "info" "Cleanup completed."
  if [[ "$DEBUG" == "false" ]]; then
    log "info" "Rebooting system..."
    /sbin/shutdown -r now
  else
    log "info" "Skipping reboot in DEBUG mode."
  fi
}

check_debug() {
  # switch $DEBUG to true when the file $RESOURCE_DIR/$PROJECT_NAME.debug exists
  if [[ -f "$RESOURCE_DIR/$PROJECT_NAME.debug" ]]; then
    DEBUG="true"
  else
    DEBUG="false"
  fi
}

check_prerequisites() {
  # Verifies prerequisites before running the onboarding logic

  if [[ ! -x "$DIALOG_BIN" ]]; then
    log "error" "Dialog binary not found at $DIALOG_BIN. Exiting..."
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

wait_for_dock() {
  # Waits until the Dock process is available, indicating a user session.
  log "info" "Dock not running, waiting"
  until pgrep -x Dock >/dev/null 2>&1; do
    echo -n "."
    sleep 1
  done
  echo
  log "info" "Dock is running, continuing..."
}

launch_dialog() {
  local blur_flags=()
  local retries=6

  if [[ "$DEBUG" == "false" ]]; then
    blur_flags+=(--blurscreen --ontop)
  fi

  # Start Dialog in background and handle errors safely
  log "info" "Launching Swift Dialog binary..."
  "$DIALOG_BIN" \
    "${blur_flags[@]:-}" \
    --jsonfile "$DIALOG_CONFIG" \
    --commandfile "$COMMAND_FILE" \
    --presentation \
    --progress "$ITEMS_COUNT" \
    --messagealignment "left" \
    --button1disabled \
    --button2text "Reboot Now" \
    --width 1280 --height 500 \
    &
  readonly DIALOG_SUBSHELL_PID=$!

  while ! pgrep -f "Swift Dialog" >/dev/null && (( retries-- > 0 )); do
    log "info" "wait for Swift Dialog being operational..."
    sleep 10
  done
  if (( retries == 0 )); then
    log "error" "Swift Dialog did not start after waiting. Exiting."
    exit 1
  else
    touch "$RESOURCE_DIR/$PROJECT_NAME.lock"
    caffeinate -dimsu -w "$DIALOG_SUBSHELL_PID" &
    log "info" "Caffeinate started to prevent sleep while dialog is active"
  fi

}

monitor_app() {
  local app_name="$1"
  local start_mode="$2"
  local start_patterns="$3"
  local success_mode="$4"
  local success_patterns="$5"
  local app_log="$LOG_DIR/$(echo "$app_name" | tr -cs 'A-Za-z0-9' '_').log"
  local start_detected=false
  local retries=0
  init_logging "$app_log"

  start_array=()
  IFS=';'
  for token in $start_patterns; do
    start_array+=("$token")
  done

  success_array=()
  for token in $success_patterns; do
    success_array+=("$token")
  done
  unset IFS

  log "info" "Monitoring installation of $app_name..."

  # Local function to centralize success handling (avoid duplication)
  handle_success() {
    log "success" "All $app_name success conditions met."
    echo "listitem: title: $app_name, status: success, statustext: Installed" >>"$COMMAND_FILE"
    echo "progress: increment" >>"$COMMAND_FILE"
    touch "$LOG_DIR/$app_name.success"
    log "info" "Installation of $app_name...finished"
    exit 0
  }

  # If success marker already exists, skip checks
  if [[ -f "$LOG_DIR/$app_name.success" ]]; then
    handle_success
  fi

  while ((retries < MAX_RETRIES)); do
    # Success pattern check
    local success_hits=0
    for pattern in "${success_array[@]}"; do
      if /usr/bin/log show --predicate "eventMessage contains[c] \"$pattern\"" --last 7d \
      | grep -v "com.apple.log" \
      | grep -Fq "$pattern"; then
        ((success_hits++))
        [[ "$success_mode" == "any" ]] && break
      elif [[ "$success_mode" == "all" ]]; then
        success_hits=-1
        break
      fi
    done

    if { [[ "$success_mode" == "any" && $success_hits -gt 0 ]] || [[ "$success_mode" == "all" && $success_hits -ge 0 ]]; }; then
      handle_success
    fi

    # Start pattern check
    if ! $start_detected; then
      for pattern in "${start_array[@]}"; do
        if /usr/bin/log show --predicate "eventMessage contains[c] \"$pattern\"" --last 7d \
        | grep -v "com.apple.log" \
        | grep -Fq "$pattern"; then

          start_detected=true
          log "info" "Detected start of $app_name installation (pattern: $pattern)"
          echo "listitem: title: $app_name, status: wait, statustext: Installing..." >>"$COMMAND_FILE"
          break
        fi
      done
    fi

    log "info" "$app_name not yet fully installed. Rechecking in $SLEEP_TIME seconds (Attempt $retries)..."
    ((retries++))
    sleep "$SLEEP_TIME"
  done

  log "error" "$app_name failed to install after $((SLEEP_TIME * MAX_RETRIES)) seconds."
  echo "listitem: title: $app_name, status: fail, statustext: Failed to install" >>"$COMMAND_FILE"
  touch "$LOG_DIR/$app_name.fail"
}

wait_for_app_install() {
  log "info" "Processing scripts..."
  local app_monitor_pids=()
  while IFS=',' read -r app_name start_mode start_patterns success_mode success_patterns; do
    [[ -z "${app_name:-}" || "${app_name:0:1}" == "#" ]] && continue

    if [[ -z "$start_mode" || -z "$start_patterns" || -z "$success_mode" || -z "$success_patterns" ]]; then
      log "warning" "Skipping invalid config line for app '$app_name'. Must have 5 fields."
      continue
    fi

    monitor_app "$app_name" "$start_mode" "$start_patterns" "$success_mode" "$success_patterns" &
    app_monitor_pids+=($!)
  done <"$CONFIG_FILE"

  
  if (( ${#app_monitor_pids[@]} != ITEMS_COUNT )); then
    log "error" "Config mismatch: Found ${#app_monitor_pids[@]} valid config entries, but dialog expects $ITEMS_COUNT items."
    echo "infobox: ❌ Config error: Only ${#app_monitor_pids[@]} of $ITEMS_COUNT apps are configured. Please review config.csv." >>"$COMMAND_FILE"
  fi

  for pid in "${app_monitor_pids[@]}"; do
    wait "$pid"
  done
    log "info" "All application monitoring jobs finished."

  local err_files=("$LOG_DIR"/*.fail)
  if compgen -G "$LOG_DIR/*.fail" > /dev/null; then
    log "warning" "Some applications failed to install:"
    for err_file in "${err_files[@]}"; do
      log "warning" " - $(basename "$err_file" .fail)"
    done
    echo "infobox: ⚠️ Some applications failed to install. Please check the logs and try again." >>"$COMMAND_FILE"
  elif (( ${#app_monitor_pids[@]} == ITEMS_COUNT )); then
    echo "infobox: ✅ All required applications have been installed. You may now click Continue or Reboot." >>"$COMMAND_FILE"
    echo "progress: complete" >>"$COMMAND_FILE"
    touch "$RESOURCE_DIR/$PROJECT_NAME.done"
  fi
  echo "button1: enable" >>"$COMMAND_FILE"

}

wait_for_dialog() {
  if [[ -n "${DIALOG_SUBSHELL_PID:-}" ]]; then
    log "info" "Waiting for Swift Dialog subshell (PID $DIALOG_SUBSHELL_PID) to exit..."
    wait "$DIALOG_SUBSHELL_PID"
  else
    log "warning" "No Swift Dialog subshell PID found to wait for."
  fi
}

# === Main Execution ===
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

exit 0

