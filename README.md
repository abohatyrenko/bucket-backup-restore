# S3-like backup/restore script

This project contains backup/restore script for Any S3-like buckets (DO) and restore it

---
> Backup/Restore script for bucket (*bucket-name*-static) placed on Digital Ocean Space
> Designed to backup into AWS S3 bucket (backup storage)

>
> Prerequisites:
>
> Tools: aws, rclone
>
> Credentials: rclone config placed under ~/.config/rclone/rclone.conf with DO space profile, AWS credentials to backup/restore bucket
>
>
> Backup Flow: DO Space --(rclone sync)--> /tmp/backup --(aws s3 cp)--> AWS S3 bucket
>
> Resotre Flow: AWS S3 --(aws s3 cp)--> /tmp/restore --(rclone sync)--> ANY S3 bucket
>

## Script


#### Download and execute the script:

```bash
$ git clone https://github.com/abohatyrenko/bucket-backup-restore.git
$ cd bucket-backup-restore
$ chmod +x bucket_backup_restore.sh && chmod +x bucket_backup_restore.sh
$ ./bucket_backup_restore.sh
```
[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/bucket-backup-restore)](https://artifacthub.io/packages/search?repo=bucket-backup-restore)

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
