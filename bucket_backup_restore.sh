#!/bin/bash

# If in the future you will need to download from Yandex S3, take a look at PR below
# It's not possible to use endpoint URL as env variable for AWS CLI at the moment (16.06.22): https://github.com/aws/aws-cli/issues/4454
# As a workaround for Yandex you can provide --endpoint-url=*yandex-url* argument to AWS CLI

set -e

# dynamic vars

AWS_BUCKET=${AWS_BUCKET:=s3://*-backup/static}
DO_BUCKET=${DO_BUCKET:=spaces-*-fra1:*-static}
RESTORE_BUCKET=${RESTORE_BUCKET:=spaces-*-fra1:*-static}
BACKUP_NAME=${BACKUP_NAME:=*-static}

if [[ -z "$AWS_ACCESS_KEY_ID" ]]
then
  echo "`date -R` : ENV var missing: AWS_ACCESS_KEY_ID"
  exit 1
fi

if [[ -z "$AWS_SECRET_ACCESS_KEY" ]]
then
  echo "`date -R` : ENV var missing: AWS_SECRET_ACCESS_KEY"
  exit 1
fi

if [[ -z "$AWS_DEFAULT_REGION" ]]
then
  echo "`date -R` : ENV var missing: AWS_DEFAULT_REGION"
  exit 1
fi

# config path defined in helm chart cronjob template
if [[ ! -f /root/.config/rclone/rclone.conf ]]
then
    echo "`date -R` : Rclone config missing: /root/.config/rclone/rclone.conf"
    exit 1
fi

# # static vars

BACKUP_DIR=/tmp/backup
RESTORE_DIR=/tmp/restore
ARTIFACT_NAME="${BACKUP_NAME}-$(date +%Y-%m-%d).tar.gz"

# By default with restore argument the latest backup will be uploaded from S3 bucket.
# As a second argument you can pass specific backup file name to restore. Example (if BACKUP_NAME=*-static) then 2nd argument will be "*-static-2022-04-21.tar.gz"
LATEST_BACKUP_FILE=`aws s3 ls "$AWS_BUCKET/" | sort | tail -n 1 | awk '{print $4}'`


case $1 in

  backup)
    echo "`date -R` : Backing up $DO_BUCKET to $BACKUP_DIR"
    mkdir -p /tmp/backup
    rclone sync  --bwlimit 10M --tpslimit 20 $DO_BUCKET "$BACKUP_DIR/$BACKUP_NAME"

    if [ -d "$BACKUP_DIR/$BACKUP_NAME" ]; then
        echo "`date -R` : $BACKUP_DIR/$BACKUP_NAME exists, making archive"
        cd $BACKUP_DIR
        tar -czf "$ARTIFACT_NAME" "$BACKUP_NAME"
    else
        echo "$BACKUP_DIR does not exist, exiting"
        exit 1
    fi

    echo "`date -R` : Uploading $BACKUP_DIR/$ARTIFACT_NAME to $AWS_BUCKET"
    aws s3 cp --no-progress $BACKUP_DIR/$ARTIFACT_NAME $AWS_BUCKET/$ARTIFACT_NAME
    echo "`date -R` : Finished: Uploaded to $AWS_BUCKET"

    ## Check if backup file size is not 0 Bytes

    echo "`date -R` : checking bucket backup size"

    SIZE=$(aws s3 ls $AWS_BUCKET/$ARTIFACT_NAME --recursive | sort | tail -n 1 | awk '{print $3}');

    if [ "$SIZE" -gt "1" ];
      then
        echo "`date -R` : size is $SIZE its ok"
      else
        echo "`date -R` : size is $SIZE its NOT ok"
        exit 1
    fi

    echo "`date -R` : Finished: Uploaded $ARTIFACT_NAME to $AWS_BUCKET"

  ;;

  restore)

    #Check if second argument provided

    if [ -z "$2" ]
    then
      echo "`date -R` : No backup file name provided as 2nd arg, please follow the naming - "$BACKUP_NAME-$(date +%Y-%m-%d).tar.gz" if needed"
      echo "`date -R` : Using Latest backup: $LATEST_BACKUP_FILE"
    fi

    echo "`date -R` : Preparing directory to restore - $RESTORE_DIR"
    mkdir -p $RESTORE_DIR
    cd $RESTORE_DIR

    echo "`date -R` : Downloading backup - ${2:-$LATEST_BACKUP_FILE}"
    aws s3 cp --no-progress $AWS_BUCKET/${2:-$LATEST_BACKUP_FILE} .
    tar -xf ${2:-$LATEST_BACKUP_FILE}

    echo "`date -R` : Syncing with $RESTORE_BUCKET"
    rclone sync --bwlimit 10M --tpslimit 20 $BACKUP_NAME $RESTORE_BUCKET
    echo "`date -R` : Finished: Succesfully restored to $RESTORE_BUCKET"

  ;;

  *)
    echo "Possible options backup / restore"
    exit 1
  ;;

esac
