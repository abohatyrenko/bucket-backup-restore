#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts passed to sh_in expand inside the container
#
# End-to-end test: runs backup/restore with the image against an S3-compatible
# server (SeaweedFS) in Docker. Builds the image unless SKIP_BUILD is set.
#
# Usage: test/e2e.sh [image-tag]

set -Eeuo pipefail

cd "$(dirname "$0")/.."

IMAGE="${1:-bucket-backup-restore:e2e}"
S3_IMAGE="${S3_IMAGE:-chrislusf/seaweedfs:latest}"
ID="bbr-e2e-$$"
NET="$ID"
S3_URL="http://$ID-s3:8333"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "$ID-s3" >/dev/null 2>&1 || true
  docker volume rm "$ID-conf" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ -z "${SKIP_BUILD:-}" ]]; then
  log "building image $IMAGE"
  docker build -t "$IMAGE" .
fi

AGE_KEY="$(docker run --rm --entrypoint age-keygen "$IMAGE" 2>/dev/null)"
AGE_PUB="$(grep -o 'age1[0-9a-z]*' <<<"$AGE_KEY")"

log "starting an S3 server (SeaweedFS)"
docker network create "$NET" >/dev/null
docker run -d --name "$ID-s3" --network "$NET" \
  -e AWS_ACCESS_KEY_ID=test-key -e AWS_SECRET_ACCESS_KEY=test-secret "$S3_IMAGE" server -s3 -dir=/data >/dev/null

# Environment building blocks. Every test passes what it needs to `base` or `run`.

# "src" is an rclone remote defined through environment variables, as users of
# non-AWS providers would do (a mounted rclone.conf is tested below)
SRC_REMOTE=(
  -e RCLONE_CONFIG_SRC_TYPE=s3
  -e RCLONE_CONFIG_SRC_PROVIDER=Other
  -e RCLONE_CONFIG_SRC_ENDPOINT="$S3_URL"
  -e RCLONE_CONFIG_SRC_ACCESS_KEY_ID=test-key
  -e RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY=test-secret
)
# Credentials for s3:// paths
AWS_KEYS=(-e AWS_ACCESS_KEY_ID=test-key -e AWS_SECRET_ACCESS_KEY=test-secret -e S3_ENDPOINT="$S3_URL")
BACKUP_ENV=(
  -e SOURCE=src:source
  -e DESTINATION=s3://backups/bucket
  -e BACKUP_NAME=assets
)
RESTORE_ENV=(-e RESTORE_TARGET=src:target -e RESTORE_CONFIRM=src:target)
DECRYPT=(-e AGE_IDENTITY="$AGE_KEY")

base() { docker run --rm --network "$NET" --read-only --tmpfs /tmp "$@"; }
# The usual setup: source and target via the "src" remote, backups in s3://backups/bucket
run() { base "${SRC_REMOTE[@]}" "${AWS_KEYS[@]}" "${BACKUP_ENV[@]}" "$@"; }
rcl() { base "${SRC_REMOTE[@]}" -e RCLONE_CONFIG=/dev/null --entrypoint rclone "$IMAGE" "$@"; }
sh_in() { base "${SRC_REMOTE[@]}" -e RCLONE_CONFIG=/dev/null --entrypoint sh "$IMAGE" -euc "$1"; }
same() { rcl check "$1" "$2" 2>/dev/null; }

bucket_created=""
for _ in $(seq 60); do
  rcl mkdir src:source >/dev/null 2>&1 && bucket_created=1 && break
  sleep 1
done
[[ -n "$bucket_created" ]] || fail "could not create S3 bucket"
for b in target target2 backups empty; do rcl mkdir "src:$b"; done

log "seeding source bucket"
sh_in '
  d=/tmp/data
  mkdir -p "$d/css" "$d/img/2026/11" "$d/with space" "$d/unicode-файлы"
  echo "body {}" >"$d/css/site.css"
  head -c 5000000 /dev/urandom >"$d/img/2026/11/photo.bin"
  : >"$d/empty.txt"
  echo hello >"$d/with space/file name.txt"
  echo привет >"$d/unicode-файлы/тест.txt"
  for i in $(seq 1 200); do echo "$i" >"$d/img/$i.txt"; done
  rclone copy "$d" src:source'

