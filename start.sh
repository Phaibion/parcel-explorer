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
  if python - "$url" "$target" <<'PY'
import os, sys, time, urllib.request
url, target = sys.argv[1], sys.argv[2]
tmp = target + ".part"
req = urllib.request.Request(url, headers={"Accept": "application/octet-stream", "User-Agent": "parcel-explorer"})
for attempt in range(4):
    try:
        with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
            while (chunk := r.read(1 << 20)):
                f.write(chunk)
        os.replace(tmp, target)
        print(f"[bootstrap] {os.path.basename(target)}: downloaded {os.path.getsize(target)//1024//1024} MB")
        sys.exit(0)
    except Exception as e:
        print(f"[bootstrap] attempt {attempt+1} failed: {e}", file=sys.stderr)
        time.sleep(5 * (attempt + 1))
sys.exit(1)
PY
  then
    echo "$ver" > "$marker"
  elif [ -s "$target" ]; then
    echo "[bootstrap] $name: download failed — keeping existing volume copy, launching anyway"
  else
    echo "[bootstrap] $name: download failed and no existing copy — continuing without it"
  fi
}

fetch parcels_fl.parquet "${DATA_ASSET_URL:-}"    "${DATA_VERSION:-1}"
fetch parcels_tx.parquet "${DATA_ASSET_URL_TX:-}" "${DATA_VERSION_TX:-1}"
fetch parcels_ca.parquet "${DATA_ASSET_URL_CA:-}" "${DATA_VERSION_CA:-1}"

exec streamlit run app.py \
  --server.port "${PORT:-8501}" \
  --server.address 0.0.0.0 \
  --server.headless true
