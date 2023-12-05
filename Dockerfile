FROM debian:11-slim

ARG RCLONE_VERSION=v1.65.0
ARG AWS_VERSION=2.8.7
ARG ARCH=amd64

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    unzip

RUN URL="https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-${ARCH}.zip" ; \
  cd /tmp \
  && wget -q $URL \
  && unzip /tmp/rclone-${RCLONE_VERSION}-linux-${ARCH}.zip \
  && mv /tmp/rclone-*-linux-${ARCH}/rclone /usr/bin \
  && rm -r /tmp/rclone*

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_VERSION}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install \
&& rm -f awscliv2.zip \
&& rm -rf /var/lib/apt/lists/*

COPY ./bucket_backup_restore.sh /opt/bucket_backup_restore.sh
CMD [ "/opt/bucket_backup_restore.sh" ]
