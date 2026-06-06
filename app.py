"""
Parcel Explorer — multi-state, filterable property-roll interface.
Live filtered count + downloadable CSV, backed by DuckDB over normalized parquet.

Run locally:  streamlit run app.py
"""
import os
import duckdb
import pandas as pd
import streamlit as st

from config import STATES, USE_CATEGORIES, HVAC_DEFAULT_CATEGORIES

BASE = os.path.dirname(os.path.abspath(__file__))
# On Railway the parquet lives on a persistent volume; DATA_DIR points at the mount.
# Locally it defaults to ./data alongside the app.
DATA_DIR = os.environ.get("DATA_DIR", os.path.join(BASE, "data"))
PREVIEW_ROWS = 1000
DOWNLOAD_WARN_ROWS = 250_000  # warn before building a CSV bigger than this


def data_path(rel):
    """Resolve a state's data file against DATA_DIR (volume on Railway, ./data locally)."""
    return os.path.join(DATA_DIR, os.path.basename(rel))

st.set_page_config(page_title="Parcel Explorer", layout="wide")


@st.cache_resource
def get_con():
    return duckdb.connect()


@st.cache_data(show_spinner=False)
def distinct_values(parquet_path: str, column: str):
    con = get_con()
    rows = con.execute(
        f"SELECT DISTINCT {column} v FROM read_parquet(?) "
        f"WHERE {column} IS NOT NULL AND TRIM(CAST({column} AS VARCHAR)) <> '' ORDER BY 1",
        [parquet_path],
    ).fetchall()
    return [r[0] for r in rows]


def build_where(f):
    """Return (sql_where, params) from the filter dict."""
    clauses, params = [], []

    if f["categories"]:
        ph = ",".join(["?"] * len(f["categories"]))
        clauses.append(f"use_category IN ({ph})")
        params += f["categories"]

    if f["counties"]:
        ph = ",".join(["?"] * len(f["counties"]))
        clauses.append(f"county IN ({ph})")
        params += f["counties"]

    if f["native_codes"]:
        ph = ",".join(["?"] * len(f["native_codes"]))
        clauses.append(f"native_use_code IN ({ph})")
        params += f["native_codes"]

    if f["sqft_only_recorded"]:
        clauses.append("bldg_sqft IS NOT NULL AND bldg_sqft > 0")
    if f["sqft_min"] is not None:
        clauses.append("bldg_sqft >= ?")
        params.append(f["sqft_min"])
    if f["sqft_max"] is not None:
        clauses.append("bldg_sqft <= ?")
        params.append(f["sqft_max"])

    if f["single_building"]:
        clauses.append("num_buildings = 1")
    elif f["nb_min"] is not None:
        clauses.append("num_buildings >= ?")
        params.append(f["nb_min"])

    if f["year_min"] is not None:
        clauses.append("year_built >= ?")
        params.append(f["year_min"])
    if f["year_max"] is not None:
        clauses.append("year_built <= ?")
        params.append(f["year_max"])

    if f["value_min"] is not None:
        clauses.append("market_value >= ?")
        params.append(f["value_min"])

    occ = f.get("occupancy")
    if occ == "Owner-occupied — strict match":
        clauses.append("owner_occupied = TRUE")
    elif occ == "Owner-occupied — broad (local FL owners)":  # max recall: keeps every possible owner-occupant
        clauses.append("owner_occupancy IN ('owner_occupied','fl_owner')")
    elif occ == "Exclude out-of-state owners":
        clauses.append("owner_occupancy <> 'out_of_state'")
    elif occ == "Out-of-state owners only":
        clauses.append("owner_occupancy = 'out_of_state'")

    if f.get("raw_where"):
        clauses.append(f"({f['raw_where']})")  # single-user power filter on any native column

    if f["owner_like"]:
        clauses.append("UPPER(owner_name) LIKE ?")
        params.append(f"%{f['owner_like'].upper()}%")
    if f["city_like"]:
        clauses.append("UPPER(site_city) LIKE ?")
        params.append(f"%{f['city_like'].upper()}%")
    if f["zip_like"]:
        clauses.append("CAST(site_zip AS VARCHAR) LIKE ?")
        params.append(f"{f['zip_like']}%")

    where = " AND ".join(clauses) if clauses else "TRUE"
    return where, params