log "seeding an expired backup, a non-backup file and a pre-1.0.0 backup"
sh_in '
  echo old | rclone rcat src:backups/bucket/assets/assets-20200101T000000Z.tar.gz
  echo note | rclone rcat src:backups/bucket/assets/README.txt
  mkdir -p /tmp/old/assets
  echo legacy >/tmp/old/assets/legacy.txt
  tar -C /tmp/old -czf /tmp/assets-2022-04-21.tar.gz assets
  rclone copyto /tmp/assets-2022-04-21.tar.gz src:backups/bucket/assets-2022-04-21.tar.gz'

log "backup (encrypted, retention 7 days)"
run -e AGE_RECIPIENTS="$AGE_PUB" -e BACKUP_KEEP_DAYS=7 "$IMAGE" backup

log "list"
listing="$(run "$IMAGE" list)"
echo "$listing"
grep -q 'assets-20200101T000000Z' <<<"$listing" && fail "expired backup was not pruned"
grep -q 'README.txt' <<<"$listing" && fail "list shows a file that is not a backup"
grep -qE '^assets-[0-9]{8}T[0-9]{6}Z\.tar\.gz\.age$' <<<"$listing" || fail "encrypted backup not found"
rcl lsf src:backups/bucket/assets | grep -qx README.txt || fail "retention deleted a file that is not a backup"

log "restore without RESTORE_TARGET / RESTORE_CONFIRM must be refused"
if run "${DECRYPT[@]}" "$IMAGE" restore; then
  fail "restore ran without RESTORE_TARGET"
fi
if run "${DECRYPT[@]}" -e RESTORE_TARGET=src:target "$IMAGE" restore; then
  fail "restore ran without confirmation"
fi

log "restore without decryption key must fail"
if run "${RESTORE_ENV[@]}" "$IMAGE" restore; then
  fail "restore of encrypted backup succeeded without a key"
fi

log "restore with wrong storage credentials must fail with an access error, not 'no backups found'"
if out="$(base "${SRC_REMOTE[@]}" "${BACKUP_ENV[@]}" "${RESTORE_ENV[@]}" "${DECRYPT[@]}" \
  -e AWS_ACCESS_KEY_ID=test-key -e AWS_SECRET_ACCESS_KEY=wrong -e S3_ENDPOINT="$S3_URL" \
  "$IMAGE" restore 2>&1)"; then
  fail "restore succeeded with wrong credentials"
fi
grep -q 'cannot list' <<<"$out" || fail "unexpected error for wrong credentials: $out"

log "restore latest backup into the target bucket (twice, to check it is repeatable)"
run "${RESTORE_ENV[@]}" "${DECRYPT[@]}" "$IMAGE" restore
run "${RESTORE_ENV[@]}" "${DECRYPT[@]}" "$IMAGE" restore
same src:source src:target || fail "restored bucket differs from the source"

log "restore keeps unrelated files by default, RESTORE_DELETE=true removes them"
sh_in "echo extra | rclone rcat src:target/extra.txt"
run "${RESTORE_ENV[@]}" "${DECRYPT[@]}" "$IMAGE" restore
rcl lsf src:target | grep -qx extra.txt || fail "restore deleted a file without RESTORE_DELETE"
run "${RESTORE_ENV[@]}" "${DECRYPT[@]}" -e RESTORE_DELETE=true "$IMAGE" restore
same src:source src:target || fail "RESTORE_DELETE=true did not make the target identical to the source"

log "unencrypted backup with pre-1.0.0 variable names (with deprecation warnings)"
out="$(base "${SRC_REMOTE[@]}" "${AWS_KEYS[@]}" \
  -e SRC_BUCKET=src:source -e DST_BUCKET=s3://backups/bucket -e BACKUP_NAME=assets \
  -e BANDWITH_LIMIT=100M -e TRANSACTION_LIMIT=50 \
  "$IMAGE" backup 2>&1)" || fail "backup with pre-1.0.0 variable names failed: $out"
grep -q 'SRC_BUCKET is deprecated' <<<"$out" || fail "no deprecation warning for SRC_BUCKET"

