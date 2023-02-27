This is a backup/restore script for S3-like bucket

### Usage:
```sh
helm repo add bucket-backup-restore https://abohatyrenko.github.io/bucket-backup-restore/helm
helm repo update

helm upgrade --install bucket-backup-restore bucket-backup-restore/bucket-backup-restore

# Uninstall
helm uninstall bucket-backup-restore
```