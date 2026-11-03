# S3 bucket backup/restore

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/bucket-backup-restore)](https://artifacthub.io/packages/search?repo=bucket-backup-restore)
[![security-scan](https://github.com/abohatyrenko/bucket-backup-restore/actions/workflows/security-scan.yml/badge.svg)](https://github.com/abohatyrenko/bucket-backup-restore/actions/workflows/security-scan.yml)

Backups of an S3-compatible bucket (DigitalOcean Spaces, AWS S3, Cloudflare R2, MinIO, ... or any other
[rclone remote](https://rclone.org/overview/)) into dated, optionally encrypted `tar.gz` archives in another
bucket, and restore from them. Ships as a Docker image and a Helm chart that runs backups as a Kubernetes CronJob.

```
backup:   SOURCE --(rclone copy)--> local disk --(tar.gz, age)--> DESTINATION/<BACKUP_NAME>/<BACKUP_NAME>-<YYYYmmddTHHMMSSZ>.tar.gz[.age]
restore:  DESTINATION/<BACKUP_NAME>/<archive> --(age, tar)--> local disk --(rclone copy|sync)--> RESTORE_TARGET
```

Features:

- every archive is checked against the number of downloaded files, rclone verifies the checksum of the upload
  and the uploaded object size is compared with the local file
- every restore is verified with `rclone check` against the extracted archive
- optional client-side encryption with [age](https://age-encryption.org)
- retention (`BACKUP_KEEP_DAYS`)
- restore guard: a restore only runs when `RESTORE_CONFIRM` equals the restore target;
  files that are not in the backup are only deleted from the target with `RESTORE_DELETE=true`
- an empty source bucket fails the backup instead of silently producing empty archives
- access to the destination is checked before the source is downloaded
- Slack notifications and heartbeat pings (healthchecks.io, Better Stack, Cronitor, ...)
- `s3://bucket/path` paths with AWS credentials from env vars or the default credential chain (IRSA, EKS Pod Identity, instance profile, ...)
- non-root, read-only root filesystem friendly image for `linux/amd64` and `linux/arm64`

## Usage

```sh
docker run --rm \
  -v ~/.config/rclone/rclone.conf:/config/rclone/rclone.conf:ro \
  -e SOURCE=spaces:my-bucket \
  -e DESTINATION=s3://my-backups/buckets \
  -e BACKUP_NAME=my-bucket \
  -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... -e AWS_REGION=eu-central-1 \
  abohatyrenko/bucket-backup-restore backup
```

`spaces` is a remote from [rclone.conf](rclone_example.conf). Remotes can also be defined with environment
variables only, without a config file:

```sh
  -e RCLONE_CONFIG_SPACES_TYPE=s3 \
  -e RCLONE_CONFIG_SPACES_PROVIDER=DigitalOcean \
  -e RCLONE_CONFIG_SPACES_ENDPOINT=fra1.digitaloceanspaces.com \
  -e RCLONE_CONFIG_SPACES_ACCESS_KEY_ID=... \
  -e RCLONE_CONFIG_SPACES_SECRET_ACCESS_KEY=... \
```

Commands:

| Command | Description |
|---|---|
| `backup` | Archive `SOURCE` and upload it to `DESTINATION/<BACKUP_NAME>/<BACKUP_NAME>-<YYYYmmddTHHMMSSZ>.tar.gz[.age]` |
| `restore [file]` | Restore the latest backup (or the given file name, or a full `remote:path` / `s3://` path) into `RESTORE_TARGET` |
| `list [name]` | List backups of `BACKUP_NAME` (or the given name), oldest first |

The script also runs outside Docker; it needs `bash`, `rclone`, GNU `tar`, `pigz`, `curl` and, for encryption, `age`.

### Configuration

**Source and destination**

| Variable | Default | Description |
|---|---|---|
| `SOURCE` | (required) | Bucket to back up, e.g. `spaces:my-bucket` or `spaces:my-bucket/images` |
| `DESTINATION` | (required) | Where archives are stored, e.g. `s3://my-backups/buckets` or `backup:my-backups/buckets` |
| `BACKUP_NAME` | (required) | Name of the backup set: archives go to `DESTINATION/<BACKUP_NAME>/` |
| `S3_ENDPOINT` | AWS | For `s3://` paths outside AWS, e.g. `https://fra1.digitaloceanspaces.com` |
| `S3_PROVIDER` | `AWS`, or `Other` with `S3_ENDPOINT` | rclone [S3 provider](https://rclone.org/s3/#s3-provider) for `s3://` paths |
| `AWS_REGION` | | Region for `s3://` paths |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | | Credentials for `s3://` paths, optional: any [AWS credential source](https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html) works (IRSA, shared credentials file, ...) |
| `RCLONE_CONFIG` | `/config/rclone/rclone.conf` | rclone config file. Optional when remotes come from `RCLONE_CONFIG_<REMOTE>_*` variables |
| `RCLONE_<FLAG>` | | Any [rclone flag](https://rclone.org/flags/), e.g. `RCLONE_TRANSFERS=16`, `RCLONE_BWLIMIT=10M`, `RCLONE_TPSLIMIT=20`, `RCLONE_EXCLUDE=cache/**` |

All paths are [rclone paths](https://rclone.org/docs/#syntax-of-remote-paths) (`remote:bucket/path`) or
`s3://bucket/path`. All `s3://` paths share one set of AWS credentials and `S3_ENDPOINT`; when source and
destination are with different providers or accounts, define an rclone remote for at least one of them.

**Backup**

| Variable | Default | Description |
|---|---|---|
| `BACKUP_KEEP_DAYS` | `0` (keep all) | Delete backups older than N days after a successful backup. The newest backup is never deleted |
| `BACKUP_ALLOW_EMPTY` | `false` | Allow backups of a source without files (usually means a wrong `SOURCE` or credentials) |
| `AGE_RECIPIENTS` | | age public key(s), comma or space separated. When set, backups are encrypted |

**Restore**

| Variable | Default | Description |
|---|---|---|
| `RESTORE_TARGET` | (required) | Where to restore to, e.g. `spaces:my-bucket-restored` (can be the original bucket) |
| `RESTORE_CONFIRM` | (required) | Must equal `RESTORE_TARGET` |
| `RESTORE_DELETE` | `false` | Also delete files in the target that are not in the backup (`rclone sync` instead of `rclone copy`) |
| `AGE_IDENTITY` / `AGE_IDENTITY_FILE` | | age secret key (content or file path) to decrypt `.age` backups |

**Notifications, other**

| Variable | Default | Description |
|---|---|---|
| `SLACK_WEBHOOK_URL` | | Slack incoming webhook |
| `NOTIFY_ON` | `failure` | `failure`, `always` or `never` |
| `HEARTBEAT_URL` | | Pinged after every successful backup. Use a dead man's switch to get alerted when backups stop running at all |
| `HEARTBEAT_FAIL_URL` | | Pinged when a backup fails, e.g. `https://hc-ping.com/<uuid>/fail` |
| `WORK_DIR` | `/tmp/bucket-backup-restore` | Scratch space; needs room for the bucket **and** its archive (about 2x the bucket size) |

### Encryption

```sh
docker run --rm --entrypoint age-keygen abohatyrenko/bucket-backup-restore
# Public key: age1...        -> AGE_RECIPIENTS for backups
# AGE-SECRET-KEY-1...        -> AGE_IDENTITY for restores, store it somewhere safe outside the cluster
```

Only the public key is needed to make backups, so a compromised backup job cannot read old backups.

### Restoring

```sh
docker run --rm \
  -v ~/.config/rclone/rclone.conf:/config/rclone/rclone.conf:ro \
  -e DESTINATION=s3://my-backups/buckets -e BACKUP_NAME=my-bucket \
  -e RESTORE_TARGET=spaces:my-bucket-restored -e RESTORE_CONFIRM=spaces:my-bucket-restored \
  -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... -e AWS_REGION=eu-central-1 \
  abohatyrenko/bucket-backup-restore restore                 # latest
  # ...                                restore my-bucket-20261030T110000Z.tar.gz
```

Test your restores regularly, e.g. with a scheduled restore into a scratch bucket.

Archives contain the files and their modification times. Object metadata is not kept: on restore,
`Content-Type` is derived from the file extension, and ACLs come from the target remote settings
(e.g. `acl = public-read` in rclone.conf for a public CDN bucket).

## Recommendations for production

- Store backups with another provider or at least in another account / region than the source.
- Enable versioning and Object Lock (or at least a lifecycle rule) on the destination bucket, and give the backup
  credentials only `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` (+ `s3:DeleteObject` if `BACKUP_KEEP_DAYS` is used).
- Use read-only credentials for the source bucket in backup jobs.
- Set `HEARTBEAT_URL` or alert on failed Kubernetes Jobs (e.g. `kube_job_status_failed` from kube-state-metrics).
- Archives are full copies. For very large buckets (hundreds of GB and more), consider provider-side replication with
  versioning, or `rclone sync --backup-dir` for incremental copies, instead of daily full archives.

## Helm chart

See the [chart README](helm/README.md).

## What is tested

Every CI run builds the image once, runs [`test/e2e.sh`](test/e2e.sh) with it against an S3-compatible server
([SeaweedFS](https://github.com/seaweedfs/seaweedfs)) in Docker:

- encrypted and plain backup/restore of nested, empty, unicode and space-containing file names, verified with `rclone check`
- retention, restore of the latest or a specific backup, repeated restores, `RESTORE_DELETE`
- restore of a pre-1.0.0 backup by full path, pre-1.0.0 variable names
- restore guard, missing decryption key, empty source and bad source credentials fail the job
- remotes from a mounted `rclone.conf` and from `RCLONE_CONFIG_*` variables, `s3://` as source, destination and restore target
- a first backup into a directory that does not exist yet (local filesystem), files that are not backups are
  neither listed nor deleted by retention, wrong storage credentials are reported as such
- AWS credentials from a shared credentials file instead of environment variables; no credentials fail the job

The Helm chart is linted and validated with kubeconform, and was tested manually in a kind cluster.

The image is scanned with [Trivy](https://trivy.dev) before it is published: CI fails on critical or high
vulnerabilities that have a fix. The published `latest` image is rescanned every week.

Not tested yet (should work, feedback welcome): DigitalOcean Spaces, AWS S3, Cloudflare R2 and other hosted
storage, IRSA / EKS Pod Identity.

## Development

```sh
docker build -t bucket-backup-restore .
test/e2e.sh   # see "What is tested" above
```

rclone is installed from Alpine packages, so the rclone version follows the Alpine release in the `Dockerfile`.

### Release

The chart and the image share one version: `X.Y.Z` means chart `X.Y.Z` with image `X.Y.Z`.

1. In `helm/Chart.yaml`, set `version`, `appVersion` and the image in `artifacthub.io/images` to `X.Y.Z`,
   and describe the release in `artifacthub.io/changes`. `scripts/check-version.sh` checks they match.
2. Package the chart and add it to the chart repository index:

   ```sh
   helm package ./helm -d helm/packages
   # index only the new package, so existing entries keep their dates
   tmp=$(mktemp -d) && mkdir "$tmp/packages" && cp helm/packages/bucket-backup-restore-X.Y.Z.tgz "$tmp/packages/"
   helm repo index "$tmp" --url https://abohatyrenko.github.io/bucket-backup-restore/helm/ --merge helm/index.yaml
   cp "$tmp/index.yaml" helm/index.yaml
   ```

3. Merge the PR. GitHub Pages publishes the chart from `main`.
4. Push the tag `vX.Y.Z` on the merge commit. CI checks that the tag matches the chart version and that the
   chart package exists, tests and scans the image and publishes it to Docker Hub. Until then, the new chart version
   points to an image that doesn't exist yet, so tag right after merging.

Release candidates (`vX.Y.Z-rc.N`) are published without the `latest` and `X.Y` tags; pre-release chart
versions are only installed with `--devel` or an explicit `--version`.

## Upgrading to 1.0.0 (image 0.x / chart 0.x)

- The image only contains rclone (no AWS CLI). `s3://` destinations keep working with the same `AWS_*` credentials;
  set `S3_ENDPOINT` for storage outside AWS. The image runs as user `10001`, the rclone config is read from
  `/config/rclone/rclone.conf` (was `/root/.config/rclone/rclone.conf`).
- `SRC_BUCKET` / `DST_BUCKET` are now `SOURCE` / `DESTINATION`, `BANDWITH_LIMIT` / `TRANSACTION_LIMIT` are now
  `RCLONE_BWLIMIT` / `RCLONE_TPSLIMIT` and have no defaults anymore (were `10M` / `20`). The old names still work
  with a deprecation warning and will be removed in 2.0.0.
- `BACKUP_NAME` has no default anymore.
- Backups are stored as `DESTINATION/<BACKUP_NAME>/<BACKUP_NAME>-<YYYYmmddTHHMMSSZ>.tar.gz` (was
  `DESTINATION/<BACKUP_NAME>-<YYYY-mm-dd>.tar.gz`, one per day). Old backups are restored by full path:
  `restore s3://my-backups/buckets/my-bucket-2023-02-28.tar.gz`. Retention only deletes files using the new naming.
- Restore needs an explicit `RESTORE_TARGET` (was always the source bucket) and `RESTORE_CONFIRM`, and no longer
  deletes files that are not in the backup unless `RESTORE_DELETE=true`.
- The image entrypoint is the script itself: pass `backup` / `restore` as arguments.
- Chart values: `app.cronSchedule` → `backup.schedule`, `jobAnnotations` → `podAnnotations`,
  `command`/`args` → `backup.args` / `restore.args`, `notificationSlack` → `secrets.slack_webhook_url` + `deployNotification.enabled`.
  `existingSecret` with the keys `aws_access_key_id`, `aws_secret_access_key`, `rclone` works as before.

## License

[MIT](LICENSE)
