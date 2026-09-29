-- =============================================================================
-- MEF Volume medallion — GOLD (presentation-shaped views the dashboard reads)
-- =============================================================================
-- Two-tier gold, so history is never collapsed:
--   (a) FULL-HISTORY views at grain (masterfile, measure, business_date) — one
--       row per snapshot day. Trend / YoY / season-over-season read these; they
--       accumulate automatically as real daily data lands (spec §3.1/§3.4).
--   (b) CURRENT projection — the ONE coherent as-of date, resolved as a SINGLE
--       MAX(business_date) computed ONCE (not independent per-column MAX), so
--       today-tiles never combine values across snapshots. Composition +
--       disposition + source-detail tiles read the CURRENT views only.
--
-- NAMING: deliberately `mef_mvp_gold_*` (NOT `gold_mef_volume`) to avoid
-- colliding with any other gold-layer mart of that name in the target schema.
--
-- CATALOG/SCHEMA: no catalog/schema literals and no USE statements here. The
-- build notebook sets the parameterized ${var.catalog}/${var.schema} context once
-- before running this file; all unqualified relations resolve against it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- (a) FULL HISTORY — volume, grain (masterfile, measure, description, business_date)
--     Daily and YTD pivoted WITHIN a single business_date (grouping includes
--     business_date, so no cross-snapshot mixing). One row per measure per day.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mef_mvp_gold_volume_history AS
SELECT
  masterfile,
  measure,
  description,
  business_date,
  CAST(MAX(CASE WHEN period = 'DAILY' THEN value END) AS BIGINT) AS daily_value,
  CAST(MAX(CASE WHEN period = 'YTD'   THEN value END) AS BIGINT) AS ytd_value
FROM silver_mef_volume
GROUP BY masterfile, measure, description, business_date;

-- (a) FULL HISTORY — derived reject rate, grain (masterfile, business_date).
CREATE OR REPLACE VIEW mef_mvp_gold_reject_rate_history AS
SELECT
  masterfile,
  business_date,
  MAX(CASE WHEN period = 'DAILY' THEN reject_rate_pct END) AS daily_reject_rate_pct,
  MAX(CASE WHEN period = 'YTD'   THEN reject_rate_pct END) AS ytd_reject_rate_pct
FROM silver_mef_reject_rate
GROUP BY masterfile, business_date;

-- ---------------------------------------------------------------------------
-- as-of resolver: the SINGLE current business_date, computed ONCE. Everything
-- "current" joins to this so all tiles share one coherent snapshot date.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mef_mvp_gold_as_of AS
SELECT MAX(business_date) AS as_of_date
FROM silver_mef_volume;

-- ---------------------------------------------------------------------------
-- (b) CURRENT — source detail, report-shaped (1:1 to the paper report table),
--     ONLY the latest snapshot day.
--
-- Value vs rate are different UNITS, so the numeric columns keep them separate
-- (count rows: daily_value/ytd_value populated, daily_rate/ytd_rate NULL; rate
-- rows: the reverse) — kept for numeric consumers. FOR DISPLAY, daily_display /
-- ytd_display collapse each row to exactly ONE pre-formatted string (like the
-- paper report): counts as thousands-separated integers (e.g. 11,011,052), reject
-- rates as a 2-decimal percent with '%' (e.g. 10.06%). The reject_rate_pct value
-- is ALREADY a percent (0..100), so we format it directly and append '%' — no
-- second *100. The dashboard's detail table selects only description + these two
-- string columns, so every row shows one Daily and one YTD cell with ZERO nulls.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mef_mvp_gold_volume AS
WITH asof AS (SELECT as_of_date FROM mef_mvp_gold_as_of)
-- count rows for the current day
SELECT
  h.masterfile,
  h.measure,
  h.description,
  h.business_date                AS as_of_date,
  h.daily_value,
  h.ytd_value,
  CAST(NULL AS DOUBLE)           AS daily_rate,
  CAST(NULL AS DOUBLE)           AS ytd_rate,
  format_number(h.daily_value, 0) AS daily_display,   -- e.g. 11,011,052
  format_number(h.ytd_value, 0)   AS ytd_display,     -- e.g. 237,936,075
  CASE h.measure
    WHEN 'total_submitted' THEN 1
    WHEN 'total_fed'       THEN 2
    WHEN 'total_states'    THEN 3
    ELSE 100
  END
  + CASE h.masterfile WHEN 'IMF' THEN 10 WHEN 'BMF' THEN 20 ELSE 0 END
  + CASE h.measure
      WHEN 'total'     THEN 1
      WHEN 'accepted'  THEN 2
      WHEN 'rejected'  THEN 3
      WHEN 'imf_state' THEN 5
      WHEN 'bmf_state' THEN 5
      ELSE 0
    END                          AS display_order
