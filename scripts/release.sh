#!/usr/bin/env bash
#
# Sets the version of the next release in helm/Chart.yaml: version, appVersion
# and the image in artifacthub.io/images (the chart and the image share one version).
#
# Usage: scripts/release.sh X.Y.Z

set -Eeuo pipefail

cd "$(dirname "$0")/.."

readonly CHART=helm/Chart.yaml

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "usage: scripts/release.sh X.Y.Z" >&2
  exit 64
fi

# -i.bak: the only form of in-place editing both GNU and BSD sed understand
sed -i.bak -E \
  -e "s/^version: .*/version: ${version}/" \
  -e "s/^appVersion: .*/appVersion: \"${version}\"/" \
  -e "s|^( *image: abohatyrenko/bucket-backup-restore:).*|\\1${version}|" \
  "$CHART"
rm "${CHART}.bak"

scripts/check-version.sh
echo "Next: describe the release in artifacthub.io/changes of ${CHART}, see Release in README.md"
