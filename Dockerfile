FROM alpine:3.24

# rclone comes from Alpine: its package is rebuilt when Go gets security fixes, which the
# official rclone image is not between rclone releases (vulnerability scanners flag those).
# hadolint ignore=DL3018
RUN apk add --no-cache \
      age \
      bash \
      ca-certificates \
      coreutils \
      curl \
      findutils \
      pigz \
      rclone \
      tar \
 && addgroup -S -g 10001 backup \
 && adduser -S -D -H -u 10001 -G backup -h /tmp backup

COPY --chmod=0755 bucket_backup_restore.sh /usr/local/bin/bucket_backup_restore.sh
# Backward compatible path used by older chart versions / docs
RUN ln -s /usr/local/bin/bucket_backup_restore.sh /opt/bucket_backup_restore.sh

ENV HOME=/tmp \
    WORK_DIR=/tmp/bucket-backup-restore \
    RCLONE_CONFIG=/config/rclone/rclone.conf

USER 10001:10001
WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/bucket_backup_restore.sh"]
CMD ["backup"]
