-- =============================================================================
-- MEF Volume medallion — SILVER (normalized / typed staging)
-- =============================================================================
-- One row per (masterfile x measure x period x business_date), typed numerics.
--
-- CATALOG/SCHEMA: no catalog/schema literals and no USE statements here. The
-- build notebook sets the parameterized ${var.catalog}/${var.schema} context once
-- before running this file; all unqualified relations resolve against it.
-- =============================================================================

-- ===========================================================================
-- >>> THE SWAP SEAM <<< — mef_volume_source is the SINGLE place that changes
-- when the real MEF volume feed lands. It is a view that maps whatever the
-- real source looks like onto the fixed SILVER COLUMN CONTRACT (below). Today it
-- selects the seed 1:1; to go real you redefine THIS ONE VIEW to select from the
-- real upstream MEF volume table, mapping its columns to the contract. Nothing else in the
-- medallion, dashboard, or docs changes — silver/gold/dashboard all read the
-- contract, never the raw source.
--
-- SILVER COLUMN CONTRACT (the real source table must be mapped to exactly this):
--   masterfile    STRING  -- 'IMF' | 'BMF' | 'STATE' | 'TOTAL'
--   measure       STRING  -- 'total_submitted'|'total_fed'|'total_states'|
--                            'total'|'accepted'|'rejected'|'imf_state'|'bmf_state'
--   description   STRING  -- human label for the source detail table (report row text)
--   period        STRING  -- 'DAILY' (the as-of day) | 'YTD' (season-to-date)
--   business_date DATE    -- as-of date; the accumulating-history grain key
--   value         BIGINT  -- the counted volume (integer, never a string)
--
-- Reject RATES are NOT part of the contract — they are DERIVED below from
-- accepted/rejected, so the real source only has to supply counts.
-- ===========================================================================
CREATE OR REPLACE VIEW mef_volume_source AS
SELECT
  masterfile,
  measure,
  description,
  period,
  business_date,
  value
-- TODO(real-data): to go real, change ONLY this FROM to the real upstream MEF
-- volume table and map its columns to the contract above (e.g.
--   FROM <your_catalog>.<your_schema>.<your_mef_volume_table>) with a SELECT that aliases the real column names
-- onto masterfile/measure/description/period/business_date/value). This view is
-- the sole edit location.
FROM mef_volume_seed;

-- ---------------------------------------------------------------------------
-- silver_mef_volume: typed staging over the swap seam. Reads mef_volume_source
-- (the contract), never the seed/real table directly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW silver_mef_volume AS
SELECT
  CAST(masterfile   AS STRING) AS masterfile,
  CAST(measure      AS STRING) AS measure,
  CAST(description  AS STRING) AS description,
  CAST(period       AS STRING) AS period,          -- DAILY | YTD
  CAST(business_date AS DATE)  AS business_date,
  CAST(value        AS BIGINT) AS value
FROM mef_volume_source;

-- ---------------------------------------------------------------------------
-- Silver "rates" view: reject rate DERIVED (never stored) from accepted/rejected,
-- null-safe via NULLIF on the denominator. One row per masterfile x period x date.
-- Denominator = accepted + rejected (the returns that received an accept/reject
-- disposition), matching how the report computes its reject rate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW silver_mef_reject_rate AS
WITH ar AS (
  SELECT
    masterfile,
    period,
    business_date,
    MAX(CASE WHEN measure = 'accepted' THEN value END) AS accepted,
    MAX(CASE WHEN measure = 'rejected' THEN value END) AS rejected
  FROM silver_mef_volume
  WHERE masterfile IN ('IMF', 'BMF')
    AND measure IN ('accepted', 'rejected')
  GROUP BY masterfile, period, business_date
)
SELECT
  masterfile,
  period,
  business_date,
  accepted,
  rejected,
  (accepted + rejected)                                              AS disposed,
  -- derived reject rate as a PERCENT (0..100), null-safe. Percent (not fraction)
  -- so it reconciles directly to the report's "10.71%" and formats with a plain
  -- number format + a "%" display label (no percent-format schema field needed).
  100.0 * CAST(rejected AS DOUBLE) / NULLIF(CAST(accepted + rejected AS DOUBLE), 0) AS reject_rate_pct
FROM ar;