log "restore of a specific file, with s3:// as the restore target"
file="$(run "$IMAGE" list | grep -E '\.tar\.gz$' | tail -n 1)"
[[ -n "$file" ]] || fail "unencrypted backup not found"
run -e RESTORE_TARGET=s3://target2/restored -e RESTORE_CONFIRM=s3://target2/restored "$IMAGE" restore "$file"
same src:source src:target2/restored || fail "restore of ${file} differs from the source"

log "restore of a pre-1.0.0 backup by full path"
run "${RESTORE_ENV[@]}" "$IMAGE" restore s3://backups/bucket/assets-2022-04-21.tar.gz
[[ "$(rcl cat src:target/legacy.txt)" == legacy ]] || fail "pre-1.0.0 backup was not restored"

log "s3:// as the source"
run -e SOURCE=s3://source -e BACKUP_NAME=s3source "$IMAGE" backup
(($(run "$IMAGE" list s3source | wc -l) == 1)) || fail "backup of an s3:// source not found"

log "backup of an empty bucket must fail unless allowed"
if run -e SOURCE=src:empty "$IMAGE" backup; then
  fail "backup of an empty bucket succeeded"
fi
run -e SOURCE=src:empty -e BACKUP_ALLOW_EMPTY=true -e BACKUP_NAME=empty "$IMAGE" backup

log "backup with wrong source credentials must fail"
if run -e RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY=wrong "$IMAGE" backup; then
  fail "backup succeeded with wrong source credentials"
fi

log "first backup into a destination directory that does not exist yet (local filesystem)"
base "${SRC_REMOTE[@]}" -e SOURCE=src:source -e DESTINATION=/tmp/backups -e BACKUP_NAME=assets \
  --entrypoint sh "$IMAGE" -euc 'bucket_backup_restore.sh backup && bucket_backup_restore.sh list | grep -q tar.gz' \
  || fail "backup into a new local directory failed"

log "remotes from a mounted rclone.conf (as the Helm chart does), destination as an rclone remote"
docker volume create "$ID-conf" >/dev/null
docker run --rm -v "$ID-conf:/c" alpine:3 sh -c "
  printf '[spaces]\ntype = s3\nprovider = Other\nendpoint = $S3_URL\naccess_key_id = test-key\nsecret_access_key = test-secret\n' >/c/rclone.conf
  printf '[default]\naws_access_key_id = test-key\naws_secret_access_key = test-secret\n' >/c/credentials
  chmod 644 /c/rclone.conf /c/credentials"
base -v "$ID-conf:/config/rclone:ro" \
  -e SOURCE=spaces:source -e DESTINATION=spaces:backups/conf -e BACKUP_NAME=assets \
  "$IMAGE" backup
(($(rcl lsf src:backups/conf/assets | wc -l) == 1)) || fail "backup with rclone.conf remotes did not upload"

log "a missing custom RCLONE_CONFIG is reported"
out="$(run -e RCLONE_CONFIG=/nope/rclone.conf "$IMAGE" list 2>&1)"
grep -q 'RCLONE_CONFIG=/nope/rclone.conf does not exist' <<<"$out" || fail "no warning for a missing RCLONE_CONFIG"

log "AWS credentials from a shared credentials file, no AWS_* keys in the environment"
FILE_CREDS=(-v "$ID-conf:/aws:ro" -e AWS_SHARED_CREDENTIALS_FILE=/aws/credentials -e S3_ENDPOINT="$S3_URL")
before="$(run "$IMAGE" list | wc -l)"
base "${SRC_REMOTE[@]}" "${FILE_CREDS[@]}" "${BACKUP_ENV[@]}" "$IMAGE" backup
after="$(run "$IMAGE" list | wc -l)"
((after == before + 1)) || fail "backup with file-based credentials did not upload ($before -> $after backups)"

log "backup without any AWS credentials must fail"
if base "${SRC_REMOTE[@]}" "${BACKUP_ENV[@]}" -e S3_ENDPOINT="$S3_URL" -e AWS_EC2_METADATA_DISABLED=true "$IMAGE" backup; then
  fail "backup succeeded without AWS credentials"
fi

log "ALL TESTS PASSED"
