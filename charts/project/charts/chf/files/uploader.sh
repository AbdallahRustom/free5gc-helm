#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }

# Hide xtrace while running sensitive commands (in case container runs bash -x)
suppress_xtrace() { case "$-" in *x*) set +x; _xtrace_was_on=1;; esac; }
restore_xtrace()  { if [ "${_xtrace_was_on:-}" = 1 ]; then set -x; unset _xtrace_was_on; fi; }

log "uploader start"

# Directories
BASE="${CDR_BASE:-/data/cdr}"
IN="${BASE}/incoming"
FAILED="${BASE}/failed"
SENT="${BASE}/sent"
TMP_ZIP_DIR="${BASE}/tmp"
mkdir -p "$IN" "$FAILED" "$SENT" "$TMP_ZIP_DIR"

# Policy (old/original logic)
MIN_SIZE_BYTES="${MIN_SIZE_BYTES:-5242880}" # 5 MB
MIN_AGE_SECS="${MIN_AGE_SECS:-300}"        # 5 minutes
QUIET_SECS="${QUIET_SECS:-30}"             # avoid files still being written

# SFTP (key-based)
HOST="${SFTP_HOST:?}"
USER="${SFTP_USER:?}"
PORT="${SFTP_PORT:-22}"
KEY="${SFTP_PRIVATE_KEY:-/secrets/id_ed25519}"
REMOTE_DIR="${SFTP_REMOTE_DIR:-/incoming/cdr}"

log "base=$BASE in=$IN failed=$FAILED sent=$SENT tmp=$TMP_ZIP_DIR"
log "policy: include failed + current where (size>=${MIN_SIZE_BYTES} OR age>=${MIN_AGE_SECS}) and quiet>=${QUIET_SECS}"
log "sftp: host=$HOST port=$PORT remoteDir=$REMOTE_DIR key=$KEY"
shopt -s nullglob

# Ensure zip exists
if ! command -v zip >/dev/null 2>&1; then
  log "ERROR: 'zip' not found. Install it (Alpine: 'apk add --no-cache zip')."
  exit 1
fi

# SFTP helper: key auth, StrictHostKeyChecking disabled (per your request)
sftp_batch_key() {
  local batch="$1"
  suppress_xtrace
  sftp -vv \
    -i "$KEY" \
    -oStrictHostKeyChecking=no \
    -oUserKnownHostsFile=/dev/null \
    -oPreferredAuthentications=publickey \
    -oPasswordAuthentication=no \
    -oKbdInteractiveAuthentication=no \
    -oBatchMode=yes \
    -P "$PORT" \
    -b - \
    "$USER@$HOST" \
    2>&1 <<<"$batch"
  local rc=$?
  restore_xtrace
  return $rc
}

now=$(date +%s)

# Build candidate list:
# - All failed CDRs (always included)
# - Current CDRs in IN/ that pass OR policy + quiet
to_send=()
from_failed=()
from_current=()

# Include all failed CDRs
for f in "$FAILED"/*.csv; do
  [ -e "$f" ] || break
  to_send+=( "$f" )
  from_failed+=( "$f" )
done

# Include eligible current CDRs using OR policy
for f in "$IN"/*.csv; do
  [ -e "$f" ] || break
  sz=$(stat -c %s "$f") || { log "WARN: stat size failed: $f"; continue; }
  mtime=$(stat -c %Y "$f") || { log "WARN: stat mtime failed: $f"; continue; }
  age=$(( now - mtime ))
  # OR policy: accept if either size or age threshold is met, and quiet period is met
  if (( sz < MIN_SIZE_BYTES )) && (( age < MIN_AGE_SECS )); then
    continue
  fi
  if (( age < QUIET_SECS )); then
    continue
  fi
  to_send+=( "$f" )
  from_current+=( "$f" )
done

log "selection: to_send=${#to_send[@]} (failed=${#from_failed[@]} current=${#from_current[@]})"

# Nothing to send
if (( ${#to_send[@]} == 0 )); then
  log "nothing to send, status: OK"
  exit 0
fi

# Create a timestamped zip name, e.g., cdr-batch-YYYYMMDD-HHMMSS.zip
zip_ts="$(date '+%Y%m%d-%H%M%S')"
zip_name="cdr-batch-${zip_ts}.zip"
zip_path="${TMP_ZIP_DIR}/${zip_name}"

# Create ZIP; -j stores files without paths, preserves each file's mtime
# Detect duplicate basenames; if found, keep paths to avoid overwriting inside zip
use_j="-j"
declare -A seen
collision=0
for f in "${to_send[@]}"; do
  bn="$(basename "$f")"
  if [[ -n "${seen[$bn]:-}" ]]; then collision=1; break; fi
  seen["$bn"]=1
done
if (( collision == 1 )); then
  log "notice: duplicate basenames detected; keeping paths inside zip"
  use_j=""
fi

# Build the ZIP
rm -f "$zip_path"
if ! zip $use_j -q "$zip_path" "${to_send[@]}"; then
  log "ERROR: zip failed creating $zip_name"
  rm -f "$zip_path"
  exit 1
fi
log "created zip: $zip_path with ${#to_send[@]} file(s)"

# Preflight: ensure remote directory exists
if ! sftp_batch_key "$(printf 'ls \"%s\"\n' "$REMOTE_DIR")" | sed 's/^/[SFTP] /'; then
  log "ERROR: remote directory not accessible: $REMOTE_DIR"
  rm -f "$zip_path"
  # Move current candidates to failed; leave existing failed as-is
  for f in "${from_current[@]}"; do
    mv -f "$f" "$FAILED/$(basename "$f")"
  done
  log "status: FAILED (preflight)"
  exit 1
fi

# Upload ZIP and verify it landed
if sftp_batch_key "$(printf 'put -p \"%s\" \"%s/%s\"\nls \"%s/%s\"\n' \
     "$zip_path" "$REMOTE_DIR" "$zip_name" "$REMOTE_DIR" "$zip_name")" | sed 's/^/[SFTP] /'
then
  log "uploaded: $zip_name"
  # On success: move originals to sent/
  for f in "${from_current[@]}"; do
    mv -f "$f" "$SENT/$(basename "$f")"
  done
  for f in "${from_failed[@]}"; do
    mv -f "$f" "$SENT/$(basename "$f")"
  done
  rm -f "$zip_path"
  log "status: OK (sent ${#to_send[@]} file(s) in $zip_name)"
  exit 0
else
  log "ERROR: upload failed: $zip_name"
  # On failure: move current to failed/, leave existing failed in place
  for f in "${from_current[@]}"; do
    mv -f "$f" "$FAILED/$(basename "$f")"
  done
  rm -f "$zip_path"
  log "status: FAILED (kept failed CDRs for next run)"
  exit 1
fi
