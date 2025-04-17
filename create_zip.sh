#!/bin/bash

# Check if an argument was provided
if [[ -z "$1" ]]; then
  echo "❌ Error: No folder path provided."
  echo "Usage: $0 /path/to/folder /path/to/output.zip"
  exit 1
fi

# Extract directory part of output path and check if it exists
OUTPUT_DIR=$(dirname "$2")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "❌ Error: Output directory '$OUTPUT_DIR' does not exist."
  exit 1
fi

# Check if a second argument was provided
if [[ -z "$2" ]]; then
  echo "❌ Error: No output zip path provided."
  echo "Usage: $0 /path/to/folder /path/to/output.zip"
  exit 1
fi

# Resolve absolute path and sanitize
INPUT_PATH=$(realpath "$1" 2>/dev/null)

# Validate that the input is a directory
if [[ ! -d "$INPUT_PATH" ]]; then
  echo "❌ Error: '$1' is not a valid directory."
  exit 1
fi

# Get folder name and define zip output
FOLDER_NAME=$(basename "$INPUT_PATH")
ZIP_NAME="$2"

# Create the zip file in a temporary path
TEMP_ZIP_PATH="$(mktemp -u "${TMPDIR:-/tmp}/tempzip.XXXXXX.zip")"
pushd "$INPUT_PATH" >/dev/null
zip -r "$TEMP_ZIP_PATH" . >/dev/null
popd >/dev/null
mv "$TEMP_ZIP_PATH" "$ZIP_NAME"

# Check result
if [[ $? -eq 0 ]]; then
  echo "✅ Successfully created zip: $ZIP_NAME"
else
  echo "❌ Failed to create zip file."
  exit 1
fi
