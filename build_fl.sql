-- Reproducible build of the normalized Florida parquet (adapter #1).
-- Input:  raw DOR NAL CSVs (one per county) from the FL Dept. of Revenue data portal.
-- Output: data/parcels_fl.parquet  (canonical filter columns + all 165 native DOR columns)
--
-- Source files (2025 Final roll), per county, downloaded from:
--   https://floridarevenue.com/property/dataportal  ->  Tax Roll Data Files / NAL / 2025F
--   one ZIP per county, e.g. "Dade 23 Final NAL 2025.zip" -> NAL23F202501.csv
--
-- Usage:
--   duckdb < build_fl.sql      (with RAW_CSV_GLOB / COUNTIES_CSV pointing at the unzipped files)
--
-- The CASE block below IS the FL use-code crosswalk (Rule 12D-8.008 -> canonical category).
-- A new state = copy this file, repoint the inputs, and rewrite the column map + CASE block.

COPY (
  SELECT
    'FL' AS state,
    cty.county AS county,
    f.PARCEL_ID AS parcel_id,
    f.OWN_NAME  AS owner_name,
    f.OWN_ADDR1 AS owner_addr, f.OWN_CITY AS owner_city, f.OWN_STATE AS owner_state, f.OWN_ZIPCD AS owner_zip,
    f.PHY_ADDR1 AS site_addr,  f.PHY_CITY AS site_city,  f.PHY_ZIPCD AS site_zip,
    f.DOR_UC    AS native_use_code,
    CASE
      WHEN TRY_CAST(f.DOR_UC AS INT) IN (0,10,40,70)   THEN 'vacant'
      WHEN TRY_CAST(f.DOR_UC AS INT) BETWEEN 1  AND 9   THEN 'residential'
      WHEN TRY_CAST(f.DOR_UC AS INT) BETWEEN 11 AND 39  THEN 'commercial'
      WHEN TRY_CAST(f.DOR_UC AS INT) BETWEEN 41 AND 49  THEN 'industrial'
      WHEN TRY_CAST(f.DOR_UC AS INT) BETWEEN 50 AND 69  THEN 'agricultural'
      WHEN TRY_CAST(f.DOR_UC AS INT) BETWEEN 71 AND 79  THEN 'institutional'
      WHEN TRY_CAST(f.DOR_UC AS INT) BETWEEN 80 AND 89  THEN 'government'
      WHEN TRY_CAST(f.DOR_UC AS INT) BETWEEN 90 AND 99  THEN 'utility_misc'
      ELSE 'unknown' END AS use_category,
    TRY_CAST(f.TOT_LVG_AREA AS BIGINT) AS bldg_sqft,
    TRY_CAST(f.NO_BULDNG    AS INT)    AS num_buildings,
    TRY_CAST(f.ACT_YR_BLT   AS INT)    AS year_built,
    TRY_CAST(f.LND_SQFOOT   AS BIGINT) AS land_sqft,
    TRY_CAST(f.JV           AS BIGINT) AS market_value,
    f.* EXCLUDE (PARCEL_ID, OWN_NAME, DOR_UC)            -- all remaining native columns
  FROM read_csv_auto(getenv('RAW_CSV_GLOB'), union_by_name=true, all_varchar=true, ignore_errors=true) f
  LEFT JOIN read_csv_auto(getenv('COUNTIES_CSV'), types={'CO_NO':'VARCHAR'}) cty
    ON CAST(f.CO_NO AS VARCHAR) = cty.CO_NO
) TO 'data/parcels_fl.parquet' (FORMAT parquet, COMPRESSION zstd);

-- Owner-occupancy flags (no explicit owner-occupied field exists for FL commercial;
-- derived by matching owner mailing address to the site address). Run as a second pass
-- over the parquet above:
--   owner_occupied      = exact normalized addr match, OR (same ZIP + same street number +
--                         one normalized addr is a prefix of the other -> catches "STE 200" diffs)
--   owner_po_box        = owner mailing address is a PO box (absentee)
--   owner_out_of_state  = owner_state <> 'FL' (absentee)
--   owner_occupancy     = 'owner_occupied' | 'absentee' | 'unknown'
-- See the second-pass query used to add these four columns in the deploy history.
