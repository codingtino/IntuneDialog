#!/bin/bash

# -----------------------------------------------------------------------------
# Script Name: init_intunedialog.sh
# Description: starts intunedialog to wait for intune deployed apps to be installed
# Author: Tino Naumann
# Created: 2025-05-17
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

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
  local blur_flags=""

  if [[ "$DEBUG" == "true" ]]; then
    blur_flags="--blurscreen --ontop"
  fi

  while [ $attempt -le $MAX_ATTEMPTS ]; do
    log "info" "Attempting to launch Swift Dialog (Attempt $attempt of $MAX_ATTEMPTS)"
    killall Dialog >/dev/null 2>&1
    (
      set +e # Prevent set -e from killing the subshell silently
      log "info" "Launching Swift Dialog binary..."
      "$DIALOG_BIN" \
        ${blur_flags} \
        --jsonfile "$DIALOG_CONFIG" \
        --commandfile "$COMMAND_FILE" \
        --presentation \
        --messagealignment "left" \
        --button1disabled \
        --button2text "Reboot Now" \
        --blurscreen --ontop \
        --width 1280 --height 500 || log "error" "Dialog failed to launch"
      exit_code=$?
      log "info" "Swift Dialog exited with code $exit_code"

      log "info" "Swift Dialog exited"

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
    ) &

    for ((i = 1; i <= DIALOG_TIMEOUT; i++)); do
      dialog_pid=$(pgrep -i -f "$DIALOG_BIN")
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
  # Monitors installation of an app by checking the install log for app-specific entries.
  local app_name="$1"
  local app_paths=("${@:2}") # All remaining args are app paths
  local app_log="$LOG_DIR/$(echo "$app_name" | tr -cs 'A-Za-z0-9' '_').log"
  local start_detected=false
  local retries=0
  init_logging "$app_log"

  {
    log "info" "Monitoring installation of $app_name..."

    while ((retries < MAX_RETRIES)); do
      # --- Success condition: All bundles touched
      local all_touched=true
      for app_path in "${app_paths[@]}"; do
        if ! grep -Fq "Touched bundle $app_path" "$INSTALL_LOG"; then
          all_touched=false
          break
        fi
      done

      if $all_touched; then
        log "success" "All $app_name components have been touched (installed)."
        echo "listitem: title: $app_name, status: success, statustext: Installed" >>"$COMMAND_FILE"
        log "info" "Installation of $app_name...finished"
        exit 0
      fi

      # --- Start condition: Any path matched with pre/postinstall
      if ! $start_detected; then
        for app_path in "${app_paths[@]}"; do
          if grep -Eq "\./(pre|post)install:.*$app_path" "$INSTALL_LOG"; then
            start_detected=true
            log "info" "Detected start of $app_name installation (via $app_path)"
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
    log "error" "Wait 1 minute and trigger restart."
    echo "listitem: title: $app_name, status: fail, statustext: Failed to install" >>"$COMMAND_FILE"
    sleep 60
    echo "button2:" >>"$COMMAND_FILE"
  } &
}

parse_config() {
  # Parses config CSV file and spawns background jobs to monitor each app.
  log "info" "Processing scripts..."
  local job_pids=()
  while IFS=',' read -ra fields; do
    [[ ${#fields[@]} -eq 0 || -z "${fields[0]:-}" || "${fields[0]:-}" == \#* ]] && continue
    local app_name="${fields[0]}"
    local app_paths=("${fields[@]:1}")
    monitor_app "$app_name" "${app_paths[@]}"
    job_pids+=($!)
  done <"$CONFIG_FILE"

  for pid in "${job_pids[@]}"; do
    wait "$pid"
  done
}

wait_for_dialog_exit() {
  # Waits until SwiftDialog process has exited.
  log "info" "Waiting for Swift Dialog process to exit..."
  while pgrep -i -f "$DIALOG_BIN" >/dev/null; do
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
