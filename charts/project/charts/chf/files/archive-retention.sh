set -euo pipefail
# Delete compressed files older than KEEP_DAYS
find "$ARCHIVE_DIR" -type f -name '*.csv.gz' -mtime +"$KEEP_DAYS" -delete