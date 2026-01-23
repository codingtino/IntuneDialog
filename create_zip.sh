#!/bin/bash

# -----------------------------------------------------------------------------
# Script Name: create_zip.sh
# Description: Compresses a directory into a zip file.
#              Ensures safe handling of paths and verifies output.
# Author:      Tino Naumann
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# === Logging & Output ===

# Prints a message to stdout.
log() {
  echo "$1"
}

# Prints usage instructions and exits.
usage() {
  log "Usage: $0 <input_folder> <output_zip_path>"
  exit 1
}

# === Core Logic ===

# Creates a zip archive from the specified directory.
create_archive() {
  local input_dir="$1"
  local output_zip="$2"
  local temp_zip

  # Create a temporary file path for the zip archive
  temp_zip="$(mktemp -u "${TMPDIR:-/tmp}/tempzip.XXXXXX.zip")"

  # Change to input directory to ensure relative paths in zip
  pushd "$input_dir" >/dev/null

  # Zip contents recursively (quietly)
  if zip -r -q "$temp_zip" .; then
    popd >/dev/null
    mv "$temp_zip" "$output_zip"
    log "Successfully created zip: $output_zip"
  else
    popd >/dev/null
    rm -f "$temp_zip"
    log "Failed to create zip file."
    exit 1
  fi
}

# === Main Execution ===

main() {
  # Validate argument count
  if [[ $# -lt 2 ]]; then
    log "Error: Missing arguments."
    usage
  fi

  local input_arg="$1"
  local output_arg="$2"

  # Validate input directory (resolve absolute path)
  local input_path
  input_path=$(realpath "$input_arg" 2>/dev/null || true)

  if [[ ! -d "$input_path" ]]; then
    log "Error: Input '$input_arg' is not a valid directory."
    exit 1
  fi

  # Validate output directory existence
  local output_dir
  output_dir=$(dirname "$output_arg")
  if [[ ! -d "$output_dir" ]]; then
    log "Error: Output directory '$output_dir' does not exist."
    exit 1
  fi

  create_archive "$input_path" "$output_arg"
}

main "$@"
