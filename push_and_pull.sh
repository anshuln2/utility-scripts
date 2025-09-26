#!/usr/bin/env bash

set -euo pipefail

# Pull latest changes
git pull

BASE_REMOTE="klone-node:/gscratch/sewoong/anasery/fingerprinting/oml-exploration/plots/"

# Prompt for a regex/glob to fetch specific files
read -r -p "Enter a file regex/glob to scp from server (leave blank for defaults): " FILE_REGEX

if [[ -z "${FILE_REGEX}" ]]; then
  echo "No pattern provided. Fetching defaults: 'detailed' and '*.pdf'"
  scp -r "${BASE_REMOTE}detailed" .
  scp -r "${BASE_REMOTE}"*.pdf .
else
  echo "Fetching pattern: ${FILE_REGEX}"
  # Decide destination directory based on leading path segment of the pattern
  DEST_DIR="."
  if [[ "${FILE_REGEX}" == */* ]]; then
    FIRST_SEG="${FILE_REGEX%%/*}"
    # Only use FIRST_SEG as destination if it has no globbing characters
    if [[ -n "${FIRST_SEG}" && "${FIRST_SEG}" != *[*?\[]* ]]; then
      DEST_DIR="${FIRST_SEG}"
      mkdir -p "${DEST_DIR}"
    fi
  fi
  # Copy matching files into the chosen destination directory
  scp -r "${BASE_REMOTE}${FILE_REGEX}" "${DEST_DIR}/"
fi

# Stage changes
git add .

# Prompt for commit message with default
read -r -p "Commit message (default: update plots): " COMMIT_MSG
COMMIT_MSG=${COMMIT_MSG:-"update plots"}

git commit -m "${COMMIT_MSG}"
git push
