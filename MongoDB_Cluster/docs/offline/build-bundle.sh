#!/usr/bin/env bash
# Build the air-gap bundle on an INTERNET-CONNECTED Docker host.
#
#   bash docs/offline/build-bundle.sh [output_dir]
#
# Produces:
#   <output_dir>/images/*.tar     docker-save'd images (mongo:7.0 + both lab images)
#   <output_dir>/docs/lab/...     the complete lab
#   <output_dir>/docs/offline/... verify + load scripts for the target host
#   <output_dir>/HANDS_ON.md      the command workbook
#   <output_dir>/SHA256SUMS       integrity manifest
#   <output_dir>.tar.gz           single file to copy to the air-gapped host
#
# Optional:
#   PLATFORM=linux/amd64   target architecture (default linux/amd64)
#   WITH_BASES=1           also save python + debian base images so the lab
#                          can be REBUILT inside the air-gapped network

set -euo pipefail

OFFLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_DIR="$(cd "$OFFLINE_DIR/.." && pwd)"
LAB_DIR="$DOCS_DIR/lab"
PROJECT_DIR="$(cd "$DOCS_DIR/.." && pwd)"

OUT_DIR="${1:-$PROJECT_DIR/mongodb-ha-lab-bundle}"
PLATFORM="${PLATFORM:-linux/amd64}"

RUNTIME_IMAGES=(
    mongo:7.0
    mongodb-ha-lab-health:local
    mongodb-ha-lab-proxy:local
)
BASE_IMAGES=(
    python:3.12-slim-bookworm
    debian:bookworm-slim
)

safe_name() { echo "$1" | tr '/:' '__'; }

echo "=== 0. sanity ==="
test -f "$LAB_DIR/compose.yaml" || { echo "compose.yaml not found in $LAB_DIR"; exit 1; }
docker info >/dev/null || { echo "docker daemon unreachable"; exit 1; }

echo
echo "=== 1. build the lab images for $PLATFORM ==="
docker compose -p mongodb-ha-lab-build -f "$LAB_DIR/compose.yaml" build

echo
echo "=== 2. pull the client/base image ==="
docker pull --platform "$PLATFORM" mongo:7.0
if [ "${WITH_BASES:-0}" = "1" ]; then
    docker pull --platform "$PLATFORM" python:3.12-slim-bookworm
    docker pull --platform "$PLATFORM" debian:bookworm-slim
fi

echo
echo "=== 3. save images to $OUT_DIR/images ==="
mkdir -p "$OUT_DIR/images"
for img in "${RUNTIME_IMAGES[@]}"; do
    out="$OUT_DIR/images/$(safe_name "$img").tar"
    echo "  saving $img -> $out"
    docker save -o "$out" "$img"
done
if [ "${WITH_BASES:-0}" = "1" ]; then
    for img in "${BASE_IMAGES[@]}"; do
        out="$OUT_DIR/images/$(safe_name "$img").tar"
        echo "  saving $img -> $out"
        docker save -o "$out" "$img"
    done
fi

echo
echo "=== 4. copy lab + docs + workbook ==="
rm -rf "$OUT_DIR/docs" "$OUT_DIR/HANDS_ON.md"
mkdir -p "$OUT_DIR/docs"
cp -a "$LAB_DIR" "$OUT_DIR/docs/lab"
cp -a "$OFFLINE_DIR" "$OUT_DIR/docs/offline"
cp "$DOCS_DIR/MONGODB_HA_LAB_GUIDE.md" "$OUT_DIR/docs/"
test -f "$PROJECT_DIR/HANDS_ON.md" && cp -a "$PROJECT_DIR/HANDS_ON.md" "$OUT_DIR/"

echo
echo "=== 5. checksums ==="
(
    cd "$OUT_DIR"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
    echo "  $(wc -l < SHA256SUMS) files hashed"
)

echo
echo "=== 6. final archive ==="
tar -C "$(dirname "$OUT_DIR")" -czf "${OUT_DIR}.tar.gz" "$(basename "$OUT_DIR")"
sha256sum "${OUT_DIR}.tar.gz" | tee "${OUT_DIR}.tar.gz.sha256"

echo
echo "DONE."
echo "  copy to the air-gapped host: ${OUT_DIR}.tar.gz"
echo "  on the target host:          bash docs/offline/verify-bundle.sh"
echo "                               bash docs/offline/load-images.sh"
echo "                               docker compose up -d --no-build"
