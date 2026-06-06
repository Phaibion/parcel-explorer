-- Harris County (HCAD) adapter — Texas adapter #1.
-- Input: HCAD 2025 PDATA bulk files (tab-delimited, WITH headers):
--   acct/real_acct.txt          (1 row per account: owner, situs, state_class, bld_ar, land_ar, value)
--   bld/building_other.txt      (non-residential building records: heat_ar, date_erected)
--   bld/building_res.txt        (residential building records: same key cols)
-- Output: data/parcels_tx.parquet  (canonical schema, identical to Florida)
--
-- HCAD state_class -> canonical use_category crosswalk (F1/F2 per Comptroller 96-313):
--   F1*=commercial, F2*=industrial, A/B/M/O=residential, C=vacant, D/E/1=agricultural,
--   G/J=utility_misc, X=exempt (institutional+government+nonprofit), else unknown (incl. Z*).
-- Source: https://download.hcad.org/data/CAMA/2025/  (free, no fee)

SET threads=4;

CREATE OR REPLACE TEMP TABLE bldgs AS
SELECT acct,
       COUNT(*)                                          AS n_bld,
       SUM(TRY_CAST(heat_ar AS BIGINT))                  AS heat_sqft,
       MIN(NULLIF(TRY_CAST(date_erected AS INT), 0))     AS yr_built
FROM (
  SELECT acct, heat_ar, date_erected FROM read_csv('bld/building_other.txt', delim='\t', header=true, all_varchar=true, ignore_errors=true, quote='')
  UNION ALL
  SELECT acct, heat_ar, date_erected FROM read_csv('bld/building_res.txt',   delim='\t', header=true, all_varchar=true, ignore_errors=true, quote='')
) GROUP BY acct;

COPY (
  SELECT
    'TX' AS state,
    'Harris' AS county,
    a.acct AS parcel_id,
    a.mailto AS owner_name,
    NULLIF(TRIM(CONCAT_WS(' ', a.mail_addr_1, a.mail_addr_2)), '') AS owner_addr,
    a.mail_city AS owner_city, a.mail_state AS owner_state, a.mail_zip AS owner_zip,
    a.site_addr_1 AS site_addr, a.site_addr_2 AS site_city, a.site_addr_3 AS site_zip,
    a.state_class AS native_use_code,
    CASE
      WHEN UPPER(TRIM(a.state_class)) LIKE 'F1%' THEN 'commercial'
      WHEN UPPER(TRIM(a.state_class)) LIKE 'F2%' THEN 'industrial'
      WHEN UPPER(TRIM(a.state_class)) LIKE 'A%' OR UPPER(TRIM(a.state_class)) LIKE 'B%'
        OR UPPER(TRIM(a.state_class)) LIKE 'M%' OR UPPER(TRIM(a.state_class)) LIKE 'O%' THEN 'residential'
      WHEN UPPER(TRIM(a.state_class)) LIKE 'C%' THEN 'vacant'
      WHEN UPPER(TRIM(a.state_class)) LIKE 'D%' OR UPPER(TRIM(a.state_class)) LIKE 'E%'
        OR UPPER(TRIM(a.state_class)) LIKE '1%' THEN 'agricultural'
      WHEN UPPER(TRIM(a.state_class)) LIKE 'G%' OR UPPER(TRIM(a.state_class)) LIKE 'J%' THEN 'utility_misc'
      WHEN UPPER(TRIM(a.state_class)) LIKE 'X%' THEN 'exempt'
      ELSE 'unknown' END AS use_category,
    COALESCE(NULLIF(b.heat_sqft, 0), TRY_CAST(a.bld_ar AS BIGINT)) AS bldg_sqft,
    COALESCE(b.n_bld, CASE WHEN TRY_CAST(a.bld_ar AS BIGINT) > 0 THEN 1 END) AS num_buildings,
    COALESCE(b.yr_built, NULLIF(TRY_CAST(a.yr_impr AS INT), 0)) AS year_built,
    TRY_CAST(a.land_ar AS BIGINT) AS land_sqft,
    TRY_CAST(a.tot_mkt_val AS BIGINT) AS market_value,
    a.* EXCLUDE (acct, mailto, state_class)               -- all remaining native HCAD columns
  FROM read_csv('acct/real_acct.txt', delim='\t', header=true, all_varchar=true, ignore_errors=true, quote='') a
  LEFT JOIN bldgs b ON a.acct = b.acct
) TO 'parcels_tx.parquet' (FORMAT parquet, COMPRESSION zstd);
