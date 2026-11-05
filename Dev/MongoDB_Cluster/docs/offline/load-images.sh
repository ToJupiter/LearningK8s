#!/usr/bin/env bash
# Load the saved Docker images on the air-gapped TARGET host.
#
#   bash docs/offline/load-images.sh [images_dir]
#
# Afterwards:
#   cd <extracted-bundle>/docs/lab
#   bash scripts/preflight.sh
#   docker compose up -d --no-build      # NO build, NO pull: everything is local

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARG="${1:-}"

if [ -n "$ARG" ]; then
    IMG_DIR="$(cd "$ARG" && pwd)"
elif [ -d "$HERE/images" ]; then
    IMG_DIR="$HERE/images"
elif [ -d "$HERE/../../images" ]; then
    IMG_DIR="$(cd "$HERE/../.." && pwd)/images"
else
    echo "images directory not found; pass it as argument"
    exit 1
fi

echo "loading images from $IMG_DIR"
shopt -s nullglob
loaded=0
for tarfile in "$IMG_DIR"/*.tar; do
    echo "  docker load -i $tarfile"
    docker load -i "$tarfile"
    loaded=$((loaded + 1))
done
shopt -u nullglob

if [ "$loaded" -eq 0 ]; then
    echo "no .tar files found in $IMG_DIR"
    exit 1
fi

echo
echo "expected images now present:"
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' \
    | grep -E 'mongo:7.0|mongodb-ha-lab-(health|proxy)' \
    || { echo "MISSING IMAGES - do not proceed"; exit 1; }

echo
echo "IMAGES LOADED - next: cd docs/lab && bash scripts/preflight.sh"
