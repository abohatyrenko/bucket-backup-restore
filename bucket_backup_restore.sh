#!/usr/bin/env bash
#
# Backup of an S3-compatible bucket (or any rclone remote) into a dated, optionally
# encrypted tar.gz archive in another bucket, and restore from it.
#
# Usage:
#   bucket_backup_restore.sh backup
#   bucket_backup_restore.sh restore [backup-file-name | full-remote-path]   # latest backup if omitted
#   bucket_backup_restore.sh list [backup-name]
#
# All configuration is done through environment variables, see README.md.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Source bucket (rclone remote path). SRC_BUCKET / DST_BUCKET are the names used before 1.0.0.
SOURCE="${SOURCE:-${SRC_BUCKET:-}}"
SOURCE="${SOURCE%/}"
BACKUP_NAME="${BACKUP_NAME:-}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-0}"
BACKUP_ALLOW_EMPTY="${BACKUP_ALLOW_EMPTY:-false}"

# Destination for archives: rclone remote path or s3://bucket/path
DESTINATION="${DESTINATION:-${DST_BUCKET:-}}"
DESTINATION="${DESTINATION%/}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_PROVIDER="${S3_PROVIDER:-}"
S3_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

# Restore
RESTORE_TARGET="${RESTORE_TARGET:-$SOURCE}"
RESTORE_TARGET="${RESTORE_TARGET%/}"
RESTORE_CONFIRM="${RESTORE_CONFIRM:-}"
RESTORE_DELETE="${RESTORE_DELETE:-false}"

# Encryption (https://age-encryption.org)
AGE_RECIPIENTS="${AGE_RECIPIENTS:-}"
AGE_IDENTITY="${AGE_IDENTITY:-}"
AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:-}"

# Notifications
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
NOTIFY_ON="${NOTIFY_ON:-failure}" # failure | always | never
HEARTBEAT_URL="${HEARTBEAT_URL:-}"
HEARTBEAT_FAIL_URL="${HEARTBEAT_FAIL_URL:-}"

WORK_DIR="${WORK_DIR:-/tmp/bucket-backup-restore}"

# Remotes can come from a config file or from RCLONE_CONFIG_<REMOTE>_* variables only;
# without a config file rclone would print a notice on every call
if [[ -n "${RCLONE_CONFIG:-}" && ! -e "$RCLONE_CONFIG" ]]; then export RCLONE_CONFIG=/dev/null; fi

# Pre-1.0.0 throttling variables, now plain rclone flags (any RCLONE_<FLAG> variable works)
if [[ -n "${BANDWITH_LIMIT:-}" ]]; then export RCLONE_BWLIMIT="${RCLONE_BWLIMIT:-$BANDWITH_LIMIT}"; fi
if [[ -n "${TRANSACTION_LIMIT:-}" ]]; then export RCLONE_TPSLIMIT="${RCLONE_TPSLIMIT:-$TRANSACTION_LIMIT}"; fi

COMMAND="${1:-}"
TMP_DIR=""
SUMMARY=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${*:2}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
die() { log ERROR "$@"; exit 1; }

require_env() {
  local name missing=()
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "missing required environment variable(s): ${missing[*]}"
}

is_true() { [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

notify_slack() {
  [[ -n "$SLACK_WEBHOOK_URL" ]] || return 0
  curl -fsS -m 15 --retry 3 -H 'Content-Type: application/json' \
    -d "{\"text\": \"$(json_escape "$1")\"}" "$SLACK_WEBHOOK_URL" >/dev/null \
    || warn "failed to send Slack notification"
}

ping_url() {
  [[ -n "$1" ]] || return 0
  curl -fsS -m 15 --retry 3 "$1" >/dev/null || warn "failed to ping heartbeat URL"
}

on_exit() {
  local rc=$?
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
  case "$COMMAND" in backup | restore) ;; *) return "$rc" ;; esac

  local context="${COMMAND}${SUMMARY:+ ${SUMMARY}}"
  if ((rc == 0)); then
    [[ "$NOTIFY_ON" == "always" ]] && notify_slack ":white_check_mark: ${context} succeeded"
    [[ "$COMMAND" == "backup" ]] && ping_url "$HEARTBEAT_URL"
  else
    log ERROR "${context} failed with exit code ${rc}"
    [[ "$NOTIFY_ON" != "never" ]] && notify_slack ":x: ${context} FAILED (exit code ${rc}), check the job logs"
    [[ "$COMMAND" == "backup" ]] && ping_url "$HEARTBEAT_FAIL_URL"
  fi
  return "$rc"
}
trap on_exit EXIT

make_tmp_dir() {
  mkdir -p -- "$WORK_DIR"
  TMP_DIR="$(mktemp -d "${WORK_DIR}/run.XXXXXX")"
}

