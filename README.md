# S3-like backup/restore script

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/bucket-backup-restore)](https://artifacthub.io/packages/search?repo=bucket-backup-restore)

This project contains backup/restore script for Any S3-like buckets and restore it

---
> Prerequisites to run locally:
>
> Tools: aws, rclone
>
> Credentials: rclone config placed under ~/.config/rclone/rclone.conf with source rclone profile, AWS credentials with destination passed via AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env variables
>
>
> Backup Flow: Source S3 Storage --(rclone sync)--> /tmp/backup --(aws s3 cp)--> Destination S3 Storage
>
> Restore Flow: Source S3 Storage --(aws s3 cp)--> /tmp/restore --(rclone sync)--> Destination S3 Storage

## Script


#### Download and execute the script:

```bash
$ git clone https://github.com/abohatyrenko/bucket-backup-restore.git
$ cd bucket-backup-restore
$ chmod +x bucket_backup_restore.sh && chmod +x bucket_backup_restore.sh
$ ./bucket_backup_restore.sh
```


## Default Configuration

### Dynamic variables

```bash
SRC_BUCKET=${SRC_BUCKET:=example-storage:example}
DST_BUCKET=${DST_BUCKET:=s3://example-storage/example}
BACKUP_NAME=${BACKUP_NAME:=backup-example}
```

---
## Script is self documented, to use manually:

```shell
export AWS_PROFILE='profile_backup' # profile_backup is custom name of profile of AWS profile with S3 access placed under ~/.aws/config

to backup: ./backup_restore.sh backup
to restore: ./backup_restore.sh restore
to restore specific date: ./backup_restore.sh restore example/*bucket-name*-example-06-10-2021.tar.gz
```
---
