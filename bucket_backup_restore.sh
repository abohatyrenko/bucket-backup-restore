#!/usr/bin/env bash
#
# Backup of an S3-compatible bucket (or any rclone remote) into a dated, optionally
# encrypted tar.gz archive in another bucket, and restore from it.
#
# Usage:
#   bucket_backup_restore.sh backup
#   bucket_backup_restore.sh restore [backup-file-name | full-path]   # latest backup if omitted
#   bucket_backup_restore.sh list [backup-name]
#
# All configuration is done through environment variables, see README.md.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_RCLONE_CONFIG=/config/rclone/rclone.conf

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${*:2}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
die() { log ERROR "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Paths are rclone paths (remote:bucket/path) or s3://bucket/path
SOURCE="${SOURCE:-}"
SOURCE="${SOURCE%/}"
DESTINATION="${DESTINATION:-}"
DESTINATION="${DESTINATION%/}"
BACKUP_NAME="${BACKUP_NAME:-}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-0}"
BACKUP_ALLOW_EMPTY="${BACKUP_ALLOW_EMPTY:-false}"

# s3:// paths
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_PROVIDER="${S3_PROVIDER:-}"
S3_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

# Restore
RESTORE_TARGET="${RESTORE_TARGET:-}"
RESTORE_TARGET="${RESTORE_TARGET%/}"
RESTORE_CONFIRM="${RESTORE_CONFIRM:-}"
RESTORE_CONFIRM="${RESTORE_CONFIRM%/}"
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

# Remotes can come from RCLONE_CONFIG_<REMOTE>_* variables only. Without a config file
# rclone prints a notice on every call, so the image default may be missing silently.
if [[ -n "${RCLONE_CONFIG:-}" && ! -e "$RCLONE_CONFIG" ]]; then
  [[ "$RCLONE_CONFIG" == "$DEFAULT_RCLONE_CONFIG" ]] \
    || warn "RCLONE_CONFIG=${RCLONE_CONFIG} does not exist, only remotes from RCLONE_CONFIG_* variables are available"
  export RCLONE_CONFIG=/dev/null
fi

# s3://bucket/path stands for an S3 remote that takes credentials from the AWS credential
# chain (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, shared credentials file, IRSA / EKS Pod
# Identity, instance profile) and S3_ENDPOINT / AWS_REGION.
export RCLONE_CONFIG_S3URL_TYPE=s3
export RCLONE_CONFIG_S3URL_ENV_AUTH=true
# Backup credentials usually may not create buckets
export RCLONE_CONFIG_S3URL_NO_CHECK_BUCKET=true
if [[ -n "$S3_ENDPOINT" ]]; then
  export RCLONE_CONFIG_S3URL_PROVIDER="${S3_PROVIDER:-Other}"
  export RCLONE_CONFIG_S3URL_ENDPOINT="$S3_ENDPOINT"
else
  export RCLONE_CONFIG_S3URL_PROVIDER="${S3_PROVIDER:-AWS}"
fi
if [[ -n "$S3_REGION" ]]; then export RCLONE_CONFIG_S3URL_REGION="$S3_REGION"; fi

COMMAND="${1:-}"
TMP_DIR=""
SUMMARY=""
# Set when the command ran to its end, see on_exit
FINISHED=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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
  # When the shell is killed by a signal (job deadline, pod eviction), $? is the status of the
  # last finished command, usually 0: without this an interrupted run is reported as a success.
  if ((rc == 0)) && [[ -z "$FINISHED" ]]; then rc=143; fi
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

# rclone with s3://bucket/path arguments translated to the "s3" remote, so that
# logs and messages can use the paths as the user wrote them
rcl() {
  local arg args=()
  for arg in "$@"; do
    [[ "$arg" == s3://* ]] && arg="s3url:${arg#s3://}"
    args+=("$arg")
  done
  rclone "${args[@]}"
}

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "backup name '$1' may only contain letters, digits, '.', '_' and '-'"
}

# Prints the backups of name $2 in directory $1, oldest first. The timestamp in the
# name sorts chronologically. A directory that does not exist yet has no backups.
list_backups() {
  local dir="$1" name="$2" listing status=0
  listing="$(rcl lsf --files-only "${dir}/")" || status=$?
  # rclone exit code 3: directory not found
  ((status == 0 || status == 3)) || die "cannot list ${dir}/ (rclone exit code ${status})"
  grep -E "^${name//./\\.}-[0-9]{8}T[0-9]{6}Z\\.tar\\.gz(\\.age)?$" <<<"$listing" | sort || true
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

do_backup() {
  require_env SOURCE DESTINATION BACKUP_NAME
  validate_name "$BACKUP_NAME"
  [[ "$BACKUP_KEEP_DAYS" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP_DAYS must be a non-negative integer"

  local timestamp dest_dir data_dir archive upload_file target files entries
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest_dir="${DESTINATION}/${BACKUP_NAME}"
  SUMMARY="of ${SOURCE}"

  # Fail before spending hours on the download when the destination is not accessible
  info "checking access to ${dest_dir}/"
  list_backups "$dest_dir" "$BACKUP_NAME" >/dev/null

  make_tmp_dir
  data_dir="${TMP_DIR}/${BACKUP_NAME}"
  archive="${TMP_DIR}/${BACKUP_NAME}-${timestamp}.tar.gz"
  mkdir -p -- "$data_dir"

  info "downloading ${SOURCE}"
  rcl copy --stats-one-line --stats=1m --stats-log-level NOTICE "$SOURCE" "$data_dir"

  files="$(find "$data_dir" -type f | wc -l)"
  if ((files == 0)) && ! is_true "$BACKUP_ALLOW_EMPTY"; then
    die "${SOURCE} has no files, refusing to make an empty backup (set BACKUP_ALLOW_EMPTY=true to allow)"
  fi

  info "archiving ${files} file(s), $(du -sh "$data_dir" | cut -f1)"
  # pigz compresses on all cores, the result is a regular gzip file
  tar -C "$TMP_DIR" --use-compress-program=pigz -cf "$archive" "$BACKUP_NAME"
  rm -rf -- "$data_dir"

  info "validating archive"
  entries="$(tar -tzf "$archive" | awk '!/\/$/ { n++ } END { print n + 0 }')"
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
  # rclone compares size and checksum of the uploaded object with the local file
  rcl copyto "$upload_file" "$target"

  SUMMARY="${SUMMARY} -> ${target}"
  if ((10#$BACKUP_KEEP_DAYS > 0)); then prune_backups "$dest_dir"; fi

  info "backup finished: ${target}"
}

# Deletes backups older than BACKUP_KEEP_DAYS, judging by the timestamp in their name.
# The newest backup is always kept.
prune_backups() {
  local dest_dir="$1" cutoff listing name
  cutoff="$(date -u -d "-${BACKUP_KEEP_DAYS} days" +%Y%m%dT%H%M%SZ)"
  info "removing backups older than ${BACKUP_KEEP_DAYS} day(s) (before ${cutoff})"

  listing="$(list_backups "$dest_dir" "$BACKUP_NAME" | sed '$d')"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    local ts="${name#"${BACKUP_NAME}"-}"
    if [[ "${ts%%.*}" < "$cutoff" ]]; then
      info "deleting expired backup ${name}"
      rcl deletefile "${dest_dir}/${name}"
    fi
  done <<<"$listing"
}

do_restore() {
  require_env DESTINATION BACKUP_NAME RESTORE_TARGET
  validate_name "$BACKUP_NAME"
  [[ "$RESTORE_CONFIRM" == "$RESTORE_TARGET" ]] \
    || die "restore writes into ${RESTORE_TARGET}; set RESTORE_CONFIRM=${RESTORE_TARGET} to proceed"

  local dest_dir file="${1:-}" source_file local_file extract_dir src_dir
  dest_dir="${DESTINATION}/${BACKUP_NAME}"
  SUMMARY="into ${RESTORE_TARGET}"

  if [[ -z "$file" ]]; then
    file="$(list_backups "$dest_dir" "$BACKUP_NAME" | tail -n 1)"
    [[ -n "$file" ]] || die "no backups found in ${dest_dir}/"
    info "no backup file given, using latest: ${file}"
  fi
  # A full path (s3://... or remote:path) restores an archive from anywhere
  if [[ "$file" == *:* ]]; then
    source_file="$file"
  else
    source_file="${dest_dir}/${file}"
  fi
  SUMMARY="${SUMMARY} from ${source_file##*/}"

  make_tmp_dir
  local_file="${TMP_DIR}/${source_file##*/}"
  extract_dir="${TMP_DIR}/extract"

  info "downloading ${source_file}"
  rcl copyto "$source_file" "$local_file"

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
  tar -xzf "$local_file" -C "$extract_dir" --no-same-owner --no-same-permissions
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
  rcl "$mode" --stats-one-line --stats=1m --stats-log-level NOTICE "$src_dir" "$RESTORE_TARGET"

  info "verifying restored files"
  rcl check --one-way "$src_dir" "$RESTORE_TARGET"

  info "restore finished: ${RESTORE_TARGET} from ${source_file}"
}

do_list() {
  require_env DESTINATION
  local name="${1:-$BACKUP_NAME}"
  [[ -n "$name" ]] || die "pass a backup name or set BACKUP_NAME"
  validate_name "$name"
  list_backups "${DESTINATION}/${name}" "$name"
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
  list) do_list "${2:-}" ;;
  -h | --help | help) usage ;;
  *) usage; exit 64 ;;
esac
FINISHED=1