# s3://bucket/path is a shortcut for an S3 remote that takes credentials from the
# AWS credential chain (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, shared credentials
# file, IRSA / EKS Pod Identity, instance profile) and S3_ENDPOINT / AWS_REGION.
# Other paths are passed to rclone as they are.
export RCLONE_CONFIG_S3DEST_TYPE=s3
export RCLONE_CONFIG_S3DEST_ENV_AUTH=true
# Backup credentials usually may not create buckets
export RCLONE_CONFIG_S3DEST_NO_CHECK_BUCKET=true
if [[ -n "$S3_ENDPOINT" ]]; then
  export RCLONE_CONFIG_S3DEST_PROVIDER="${S3_PROVIDER:-Other}"
  export RCLONE_CONFIG_S3DEST_ENDPOINT="$S3_ENDPOINT"
else
  export RCLONE_CONFIG_S3DEST_PROVIDER="${S3_PROVIDER:-AWS}"
fi
if [[ -n "$S3_REGION" ]]; then export RCLONE_CONFIG_S3DEST_REGION="$S3_REGION"; fi

to_remote() {
  if [[ "$1" == s3://* ]]; then
    printf 's3dest:%s' "${1#s3://}"
  else
    printf '%s' "$1"
  fi
}

# Prints backup file names under remote "directory" $1, oldest first.
list_backups() {
  rclone lsf --files-only --format tp --separator '|' "${1}/" \
    | sort \
    | cut -d'|' -f2- \
    | grep -E '\.tar\.gz(\.age)?$' || true
}

remote_size() {
  rclone size --json "$1" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p'
}

validate_backup_name() {
  [[ "$BACKUP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "BACKUP_NAME may only contain letters, digits, '.', '_' and '-'"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

do_backup() {
  require_env SOURCE DESTINATION BACKUP_NAME
  validate_backup_name
  [[ "$BACKUP_KEEP_DAYS" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP_DAYS must be a non-negative integer"

  local timestamp dest_dir data_dir archive upload_file target files entries local_size uploaded_size
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest_dir="$(to_remote "$DESTINATION")/${BACKUP_NAME}"
  SUMMARY="of ${SOURCE}"

  make_tmp_dir
  data_dir="${TMP_DIR}/${BACKUP_NAME}"
  archive="${TMP_DIR}/${BACKUP_NAME}-${timestamp}.tar.gz"
  mkdir -p -- "$data_dir"

  # Fail before spending hours on the download when the destination is not accessible
  info "checking access to ${dest_dir}/"
  rclone lsf --max-depth 1 "${dest_dir}/" >/dev/null

  info "downloading ${SOURCE}"
  rclone copy --stats-one-line --stats=1m --stats-log-level NOTICE "$SOURCE" "$data_dir"

  files="$(find "$data_dir" -type f | wc -l)"
  if ((files == 0)) && ! is_true "$BACKUP_ALLOW_EMPTY"; then
    die "${SOURCE} has no files, refusing to make an empty backup (set BACKUP_ALLOW_EMPTY=true to allow)"
  fi

  info "archiving ${files} file(s), $(du -sh "$data_dir" | cut -f1)"
  tar -C "$TMP_DIR" --use-compress-program=pigz -cf "$archive" "$BACKUP_NAME"
  rm -rf -- "$data_dir"

  info "validating archive"
  entries="$(tar --use-compress-program=pigz -tf "$archive" | grep -cv '/$' || true)"
  ((entries == files)) || die "archive has ${entries} file(s), expected ${files}"

  upload_file="$archive"
  if [[ -n "$AGE_RECIPIENTS" ]]; then
    local -a recipients=() age_args=()
    local r
    read -r -a recipients <<<"${AGE_RECIPIENTS//,/ }"
    for r in "${recipients[@]}"; do age_args+=(--recipient "$r"); done
    info "encrypting archive for ${#recipients[@]} age recipient(s)"
    age "${age_args[@]}" --output "${archive}.age" "$archive"
    rm -f -- "$archive"
    upload_file="${archive}.age"
  fi

  target="${dest_dir}/${upload_file##*/}"
  info "uploading $(du -h "$upload_file" | cut -f1) to ${target}"
  # rclone verifies the checksum of the uploaded object itself
  rclone copyto "$upload_file" "$target"

  local_size="$(stat -c %s "$upload_file")"
  uploaded_size="$(remote_size "$target")"
  [[ "$uploaded_size" == "$local_size" ]] \
    || die "uploaded object size (${uploaded_size:-missing}) does not match local file size (${local_size})"
  info "upload verified (${local_size} bytes)"

  SUMMARY="${SUMMARY} -> ${target}"
  [[ "$BACKUP_KEEP_DAYS" -gt 0 ]] && prune_backups "$dest_dir"

  info "backup finished: ${target}"
}

# Deletes backups older than BACKUP_KEEP_DAYS. Only files following the
# <name>-<YYYYmmddTHHMMSSZ>.tar.gz[.age] naming are considered; the newest backup is always kept.
prune_backups() {
  local dest_dir="$1" cutoff name ts newest
  cutoff="$(date -u -d "-${BACKUP_KEEP_DAYS} days" +%Y%m%dT%H%M%SZ)"
  newest="$(list_backups "$dest_dir" | tail -n 1)"
  info "removing backups older than ${BACKUP_KEEP_DAYS} day(s) (before ${cutoff})"

  local pattern="^${BACKUP_NAME//./\\.}-([0-9]{8}T[0-9]{6}Z)\\.tar\\.gz(\\.age)?$"
  while IFS= read -r name; do
    [[ "$name" =~ $pattern ]] || continue
    ts="${BASH_REMATCH[1]}"
    if [[ "$ts" < "$cutoff" && "$name" != "$newest" ]]; then
      info "deleting expired backup ${name}"
      rclone deletefile "${dest_dir}/${name}"
    fi
  done < <(list_backups "$dest_dir")
}

do_restore() {
  require_env DESTINATION BACKUP_NAME RESTORE_TARGET
  validate_backup_name
  [[ "$RESTORE_CONFIRM" == "$RESTORE_TARGET" ]] \
    || die "restore writes into ${RESTORE_TARGET}; set RESTORE_CONFIRM=${RESTORE_TARGET} to proceed"

  local dest_dir file="${1:-}" remote_file local_file extract_dir src_dir
  dest_dir="$(to_remote "$DESTINATION")/${BACKUP_NAME}"
  SUMMARY="into ${RESTORE_TARGET}"

  if [[ -z "$file" ]]; then
    file="$(list_backups "$dest_dir" | tail -n 1)"
    [[ -n "$file" ]] || die "no backups found in ${dest_dir}/"
    info "no backup file given, using latest: ${file}"
  fi
  # A full path (s3://... or remote:path) restores archives from anywhere, e.g. pre-1.0.0
  # backups that were stored directly under DESTINATION
  if [[ "$file" == *:* ]]; then
    remote_file="$(to_remote "$file")"
  else
    remote_file="${dest_dir}/${file}"
  fi
  SUMMARY="${SUMMARY} from ${remote_file##*/}"

  make_tmp_dir
  local_file="${TMP_DIR}/${remote_file##*/}"
  extract_dir="${TMP_DIR}/extract"

  info "downloading ${remote_file}"
  rclone copyto "$remote_file" "$local_file"

  if [[ "$local_file" == *.age ]]; then
    local identity_file="$AGE_IDENTITY_FILE"
    if [[ -z "$identity_file" ]]; then
      [[ -n "$AGE_IDENTITY" ]] || die "backup is encrypted, set AGE_IDENTITY or AGE_IDENTITY_FILE"
      identity_file="${TMP_DIR}/identity.txt"
      printf '%s\n' "$AGE_IDENTITY" >"$identity_file"
    fi
    info "decrypting backup"
    age --decrypt --identity "$identity_file" --output "${local_file%.age}" "$local_file"
    rm -f -- "$local_file"
    local_file="${local_file%.age}"
  fi

  info "extracting archive"
  mkdir -p -- "$extract_dir"
  tar --use-compress-program=pigz -xf "$local_file" -C "$extract_dir" --no-same-owner --no-same-permissions
  rm -f -- "$local_file"

  # Archives contain a single top-level directory named after BACKUP_NAME at backup time
  local -a top=()
  mapfile -t top < <(find "$extract_dir" -mindepth 1 -maxdepth 1)
  if ((${#top[@]} == 1)) && [[ -d "${top[0]}" ]]; then
    src_dir="${top[0]}"
  else
    src_dir="$extract_dir"
  fi

  local mode=copy
  is_true "$RESTORE_DELETE" && mode=sync
  info "restoring $(find "$src_dir" -type f | wc -l) file(s) into ${RESTORE_TARGET} (rclone ${mode})"
  rclone "$mode" --stats-one-line --stats=1m --stats-log-level NOTICE "$src_dir" "$RESTORE_TARGET"

  info "verifying restored files"
  rclone check --one-way "$src_dir" "$RESTORE_TARGET"

  info "restore finished: ${RESTORE_TARGET} from ${remote_file}"
}

do_list() {
  require_env DESTINATION
  local name="${2:-$BACKUP_NAME}"
  [[ -n "$name" ]] || die "pass a backup name or set BACKUP_NAME"
  list_backups "$(to_remote "$DESTINATION")/${name}"
}

usage() {
  cat >&2 <<EOF
Usage:
  ${SCRIPT_NAME} backup                 archive SOURCE and upload it to DESTINATION/BACKUP_NAME/
  ${SCRIPT_NAME} restore [file]         restore into RESTORE_TARGET (latest backup if no file given)
  ${SCRIPT_NAME} list [backup-name]     list available backups, oldest first
EOF
}

case "$COMMAND" in
  backup) do_backup ;;
  restore) do_restore "${2:-}" ;;
  list) do_list "$@" ;;
  -h | --help | help) usage ;;
  *) usage; exit 64 ;;
esac
