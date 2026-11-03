#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts passed to sh_in expand inside the container
#
# End-to-end test: builds the image and runs backup/restore against an
# S3-compatible server (SeaweedFS) in Docker.
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

# "src" is an rclone remote defined through environment variables, as users of
# non-AWS providers would do (or with a mounted rclone.conf, tested below)
SRC_ENV=(
  -e RCLONE_CONFIG_SRC_TYPE=s3
  -e RCLONE_CONFIG_SRC_PROVIDER=Other
  -e RCLONE_CONFIG_SRC_ENDPOINT="$S3_URL"
  -e RCLONE_CONFIG_SRC_ACCESS_KEY_ID=test-key
  -e RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY=test-secret
)
AWS_ENV=(
  -e AWS_ACCESS_KEY_ID=test-key
  -e AWS_SECRET_ACCESS_KEY=test-secret
)
COMMON_ENV=(
  -e SOURCE=src:source
  -e DESTINATION=s3://backups/bucket
  -e S3_ENDPOINT="$S3_URL"
  -e BACKUP_NAME=assets
  -e RESTORE_TARGET=src:target
)
run() { docker run --rm --network "$NET" --read-only --tmpfs /tmp "${SRC_ENV[@]}" "${COMMON_ENV[@]}" "${AWS_ENV[@]}" "$@"; }
rcl() { run -e RCLONE_CONFIG=/dev/null --entrypoint rclone "$IMAGE" "$@"; }
sh_in() { run -e RCLONE_CONFIG=/dev/null --entrypoint sh "$IMAGE" -euc "$1"; }

bucket_created=""
for _ in $(seq 60); do
  rcl mkdir src:source >/dev/null 2>&1 && bucket_created=1 && break
  sleep 1
done
[[ -n "$bucket_created" ]] || fail "could not create S3 bucket"
rcl mkdir src:target
rcl mkdir src:backups
rcl mkdir src:empty

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

log "seeding an expired backup for retention test and a pre-1.0.0 backup"
sh_in '
  echo old | rclone rcat src:backups/bucket/assets/assets-20200101T000000Z.tar.gz
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
grep -qE '^assets-[0-9]{8}T[0-9]{6}Z\.tar\.gz\.age$' <<<"$listing" || fail "encrypted backup not found"

log "restore without RESTORE_CONFIRM must be refused"
if run -e AGE_IDENTITY="$AGE_KEY" "$IMAGE" restore; then
  fail "restore ran without confirmation"
fi

log "restore without decryption key must fail"
if run -e RESTORE_CONFIRM=src:target "$IMAGE" restore; then
  fail "restore of encrypted backup succeeded without a key"
fi

log "restore latest backup into the target bucket (twice, to check it is repeatable)"
run -e RESTORE_CONFIRM=src:target -e AGE_IDENTITY="$AGE_KEY" "$IMAGE" restore
run -e RESTORE_CONFIRM=src:target -e AGE_IDENTITY="$AGE_KEY" "$IMAGE" restore
rcl check src:source src:target || fail "restored bucket differs from the source"

log "restore keeps unrelated files by default, RESTORE_DELETE=true removes them"
sh_in "echo extra | rclone rcat src:target/extra.txt"
run -e RESTORE_CONFIRM=src:target -e AGE_IDENTITY="$AGE_KEY" "$IMAGE" restore
rcl lsf src:target | grep -qx extra.txt || fail "restore deleted a file without RESTORE_DELETE"
run -e RESTORE_CONFIRM=src:target -e AGE_IDENTITY="$AGE_KEY" -e RESTORE_DELETE=true "$IMAGE" restore
rcl check src:source src:target || fail "RESTORE_DELETE=true did not make the target identical to the source"

log "unencrypted backup with pre-1.0.0 variable names + restore of a specific file"
docker run --rm --network "$NET" --read-only --tmpfs /tmp "${SRC_ENV[@]}" "${AWS_ENV[@]}" \
  -e SRC_BUCKET=src:source -e DST_BUCKET=s3://backups/bucket -e S3_ENDPOINT="$S3_URL" \
  -e BACKUP_NAME=assets -e BANDWITH_LIMIT=100M -e TRANSACTION_LIMIT=50 \
  "$IMAGE" backup
file="$(run "$IMAGE" list | grep -E '\.tar\.gz$' | tail -n 1)"
[[ -n "$file" ]] || fail "unencrypted backup not found"
rcl purge src:target
rcl mkdir src:target
run -e RESTORE_CONFIRM=src:target "$IMAGE" restore "$file"
rcl check src:source src:target || fail "restore of ${file} differs from the source"

log "restore of a pre-1.0.0 backup by full path"
run -e RESTORE_CONFIRM=src:target "$IMAGE" restore s3://backups/bucket/assets-2022-04-21.tar.gz
[[ "$(rcl cat src:target/legacy.txt)" == legacy ]] || fail "pre-1.0.0 backup was not restored"

log "backup of an empty bucket must fail unless allowed"
if run -e SOURCE=src:empty "$IMAGE" backup; then
  fail "backup of an empty bucket succeeded"
fi
run -e SOURCE=src:empty -e BACKUP_ALLOW_EMPTY=true -e BACKUP_NAME=empty "$IMAGE" backup

log "backup with wrong source credentials must fail"
if run -e RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY=wrong "$IMAGE" backup; then
  fail "backup succeeded with wrong source credentials"
fi

log "remotes from a mounted rclone.conf (as the Helm chart does), destination as an rclone remote"
docker volume create "$ID-conf" >/dev/null
docker run --rm -v "$ID-conf:/c" alpine:3 sh -c "
  printf '[spaces]\ntype = s3\nprovider = Other\nendpoint = $S3_URL\naccess_key_id = test-key\nsecret_access_key = test-secret\n' >/c/rclone.conf
  printf '[default]\naws_access_key_id = test-key\naws_secret_access_key = test-secret\n' >/c/credentials
  chmod 644 /c/rclone.conf /c/credentials"
docker run --rm --network "$NET" --read-only --tmpfs /tmp -v "$ID-conf:/config/rclone:ro" \
  -e SOURCE=spaces:source -e DESTINATION=spaces:backups/conf -e BACKUP_NAME=assets \
  "$IMAGE" backup
(($(rcl lsf src:backups/conf/assets | wc -l) == 1)) || fail "backup with rclone.conf remotes did not upload"

log "AWS credentials from a shared credentials file, no AWS_* keys in the environment"
AWS_ENV=(-v "$ID-conf:/aws:ro" -e AWS_SHARED_CREDENTIALS_FILE=/aws/credentials)
before="$(run "$IMAGE" list | wc -l)"
run "$IMAGE" backup
after="$(run "$IMAGE" list | wc -l)"
((after == before + 1)) || fail "backup with file-based credentials did not upload ($before -> $after backups)"

log "backup without any AWS credentials must fail"
AWS_ENV=(-e AWS_EC2_METADATA_DISABLED=true)
if run "$IMAGE" backup; then
  fail "backup succeeded without AWS credentials"
fi

log "ALL TESTS PASSED"
