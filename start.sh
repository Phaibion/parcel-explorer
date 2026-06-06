#!/usr/bin/env bash
# Railway entrypoint: sync state data files onto the volume, then launch the app.
# Each state's parquet is pulled once from a public GitHub release asset. Per-file
# version markers mean adding/refreshing one state never re-downloads the others.
# Uses Python (always present) — the runtime image has no curl/wget.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
mkdir -p "$DATA_DIR"

fetch() {  # name  url  version
  local name="$1" url="$2" ver="${3:-1}"
  [ -z "$url" ] && { echo "[bootstrap] $name: no URL set, skipping"; return 0; }
  local target="$DATA_DIR/$name" marker="$DATA_DIR/.ver_$name"
  if [ -s "$target" ] && [ "$(cat "$marker" 2>/dev/null || echo none)" = "$ver" ]; then
    echo "[bootstrap] $name v$ver already on volume ($(du -h "$target" | cut -f1)) — skip"
    return 0
  fi
  echo "[bootstrap] $name: downloading v$ver…"
  python - "$url" "$target" <<'PY'
import os, sys, urllib.request
url, target = sys.argv[1], sys.argv[2]
tmp = target + ".part"
req = urllib.request.Request(url, headers={"Accept": "application/octet-stream", "User-Agent": "parcel-explorer"})
with urllib.request.urlopen(req) as r, open(tmp, "wb") as f:
    while (chunk := r.read(1 << 20)):
        f.write(chunk)
os.replace(tmp, target)
print(f"[bootstrap] {os.path.basename(target)}: downloaded {os.path.getsize(target)//1024//1024} MB")
PY
  echo "$ver" > "$marker"
}

fetch parcels_fl.parquet "${DATA_ASSET_URL:-}"    "${DATA_VERSION:-1}"
fetch parcels_tx.parquet "${DATA_ASSET_URL_TX:-}" "${DATA_VERSION_TX:-1}"

exec streamlit run app.py \
  --server.port "${PORT:-8501}" \
  --server.address 0.0.0.0 \
  --server.headless true