def run_scalar(parquet_path, where, params, expr="COUNT(*)"):
    con = get_con()
    return con.execute(
        f"SELECT {expr} FROM read_parquet(?) WHERE {where}", [parquet_path] + params
    ).fetchone()[0]


def run_df(parquet_path, where, params, limit=None):
    con = get_con()
    sql = f"SELECT * FROM read_parquet(?) WHERE {where} ORDER BY market_value DESC NULLS LAST"
    if limit:
        sql += f" LIMIT {limit}"
    return con.execute(sql, [parquet_path] + params).df()


# ----------------------------------------------------------------------------- UI
st.title("🏢 Parcel Explorer")

# --- state selector ---
state_keys = list(STATES.keys())
sk = st.sidebar.selectbox(
    "State", state_keys, format_func=lambda k: STATES[k]["label"]
)
state = STATES[sk]
parquet_path = data_path(state["data"])
avail = state["available"]

if not os.path.exists(parquet_path):
    st.error(f"Data file missing for {state['label']}: {state['data']}")
    st.stop()

st.sidebar.caption(f"**{state['vintage']}**  \n{state['source']}")

st.sidebar.header("Filters")

# --- use category ---
categories = st.sidebar.multiselect(
    "Use category", USE_CATEGORIES, default=HVAC_DEFAULT_CATEGORIES,
    help="Normalized across states. Default = the HVAC-relevant non-residential set.",
)

# --- county ---
counties = st.sidebar.multiselect(
    "County", distinct_values(parquet_path, "county"),
    help="Leave empty for all counties.",
)

# --- conditioned area / building filters ---
st.sidebar.subheader("Building")
single_building = st.sidebar.checkbox(
    "Single-building parcels only (= 1 building)", value=False,
    disabled=not avail["num_buildings"],
)
nb_min = None
sqft_only_recorded = st.sidebar.checkbox(
    "Only buildings with recorded conditioned area (HVAC signal)",
    value=True, disabled=not avail["bldg_sqft"],
)
c1, c2 = st.sidebar.columns(2)
sqft_min = c1.number_input("Min sq ft", min_value=0, value=0, step=1000,
                           disabled=not avail["bldg_sqft"])
sqft_max = c2.number_input("Max sq ft", min_value=0, value=0, step=1000,
                           help="0 = no upper limit", disabled=not avail["bldg_sqft"])

# --- year / value ---
st.sidebar.subheader("Age & value")
y1, y2 = st.sidebar.columns(2)
year_min = y1.number_input("Built after", min_value=0, value=0, step=1,
                           disabled=not avail["year_built"])
year_max = y2.number_input("Built before", min_value=0, value=0, step=1,
                           help="0 = no limit", disabled=not avail["year_built"])
value_min = st.sidebar.number_input("Min market value ($)", min_value=0, value=0,
                                     step=50000, disabled=not avail["market_value"])

# --- owner occupancy ---
st.sidebar.subheader("Owner")
occupancy = st.sidebar.selectbox(
    "Owner occupancy",
    ["Any",
     "Owner-occupied — strict match",
     "Owner-occupied — broad (local FL owners)",
     "Exclude out-of-state owners",
     "Out-of-state owners only"],
    help="STRICT = owner's mailing address matches the building (high precision, misses "
         "owners who mail elsewhere). BROAD = strict + any in-state owner — max recall, keeps "
         "every possible owner-occupant (some local landlords included). Out-of-state owners "
         "can't be occupying a FL building, so excluding them loses no real owner-occupants.",
    disabled=not avail.get("owner_occupancy", False),
)

# --- text search ---
st.sidebar.subheader("Search")
owner_like = st.sidebar.text_input("Owner name contains")
city_like = st.sidebar.text_input("Site city contains")
zip_like = st.sidebar.text_input("Site ZIP starts with")

