# bucket-backup-restore Helm chart

Runs [bucket-backup-restore](https://github.com/abohatyrenko/bucket-backup-restore#readme) as a Kubernetes CronJob, plus an optional on-demand restore job.

## Install

```sh
helm upgrade --install spaces-backup oci://ghcr.io/abohatyrenko/charts/bucket-backup-restore -f values.yaml

# Uninstall
helm uninstall spaces-backup
```

Example `values.yaml` for a DigitalOcean Spaces bucket backed up to AWS S3:

```yaml
backup:
  schedule: "0 2 * * *"
  timeZone: Europe/Kyiv
  env:
    BACKUP_KEEP_DAYS: "30"
    AGE_RECIPIENTS: age1...
    HEARTBEAT_URL: https://hc-ping.com/<uuid>

env:
  SOURCE: spaces:my-space
  DESTINATION: s3://my-backups/buckets
  AWS_REGION: eu-central-1
  BACKUP_NAME: my-space
  RCLONE_TRANSFERS: "16"

# Secret with keys AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, rclone (rclone.conf content), SLACK_WEBHOOK_URL
existingSecret: spaces-backup

workDir:
  sizeLimit: 50Gi # about 2x the bucket size
```

With `rclone` in the Secret:

```ini
[spaces]
type = s3
provider = DigitalOcean
endpoint = fra1.digitaloceanspaces.com
access_key_id = ...
secret_access_key = ...
```

Run a backup right away:

```sh
kubectl create job --from=cronjob/spaces-backup-bucket-backup-restore spaces-backup-manual-$(date +%s)
```

## Restore

Restore is disabled by default. Ideally enable it in a separate release with credentials for the target only,
so the backup release never has write access to the source bucket:

```yaml
backup:
  enabled: false
restore:
  enabled: true
  env:
    RESTORE_TARGET: spaces:my-space-restored
    RESTORE_CONFIRM: spaces:my-space-restored
env:
  DESTINATION: s3://my-backups/buckets
  AWS_REGION: eu-central-1
  BACKUP_NAME: my-space
existingSecret: spaces-restore # AWS_*, rclone, AGE_IDENTITY
```

The restore CronJob is suspended and never scheduled. Start a restore of the latest backup with:

```sh
kubectl create job --from=cronjob/<release>-bucket-backup-restore-restore restore-$(date +%s)
```

To restore a specific backup, set `restore.args: ["restore", "my-space-20261030T020000Z.tar.gz"]`.

## Values

See [values.yaml](https://github.com/abohatyrenko/bucket-backup-restore/blob/main/helm/values.yaml) for all options. The most important ones:

| Key | Default | Description |
|---|---|---|
| `backup.enabled` | `true` | Create the backup CronJob |
| `backup.schedule` / `backup.timeZone` | `0 11 * * *` / controller time zone | |
| `backup.env` / `restore.env` / `env` | `{}` | Environment variables for backup jobs / restore jobs / both |
| `restore.enabled` | `false` | Create the suspended restore CronJob |
| `existingSecret` | | Secret with keys named after the variables they set: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AGE_IDENTITY`, `SLACK_WEBHOOK_URL`, and `rclone` for the `rclone.conf` file (all optional) |
| `secrets.*` | | Values for a Secret created by the chart when `existingSecret` is empty |
| `extraEnv` | `[]` | e.g. `RCLONE_CONFIG_<REMOTE>_*` variables from other Secrets instead of an rclone.conf |
| `serviceAccount.annotations` | `{}` | e.g. `eks.amazonaws.com/role-arn` for IRSA instead of static AWS keys |
| `workDir.sizeLimit` | `10Gi` | Scratch space; must fit the bucket and its archive |
| `workDir.volume` | emptyDir | Custom volume for large buckets (e.g. an ephemeral PVC) |
| `deployNotification.enabled` | `false` | Slack message on install/upgrade/rollback |

Only restore jobs receive the age identity.
