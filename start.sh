#!/usr/bin/env bash
# Railway entrypoint: populate the volume on first boot, then launch the app.
# The data file is too large for the image, so it's pulled once from a public
# GitHub release asset onto the persistent volume. Subsequent boots skip it.
# Uses Python (always present in this image) — the runtime has no curl/wget.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
TARGET="$DATA_DIR/parcels_fl.parquet"
mkdir -p "$DATA_DIR"

if [ ! -s "$TARGET" ]; then
  echo "[bootstrap] $TARGET missing — downloading from release asset…"
  python - "$DATA_ASSET_URL" "$TARGET" <<'PY'
import os, sys, urllib.request
url, target = sys.argv[1], sys.argv[2]
tmp = target + ".part"          # atomic: never leave a partial file that looks complete
req = urllib.request.Request(url, headers={
    "Accept": "application/octet-stream", "User-Agent": "parcel-explorer"})
with urllib.request.urlopen(req) as r, open(tmp, "wb") as f:
    while (chunk := r.read(1 << 20)):
        f.write(chunk)
os.replace(tmp, target)
print(f"[bootstrap] downloaded {os.path.getsize(target) // 1024 // 1024} MB")
PY
else
  echo "[bootstrap] data already on volume ($(du -h "$TARGET" | cut -f1)) — skipping download"
fi

exec streamlit run app.py \
  --server.port "${PORT:-8501}" \
  --server.address 0.0.0.0 \
  --server.headless true
