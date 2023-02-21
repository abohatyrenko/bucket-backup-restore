FROM debian:11-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    rclone \
    curl \
    unzip
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install \
&& rm -f awscliv2.zip \
&& rm -rf /var/lib/apt/lists/*
COPY ./backup_restore.sh /opt/backup_restore.sh
RUN chmod +x /opt/backup_restore.sh
CMD [ "/opt/backup_restore.sh" ]