#!/usr/bin/env bash
# Verify the air-gap bundle integrity on the TARGET host.
#
#   bash docs/offline/verify-bundle.sh [bundle_root]
#
# Works both inside the extracted bundle (bundle/docs/offline) and when
# pointed at the bundle root directly.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARG="${1:-}"

if [ -n "$ARG" ]; then
    CANDIDATE="$(cd "$ARG" && pwd)"
elif [ -f "$HERE/SHA256SUMS" ]; then
    CANDIDATE="$HERE"
elif [ -f "$HERE/../../SHA256SUMS" ]; then
    CANDIDATE="$(cd "$HERE/../.." && pwd)"
else
    echo "SHA256SUMS not found; pass the bundle root as argument"
    exit 1
fi

echo "verifying bundle: $CANDIDATE"
(
    cd "$CANDIDATE"
    sha256sum -c SHA256SUMS
)

echo
echo "BUNDLE VERIFIED - next: bash docs/offline/load-images.sh"
