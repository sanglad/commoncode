#!/usr/bin/env bash
#
# Oracle EPM Cloud snapshot backup helper.
# Requires epmautomate in PATH and the following environment variables:
#   EPM_USER              : Service administrator user name
#   EPM_PASSWORD_FILE     : Path to an encrypted password file (preferred) or plain text file
#   EPM_URL               : EPM Cloud service URL, e.g. https://example.oraclecloud.com
#   EPM_IDENTITY_DOMAIN   : Identity domain / OCI domain name
#   EPM_SNAPSHOT_NAME     : Name of the snapshot to download, default: "Artifact Snapshot"
#   BACKUP_DIR            : Directory to store the downloaded snapshot archives
# Optional:
#   RETENTION_COUNT       : Number of most recent backups to keep (default: 7)
#   EPMAUTOMATE_OPTS      : Extra flags for epmautomate (e.g. -verbose)
#
# Usage:
#   Ensure the variables above are exported, then run:
#     ./backup_snapshot.sh
#
# The script will:
#   1. Validate prerequisites
#   2. Log in to the environment
#   3. Recreate the snapshot (ensuring it is up to date)
#   4. Download and compress the snapshot
#   5. Rotate old backups
#   6. Log out

set -euo pipefail
IFS=$'\n\t'

log() {
  printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*"
}

fatal() {
  log "ERROR: $*"
  exit 1
}

require_var() {
  local name=$1
  local value=${!name:-}
  [[ -n $value ]] || fatal "Environment variable $name is required."
}

cleanup() {
  local exit_code=$?
  if [[ -n ${EPMA_SESSION_LOGGED_IN:-} ]]; then
    log "Logging out..."
    epmautomate ${EPMAUTOMATE_OPTS:-} logout || log "WARNING: logout failed."
  fi
  if [[ -d ${WORK_DIR:-} ]]; then
    rm -rf "$WORK_DIR"
  fi
  exit "$exit_code"
}
trap cleanup EXIT

command -v epmautomate >/dev/null 2>&1 || fatal "epmautomate is not in PATH."

require_var EPM_USER
require_var EPM_PASSWORD_FILE
require_var EPM_URL
require_var EPM_IDENTITY_DOMAIN
require_var BACKUP_DIR

SNAPSHOT_NAME=${EPM_SNAPSHOT_NAME:-Artifact Snapshot}
RETENTION_COUNT=${RETENTION_COUNT:-7}

[[ -r $EPM_PASSWORD_FILE ]] || fatal "Password file $EPM_PASSWORD_FILE is not readable."

mkdir -p "$BACKUP_DIR"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/epm_backup.XXXXXX")
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
BASE_NAME=${SNAPSHOT_NAME// /_}
LOCAL_DOWNLOAD_PATH="$WORK_DIR/${BASE_NAME}.zip"
FINAL_ARCHIVE_PATH="$BACKUP_DIR/${BASE_NAME}_${TIMESTAMP}.zip"

log "Starting snapshot backup for $SNAPSHOT_NAME"

log "Logging in to ${EPM_URL}..."
epmautomate ${EPMAUTOMATE_OPTS:-} login "$EPM_USER" "$EPM_PASSWORD_FILE" "$EPM_URL" "$EPM_IDENTITY_DOMAIN"
EPMA_SESSION_LOGGED_IN=1

log "Recreating snapshot..."
epmautomate ${EPMAUTOMATE_OPTS:-} recreatesnapshot

log "Downloading snapshot $SNAPSHOT_NAME..."
epmautomate ${EPMAUTOMATE_OPTS:-} downloadfile "$SNAPSHOT_NAME" "$LOCAL_DOWNLOAD_PATH"

mv "$LOCAL_DOWNLOAD_PATH" "$FINAL_ARCHIVE_PATH"

log "Snapshot saved to $FINAL_ARCHIVE_PATH"

log "Rotating backups in $BACKUP_DIR (keeping latest $RETENTION_COUNT)..."
mapfile -t archives < <(ls -1t "${BACKUP_DIR}/${BASE_NAME}_"*.zip 2>/dev/null || true)
if (( ${#archives[@]} > RETENTION_COUNT )); then
  for old_archive in "${archives[@]:RETENTION_COUNT}"; do
    log "Removing old backup $old_archive"
    rm -f "$old_archive"
  done
fi

log "Backup completed successfully."
