FROM alpine:latest

ARG RCLONE_VERSION=current
ARG ARCH=amd64

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip

RUN URL=http://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-${ARCH}.zip ; \
  URL=${URL/\/current/} ; \
  cd /tmp \
  && wget -q $URL \
  && unzip /tmp/rclone-${RCLONE_VERSION}-linux-${ARCH}.zip \
  && mv /tmp/rclone-*-linux-${ARCH}/rclone /usr/bin \
  && rm -r /tmp/rclone*

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.8.7.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install \
&& rm -f awscliv2.zip \
&& rm -rf /var/lib/apt/lists/*

COPY ./bucket_backup_restore.sh /opt/bucket_backup_restore.sh
CMD [ "/opt/bucket_backup_restore.sh" ]
