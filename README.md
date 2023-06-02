# S3-like backup/restore script

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/bucket-backup-restore)](https://artifacthub.io/packages/search?repo=bucket-backup-restore)

This project contains backup/restore script for Any S3-like buckets (DO) and restore it

---
> Backup/Restore script for S3 compatible storage
> By default designed to backup into AWS S3 bucket (destination storage)
> By default designed to restore from any S3 bucket (source storage)
>
> Prerequisites to run locally:
>
> Tools: aws, rclone
>
> Credentials: rclone config placed under ~/.config/rclone/rclone.conf with source rclone profile, AWS credentials with destination passed via AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env variables
>
>
> Backup Flow: Source S3 Storage --(rclone sync)--> /tmp/backup --(aws s3 cp)--> AWS S3 Destination Storage
>
> Restore Flow: AWS S3 Storage --(aws s3 cp)--> /tmp/backup --(rclone sync)--> Source S3 Storage
>

## Script

#### Download and execute the script:

```bash
$ git clone https://github.com/abohatyrenko/bucket-backup-restore.git
$ cd bucket-backup-restore
$ chmod +x bucket_backup_restore.sh && chmod +x bucket_backup_restore.sh
$ ./bucket_backup_restore.sh
```

## Default Configuration

### Edit preferences

```bash
AWS_BUCKET=${AWS_BUCKET:=s3://*-backup/static}
DO_BUCKET=${DO_BUCKET:=spaces-*-fra1:*-static}
RESTORE_BUCKET=${RESTORE_BUCKET:=spaces-*-fra1:*-static}
BACKUP_NAME=${BACKUP_NAME:=*-static}
```

---
## Script is self documented, to use manually:

```shell
export AWS_PROFILE='profile_backup' # profile_backup is custom name of profile of AWS profile with S3 access placed under ~/.aws/config

to backup: ./backup_restore.sh backup
to restore: ./backup_restore.sh restore # by default will be restored to the source bucket (spaces-*space-name*-fra1:*bucket-name*-static)
to restore specific date: ./backup_restore.sh restore static/*bucket-name*-static-06-10-2021.tar.gz
```
---
