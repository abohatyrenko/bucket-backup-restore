#!/usr/bin/env bash
#
# The chart and the image share one version. Checks that helm/Chart.yaml
# version, appVersion and the image in artifacthub.io/images are equal and,
# with a release tag, that the tag matches them.
#
# Usage: scripts/check-version.sh [vX.Y.Z]

set -Eeuo pipefail

cd "$(dirname "$0")/.."

readonly CHART=helm/Chart.yaml

field() { sed -n "s/^$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$CHART"; }

version="$(field version)"
app_version="$(field appVersion)"
image_tag="$(sed -n 's|^ *image: abohatyrenko/bucket-backup-restore:\(.*\)$|\1|p' "$CHART")"

errors=()
[[ "$app_version" == "$version" ]] || errors+=("appVersion (${app_version}) differs from version (${version})")
[[ "$image_tag" == "$version" ]] || errors+=("artifacthub.io/images tag (${image_tag}) differs from version (${version})")
if [[ -n "${1:-}" ]]; then
  [[ "${1#v}" == "$version" ]] || errors+=("tag $1 does not match chart version ${version}")
fi

if ((${#errors[@]})); then
  printf 'version check failed: %s\n' "${errors[@]}" >&2
  exit 1
fi
echo "version ${version}"
