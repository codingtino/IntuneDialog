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
set -x

DEBUG="false"
# Constants
readonly PROJECT_NAME="IntuneDialog"
readonly RESOURCE_DIR="/Library/Application Support/$PROJECT_NAME"
readonly LOG_DIR="/Library/Logs/$PROJECT_NAME"
readonly DIALOG_BIN="/usr/local/bin/dialog"
readonly COMMAND_FILE="/var/tmp/dialog.log"
readonly CONFIG_FILE="$RESOURCE_DIR/config.csv"
readonly DIALOG_CONFIG="$RESOURCE_DIR/swiftdialog.json"
readonly INSTALL_LOG="/var/log/install.log"
readonly SLEEP_TIME=60
readonly MAX_RETRIES=30
readonly MAX_ATTEMPTS=10
readonly DIALOG_TIMEOUT=60

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
  rm -f "$RESOURCE_DIR/$PROJECT_NAME.lock"
  log "info" "Cleanup completed."
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
  # Attempts to launch SwiftDialog up to MAX_ATTEMPTS with a timeout check.
  local attempt=1
  local blur_flags=()

  if [[ "$DEBUG" == "false" ]]; then
    blur_flags+=(--blurscreen --ontop)
  fi

  while [ $attempt -le $MAX_ATTEMPTS ]; do
    log "info" "Attempting to launch Swift Dialog (Attempt $attempt of $MAX_ATTEMPTS)"
    killall Dialog >/dev/null 2>&1 || true

    # Start Dialog in background and handle errors safely
    {
      log "info" "Launching Swift Dialog binary..."
      "$DIALOG_BIN" \
        "${blur_flags[@]:-}" \
        --jsonfile "$DIALOG_CONFIG" \
        --commandfile "$COMMAND_FILE" \
        --presentation \
        --messagealignment "left" \
        --button1disabled \
        --button2text "Reboot Now" \
        --width 1280 --height 500

      local exit_code=$?
      log "info" "Swift Dialog exited with code $exit_code"

      if [ "$exit_code" -eq 2 ]; then
        log "info" "User clicked Reboot Now. Rebooting..."
        if rm -f "$RESOURCE_DIR/$PROJECT_NAME.lock"; then
          log "info" "$PROJECT_NAME.lock successfully removed."
        else
          log "warning" "Failed to remove dialog.lock. It may not exist or permission was denied."
        fi
        sleep 2
        shutdown -r now >/dev/null 2>&1
      fi
    } &

    for ((i = 1; i <= $DIALOG_TIMEOUT; i++)); do
      dialog_pid="$(pgrep -x Dialog || true)"
      if [ -n "$dialog_pid" ]; then
        log "info" "Swift Dialog launched successfully on attempt $attempt with PID ${dialog_pid}."
        touch "$RESOURCE_DIR/$PROJECT_NAME.lock"
        caffeinate -dimsu -w "$dialog_pid" &
        log "info" "Caffeinate started to prevent sleep while dialog is active"
        sleep 10
        return 0
      fi
      sleep 1
    done

    log "warning" "Swift Dialog did not launch within $DIALOG_TIMEOUT seconds on attempt $attempt."
    attempt=$((attempt + 1))
  done

  log "error" "Swift Dialog failed to launch after $MAX_ATTEMPTS attempts. Continuing with the script..."
  return 1
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

  #  IFS=';' read -r -a start_array <<<"$(echo "$start_patterns" | sed 's/^;*//;s/;*$//')"
  #  IFS=';' read -r -a success_array <<<"$(echo "$success_patterns" | sed 's/^;*//;s/;*$//')"
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

  {
    log "info" "Monitoring installation of $app_name..."

    while ((retries < MAX_RETRIES)); do
      # Success pattern check
      local success_hits=0
      for pattern in "${success_array[@]}"; do
        if grep -Eq "$pattern" "$INSTALL_LOG"; then
          ((success_hits++))
          [[ "$success_mode" == "any" ]] && break
        elif [[ "$success_mode" == "all" ]]; then
          success_hits=-1
          break
        fi
      done

      if { [[ "$success_mode" == "any" && $success_hits -gt 0 ]] || [[ "$success_mode" == "all" && $success_hits -ge 0 ]]; }; then
        log "success" "All $app_name success conditions met."
        echo "listitem: title: $app_name, status: success, statustext: Installed" >>"$COMMAND_FILE"
        log "info" "Installation of $app_name...finished"
        exit 0
      fi

      # Start pattern check
      if ! $start_detected; then
        for pattern in "${start_array[@]}"; do
          if grep -Eq "$pattern" "$INSTALL_LOG"; then
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
    sleep 60
    echo "button2:" >>"$COMMAND_FILE"
  } &
}

parse_config() {
  log "info" "Processing scripts..."
  local job_pids=()
  while IFS=',' read -r app_name start_mode start_patterns success_mode success_patterns; do
    [[ -z "${app_name:-}" || "${app_name:0:1}" == "#" ]] && continue

    if [[ -z "$start_mode" || -z "$start_patterns" || -z "$success_mode" || -z "$success_patterns" ]]; then
      log "warning" "Skipping invalid config line for app '$app_name'. Must have 5 fields."
      continue
    fi

    monitor_app "$app_name" "$start_mode" "$start_patterns" "$success_mode" "$success_patterns"
    job_pids+=($!)
  done <"$CONFIG_FILE"

  for pid in "${job_pids[@]}"; do
    wait "$pid"
  done
}

wait_for_dialog_exit() {
  # Waits until SwiftDialog process has exited.
  log "info" "Waiting for Swift Dialog process to exit..."
  while [[ -n "$(pgrep -x Dialog 2>/dev/null || true)" ]]; do
    sleep 1
  done
  log "info" "Swift Dialog process has exited."
}

finalize_onboarding() {
  # Processes config and signals completion in SwiftDialog
  log "info" "All application monitoring jobs finished."
  echo "infobox: ✅ All required applications have been installed. You may now click Continue or Reboot." >>"$COMMAND_FILE"
  echo "button1: enable" >>"$COMMAND_FILE"
  touch "$RESOURCE_DIR/$PROJECT_NAME.done"
}

# === Main Execution ===
init_logging
log "info" "Starting onboarding script..."
check_debug
check_prerequisites
trap cleanup EXIT
wait_for_dock
launch_dialog
parse_config
finalize_onboarding
wait_for_dialog_exit
log "info" "Finished Setup. Exiting cleanly."

exit 0
