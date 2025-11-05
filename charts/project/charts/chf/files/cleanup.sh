#!/usr/bin/env bash
set -euo pipefail

TARGET="${TARGET_DIR:-/data/cdr/sent}"
DAYS="${ONLY_OLDER_THAN_DAYS:-7}"

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "Cleanup target '$TARGET' does not exist" >&2
  exit 1
fi

echo "Cleaning files in '$TARGET' (older than ${DAYS} days; 0 means all)"

if [ "$DAYS" = "0" ]; then
  find "$TARGET" -type f -print -delete
else
  find "$TARGET" -type f -mtime +"$DAYS" -print -delete
fi
