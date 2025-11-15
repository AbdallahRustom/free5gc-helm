set -euo pipefail
# Compress all completed CSVs (gzip removes the original file)
find "$ARCHIVE_DIR" -type f -name '*.csv' -print0 | xargs -0 -r gzip -9
# Optional: cleanup stale .part files older than 1 day (defense in depth)
find "$ARCHIVE_DIR" -type f -name '*.part' -mtime +1 -delete