# --- native code power filter (single-state deep dive) ---
native_codes = []
with st.sidebar.expander(f"Advanced: {state['native_code_name']}"):
    code_opts = distinct_values(parquet_path, "native_use_code")
    labels = state.get("native_labels", {})
    native_codes = st.multiselect(
        "Native codes", code_opts,
        format_func=lambda c: f"{c} — {labels.get(str(c), '')}".strip(" —"),
    )
    st.caption("Raw filter — any native column (SQL `WHERE` fragment)")
    raw_where = st.text_input(
        "e.g.  EFF_YR_BLT > 2000 AND SALE_PRC1 > 500000", value="",
        label_visibility="collapsed",
    )
    if st.button("Show all 180 columns"):
        cols = get_con().execute(
            "SELECT column_name FROM (DESCRIBE SELECT * FROM read_parquet(?))",
            [parquet_path]).df()["column_name"].tolist()
        st.code(", ".join(cols))

f = {
    "categories": categories,
    "counties": counties,
    "native_codes": native_codes,
    "sqft_only_recorded": sqft_only_recorded and avail["bldg_sqft"],
    "sqft_min": sqft_min if (avail["bldg_sqft"] and sqft_min > 0) else None,
    "sqft_max": sqft_max if (avail["bldg_sqft"] and sqft_max > 0) else None,
    "single_building": single_building and avail["num_buildings"],
    "nb_min": nb_min,
    "year_min": year_min if (avail["year_built"] and year_min > 0) else None,
    "year_max": year_max if (avail["year_built"] and year_max > 0) else None,
    "value_min": value_min if (avail["market_value"] and value_min > 0) else None,
    "owner_like": owner_like.strip(),
    "city_like": city_like.strip(),
    "zip_like": zip_like.strip(),
    "occupancy": occupancy if avail.get("owner_occupancy", False) else "Any",
    "raw_where": raw_where.strip(),
}
try:
    where, params = build_where(f)
    count = run_scalar(data_path(state["data"]), where, params)
except Exception as e:
    st.error(f"Filter error (check the raw SQL fragment): {e}")
    st.stop()

# ----------------------------------------------------------------------------- results
total = run_scalar(parquet_path, "TRUE", [])

m1, m2, m3 = st.columns(3)
m1.metric("Matching parcels", f"{count:,}")
m2.metric("Buildings (sum)", f"{run_scalar(parquet_path, where, params, 'COALESCE(SUM(num_buildings),0)'):,}"
          if avail["num_buildings"] else "—")
m3.metric("Share of state roll", f"{(count/total*100):.2f}%" if total else "—")

if count == 0:
    st.info("No parcels match the current filters. Loosen them on the left.")
    st.stop()

# breakdown to help draw conclusions
left, right = st.columns(2)
with left:
    st.caption("By use category")
    st.bar_chart(
        run_df(parquet_path, where, params).groupby("use_category").size()
        if count <= 50000 else
        get_con().execute(
            f"SELECT use_category, COUNT(*) n FROM read_parquet(?) WHERE {where} GROUP BY 1",
            [parquet_path] + params).df().set_index("use_category")["n"]
    )
with right:
    st.caption("Top 15 counties")
    topc = get_con().execute(
        f"SELECT county, COUNT(*) n FROM read_parquet(?) WHERE {where} "
        f"GROUP BY 1 ORDER BY n DESC LIMIT 15", [parquet_path] + params).df()
    st.bar_chart(topc.set_index("county")["n"])

# preview + download
st.subheader(f"Preview (first {min(PREVIEW_ROWS, count):,} of {count:,})")
preview = run_df(parquet_path, where, params, limit=PREVIEW_ROWS)
st.dataframe(preview, width="stretch", hide_index=True)

st.subheader("Download")
if count > DOWNLOAD_WARN_ROWS:
    st.warning(f"{count:,} rows is a large export. It may take a moment to build.")
if st.button(f"Build CSV of all {count:,} matches"):
    with st.spinner("Building CSV…"):
        full = run_df(parquet_path, where, params)
        csv = full.to_csv(index=False).encode("utf-8")
    st.download_button(
        "⬇️ Download CSV", csv,
        file_name=f"parcels_{sk.lower()}_{count}.csv", mime="text/csv",
    )
