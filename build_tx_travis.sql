-- Travis County (TCAD) adapter — PACS fixed-width appraisal export.
-- This PACS layout (Legacy 8.0.32) is shared by Denton and many other TX CADs.
-- Inputs (TCAD 2026 preliminary export, free from traviscad.org/publicinformation):
--   roll/PROP.TXT                         fixed-width property master (positions from the layout xlsx, Property sheet)
--   improv/improvement_detail_2026_*.csv  headered CSV: pID, pImprovementID, stateCd, TotgrossArea, actualYearBuilt
-- Output: data/tx/parcels_travis.parquet  (canonical schema, identical column order to Harris)
-- Fixed-width positions (1-indexed start,len): prop_id 1,12 | py_owner_name 609,70 |
--   py_addr_line1 694,60 | py_addr_city 874,50 | py_addr_state 924,50 | py_addr_zip 979,5 |
--   situs_num 4460,15 | situs_street_prefx 1040,10 | situs_street 1050,50 | situs_street_suffix 1100,10 |
--   situs_city 1110,30 | situs_zip 1140,10 | imprv_state_cd 2732,10 | land_state_cd 2742,10 |
--   legal_acreage 1660,16 | market_value 4214,14

SET threads=4;

CREATE OR REPLACE TEMP TABLE imp AS
SELECT TRY_CAST(pID AS BIGINT) AS pid,
       MAX(TRY_CAST(TotgrossArea AS DOUBLE))            AS gross_sqft,   -- property-level total gross SF
       COUNT(DISTINCT pImprovementID)                    AS n_bld,
       MIN(NULLIF(TRY_CAST(actualYearBuilt AS INT), 0))  AS yr,
       MAX(stateCd)                                      AS imp_state
FROM read_csv('improv/improvement_detail_2026_*.csv', header=true, all_varchar=true, ignore_errors=true)
GROUP BY 1;

COPY (
  WITH prop AS (
    SELECT
      TRY_CAST(trim(substr(line,1,12)) AS BIGINT)                                   AS pid,
      CAST(TRY_CAST(trim(substr(line,1,12)) AS BIGINT) AS VARCHAR)                  AS parcel_id,
      trim(substr(line,609,70))                                                     AS owner_name,
      NULLIF(trim(concat_ws(' ', trim(substr(line,694,60)), trim(substr(line,754,60)))), '') AS owner_addr,
      trim(substr(line,874,50))                                                     AS owner_city,
      trim(substr(line,924,50))                                                     AS owner_state,
      trim(substr(line,979,5))                                                      AS owner_zip,
      NULLIF(trim(concat_ws(' ', trim(substr(line,4460,15)), trim(substr(line,1040,10)),
                                  trim(substr(line,1050,50)), trim(substr(line,1100,10)))), '') AS site_addr,
      trim(substr(line,1110,30))                                                    AS site_city,
      trim(substr(line,1140,10))                                                    AS site_zip,
      NULLIF(trim(substr(line,2732,10)), '')                                        AS imprv_cd,
      NULLIF(trim(substr(line,2742,10)), '')                                        AS land_cd,
      TRY_CAST(trim(substr(line,1660,16)) AS DOUBLE)                                AS acreage,
      TRY_CAST(trim(substr(line,4214,14)) AS BIGINT)                                AS market_value
    FROM read_csv('roll/PROP.TXT', delim='\x07', header=false, columns={'line':'VARCHAR'},
                  quote='', ignore_errors=true, max_line_size=1000000)
    QUALIFY row_number() OVER (PARTITION BY trim(substr(line,1,12)) ORDER BY trim(substr(line,609,70))) = 1
  ), j AS (
    SELECT p.*, i.gross_sqft, i.n_bld, i.yr, i.imp_state,
           COALESCE(p.imprv_cd, i.imp_state, p.land_cd) AS uc
    FROM prop p LEFT JOIN imp i ON p.pid = i.pid
  ), base AS (
    SELECT
      'TX' AS state, 'Travis' AS county, parcel_id, owner_name,
      owner_addr, owner_city, owner_state, owner_zip,
      site_addr, site_city, site_zip,
      uc AS native_use_code,
      CASE
        WHEN upper(coalesce(uc,'')) LIKE 'F2%' THEN 'industrial'
        WHEN upper(coalesce(uc,'')) LIKE 'F%'  THEN 'commercial'
        WHEN upper(coalesce(uc,'')) LIKE 'A%' OR upper(coalesce(uc,'')) LIKE 'B%'
          OR upper(coalesce(uc,'')) LIKE 'M%' OR upper(coalesce(uc,'')) LIKE 'O%' THEN 'residential'
        WHEN upper(coalesce(uc,'')) LIKE 'C%' THEN 'vacant'
        WHEN upper(coalesce(uc,'')) LIKE 'D%' OR upper(coalesce(uc,'')) LIKE 'E%'
          OR upper(coalesce(uc,'')) LIKE '1%' THEN 'agricultural'
        WHEN upper(coalesce(uc,'')) LIKE 'G%' OR upper(coalesce(uc,'')) LIKE 'J%' THEN 'utility_misc'
        WHEN upper(coalesce(uc,'')) LIKE 'X%' THEN 'exempt'
        ELSE 'unknown' END AS use_category,
      TRY_CAST(gross_sqft AS BIGINT) AS bldg_sqft,
      n_bld AS num_buildings,
      yr AS year_built,
      CAST(acreage * 43560 AS BIGINT) AS land_sqft,
      market_value
    FROM j
  ), flags AS (
    SELECT *,
      regexp_replace(upper(coalesce(owner_addr,'')), '[^A-Z0-9]','','g') AS _o,
      regexp_replace(upper(coalesce(site_addr,'')),  '[^A-Z0-9]','','g') AS _s,
      regexp_extract(coalesce(owner_addr,''), '([0-9]+)', 1) AS _on,
      regexp_extract(coalesce(site_addr,''),  '([0-9]+)', 1) AS _sn
    FROM base
  ), occ AS (
    SELECT *,
      ( (_o<>'' AND _o=_s)
        OR (_o<>'' AND _s<>'' AND coalesce(owner_zip,'')<>'' AND coalesce(owner_zip,'')=coalesce(site_zip,'')
            AND _on<>'' AND _on=_sn AND (_o LIKE _s||'%' OR _s LIKE _o||'%')) ) AS owner_occupied,
      (upper(coalesce(owner_addr,'')) LIKE '%PO BOX%' OR upper(coalesce(owner_addr,'')) LIKE '%P O BOX%') AS owner_po_box,
      (coalesce(owner_state,'')<>'' AND upper(owner_state) NOT IN ('TX','TEXAS')) AS owner_out_of_state
    FROM flags
  )
  SELECT
    state, county, parcel_id, owner_name, owner_addr, owner_city, owner_state, owner_zip,
    site_addr, site_city, site_zip, native_use_code, use_category, bldg_sqft, num_buildings,
    year_built, land_sqft, market_value, owner_occupied, owner_po_box, owner_out_of_state,
    CASE WHEN owner_occupied THEN 'owner_occupied'
         WHEN upper(coalesce(owner_state,'')) IN ('TX','TEXAS') THEN 'instate_owner'
         WHEN coalesce(trim(owner_state),'')<>'' THEN 'out_of_state'
         ELSE 'unknown' END AS owner_occupancy
  FROM occ
) TO 'data/tx/parcels_travis.parquet' (FORMAT parquet, COMPRESSION zstd);
