#!/usr/bin/env bash
# Railway entrypoint: populate the volume on first boot, then launch the app.
# The data file is too large for the image, so it's pulled once from a private
# GitHub release asset onto the persistent volume. Subsequent boots skip the download.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
TARGET="$DATA_DIR/parcels_fl.parquet"
mkdir -p "$DATA_DIR"

if [ ! -s "$TARGET" ]; then
  echo "[bootstrap] $TARGET missing — downloading from release asset…"
  curl -fSL --retry 3 --retry-delay 2 \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/octet-stream" \
    "${DATA_ASSET_URL}" -o "$TARGET"
  echo "[bootstrap] downloaded $(du -h "$TARGET" | cut -f1)"
else
  echo "[bootstrap] data already on volume ($(du -h "$TARGET" | cut -f1)) — skipping download"
fi

exec streamlit run app.py \
  --server.port "${PORT:-8501}" \
  --server.address 0.0.0.0 \
  --server.headless true