FROM mef_mvp_gold_volume_history h
JOIN asof ON h.business_date = asof.as_of_date

UNION ALL

-- derived reject-rate rows for the current day (one per masterfile)
SELECT
  r.masterfile,
  'reject_rate'                                          AS measure,
  CONCAT(r.masterfile, ' Reject Rate')                   AS description,
  r.business_date                                        AS as_of_date,
  CAST(NULL AS BIGINT)                                   AS daily_value,
  CAST(NULL AS BIGINT)                                   AS ytd_value,
  CAST(r.daily_reject_rate_pct AS DOUBLE)                AS daily_rate,
  CAST(r.ytd_reject_rate_pct   AS DOUBLE)                AS ytd_rate,
  CONCAT(format_number(r.daily_reject_rate_pct, 2), '%') AS daily_display,  -- e.g. 10.06%
  CONCAT(format_number(r.ytd_reject_rate_pct, 2), '%')   AS ytd_display,    -- e.g. 10.71%
  100 + CASE r.masterfile WHEN 'IMF' THEN 10 WHEN 'BMF' THEN 20 ELSE 0 END + 4 AS display_order
FROM mef_mvp_gold_reject_rate_history r
JOIN asof ON r.business_date = asof.as_of_date;

-- ---------------------------------------------------------------------------
-- Retire the legacy wide KPI projection. Dashboard counters now select dimension
-- values from the tidy views below, so adding a masterfile or measure is a row-only
-- change and never requires a gold schema migration.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS mef_mvp_gold_kpi;

-- ---------------------------------------------------------------------------
-- (b) CURRENT — composition (Federal IMF/BMF vs State) for the as-of day.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mef_mvp_gold_composition AS
SELECT as_of_date, segment, component, daily_value, ytd_value FROM (
  SELECT as_of_date, 'Federal' AS segment, 'IMF' AS component, daily_value, ytd_value
    FROM mef_mvp_gold_volume WHERE masterfile='IMF' AND measure='total'
  UNION ALL
  SELECT as_of_date, 'Federal' AS segment, 'BMF' AS component, daily_value, ytd_value
    FROM mef_mvp_gold_volume WHERE masterfile='BMF' AND measure='total'
  UNION ALL
  SELECT as_of_date, 'State' AS segment, 'States' AS component, daily_value, ytd_value
    FROM mef_mvp_gold_volume WHERE masterfile='TOTAL' AND measure='total_states'
);

-- ---------------------------------------------------------------------------
-- (b) CURRENT — accepted vs rejected per masterfile for the as-of day.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mef_mvp_gold_disposition AS
SELECT as_of_date, masterfile, disposition, daily_value, ytd_value FROM (
  SELECT as_of_date, masterfile, 'Accepted' AS disposition, daily_value, ytd_value
    FROM mef_mvp_gold_volume WHERE masterfile IN ('IMF','BMF') AND measure='accepted'
  UNION ALL
  SELECT as_of_date, masterfile, 'Rejected' AS disposition, daily_value, ytd_value
    FROM mef_mvp_gold_volume WHERE masterfile IN ('IMF','BMF') AND measure='rejected'
);
