# Parcel Explorer

A multi-state, filterable interface over public property-tax rolls. Pick a state,
filter by use category / size / building count / year / value / owner / location (and
any raw native column), watch the count update live, and download the matching list
as CSV — owner names and site addresses included.

Built for HVAC / commercial lead-gen: the default filter is the non-residential,
conditioned-building set most likely to run HVAC.

## Stack
- **DuckDB** queries normalized Parquet directly (no DB server).
- **Streamlit** front-end.
- Designed for **Railway** (data on a persistent volume).

## Architecture: canonical schema + per-state adapters
Every state's raw roll is different, so the app never reads raw files directly.
Each state is normalized into one **canonical schema** (see `config.py`):

| canonical | meaning |
|---|---|
| state, county, parcel_id | identity |
| owner_name / owner_addr / city / state / zip | mailing |
| site_addr / site_city / site_zip | building location |
| native_use_code | the state's own code, untouched |
| **use_category** | normalized: commercial / industrial / institutional / government / residential / agricultural / vacant / utility_misc |
| bldg_sqft, num_buildings, year_built, land_sqft, market_value | sizing / value |

…plus every native column passed through, so nothing is lost.

**Adding a state** (e.g. Texas):
1. Copy `build_fl.sql`, repoint inputs, rewrite the column map + use-code `CASE` crosswalk.
2. Produce `data/parcels_<st>.parquet` with the same canonical columns.
3. Add a `STATES["TX"]` block in `config.py` with its `available` flags (e.g. set
   `bldg_sqft: False` if that state's source omits building area — the app then greys
   out the size filter and says so). No app code changes.

## Data: Florida (adapter #1)
- **Source:** Florida Dept. of Revenue (DOR) NAL roll, 2025 Final, all 67 counties,
  from <https://floridarevenue.com/property/dataportal>.
- **Rows:** ~10,998,029 parcels. **Columns:** 180 (15 canonical + 165 native).
- The `bldg_sqft` field is DOR `TOT_LVG_AREA` = conditioned/heated area, the HVAC proxy.

## Run locally
```bash
pip install -r requirements.txt
# expects data/parcels_fl.parquet present
streamlit run app.py
```

## Deploy (Railway)
Data is too large for git, so it lives on a **persistent volume**, not in the repo.
1. Push this repo (code only — `data/` is gitignored).
2. In Railway: create the service from the repo, add a **Volume** mounted at `/data`.
3. Set env var `DATA_DIR=/data`.
4. Upload the parquet to the volume once (via Railway CLI / shell):
   `parcels_fl.parquet` -> `/data/parcels_fl.parquet`.
5. Start command (Procfile): `streamlit run app.py --server.port $PORT --server.address 0.0.0.0`.

To refresh data (new roll year, or add a state): rebuild the parquet locally with
`build_fl.sql`, upload to the volume, restart. No redeploy needed.
