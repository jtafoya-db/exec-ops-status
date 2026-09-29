-- =============================================================================
-- MEF Volume medallion — SEED (bronze/landing)
-- =============================================================================
-- SYNTHETIC SAMPLE DATA. Every figure below is invented for demonstration: it
-- is shaped like a daily MEF (Modernized e-File) VOLUME DATA report snapshot —
-- as-of business date seed_as_of_date (Daily) plus the season Year-To-Date
-- (season start .. seed_as_of_date) — but it is NOT real filing volume.
--
-- The figures are internally consistent (accepted + rejected = masterfile
-- total; Fed = IMF + BMF; states = IMF state + BMF state; submitted = Fed +
-- states; YTD >= DAILY) so the pipeline and validator behave as they would on
-- a real report. The seed is the stand-in for a real daily feed; it is the ONLY
-- place that carries hand-entered figures. Silver/gold derive everything else.
--
-- GRAIN (designed to accumulate history):
--   one row per (masterfile, measure, business_date, period)
--   period = 'DAILY'  -> the as-of day's value (business_date = seed_as_of_date)
--   period = 'YTD'    -> season-to-date value as of that same business_date
--
-- The 'DAILY' rows are the accumulating grain: when a real daily feed lands,
-- it simply appends more business_date rows with NO rework, and true YTD can
-- then be COMPUTED by summing DAILY rows instead of being seeded. We seed a
-- 'YTD' period row here only because Phase 1 has a single day of history and
-- must reconcile 1:1 to the sample report's YTD column (snapshot + YTD only — no
-- fabricated intervening days).
--
-- Reject RATES are intentionally NOT stored as ground truth here: they are
-- derived in silver/gold from accepted/rejected. The sample report's stated rates are
-- carried in a separate validation table (mef_volume_seed_rate_check) and used
-- only to assert the derivation matches.
--
-- CATALOG/SCHEMA: this file contains NO catalog/schema literals and NO USE
-- statements. The build notebook (src/build_mef_volume_medallion_nb.ipynb) sets
-- the session context ONCE from the job's parameterized ${var.catalog}/
-- ${var.schema} before running these statements, so all unqualified relations
-- below resolve against the target catalog.schema. To run this file directly in a
-- SQL editor, first `USE CATALOG <your_catalog>; USE SCHEMA <your_schema>;`.
--
-- AS-OF DATE: every seed row is stamped with ONE date, the session variable
-- seed_as_of_date declared below. Its DEFAULT is the business date the sample
-- report was printed for — the single documented date literal in this medallion.
-- The build notebook's optional `seed_as_of_date` widget overrides it (SET VAR)
-- to re-stamp the same sample numbers with a different as-of date; the local
-- harness (validate_local.py) reads this same default. Silver/gold never read a
-- date literal — they resolve the as-of from MAX(business_date).
-- =============================================================================

DECLARE OR REPLACE VARIABLE seed_as_of_date DATE DEFAULT DATE'2026-04-14';

CREATE TABLE IF NOT EXISTS mef_volume_seed (
  masterfile   STRING  COMMENT 'IMF | BMF | STATE | TOTAL — the file/aggregate the measure belongs to',
  measure      STRING  COMMENT 'canonical measure key, e.g. total_submitted, accepted, rejected, imf_state, ...',
  description  STRING  COMMENT 'the report row label, for 1:1 reconciliation to the report layout',
  period       STRING  COMMENT 'DAILY (as-of business_date) | YTD (season-to-date as of business_date)',
  business_date DATE   COMMENT 'as-of date for the value (accumulating grain key)',
  value        BIGINT  COMMENT 'the counted volume (typed integer, never a string)'
)
COMMENT 'Landing/seed for MEF volume — SYNTHETIC sample rows shaped like a MEF VOLUME DATA report snapshot. Swap target for a real upstream MEF feed at the silver boundary.';

-- Idempotent reload of the snapshot.
TRUNCATE TABLE mef_volume_seed;

INSERT INTO mef_volume_seed (masterfile, measure, description, period, business_date, value)
SELECT masterfile, measure, description, period, seed_as_of_date AS business_date, value
FROM VALUES
  -- Top-line submitted (Fed + State) -----------------------------------------
  ('TOTAL', 'total_submitted', 'Total Submitted (Fed + state)',  'DAILY', 11011052),
  ('TOTAL', 'total_submitted', 'Total Submitted (Fed + state)',  'YTD',   237936075),
  ('TOTAL', 'total_fed',       'Total Fed (IMF + BMF)',          'DAILY', 7023430),
  ('TOTAL', 'total_fed',       'Total Fed (IMF + BMF)',          'YTD',   159674852),
  ('TOTAL', 'total_states',    'Total states',                   'DAILY', 3987622),
  ('TOTAL', 'total_states',    'Total states',                   'YTD',   78261223),
  -- IMF ----------------------------------------------------------------------
  ('IMF', 'total',      'Total IMF (Including 4868s)', 'DAILY', 6095041),
  ('IMF', 'total',      'Total IMF (Including 4868s)', 'YTD',   132444846),
  ('IMF', 'accepted',   'IMF Accepted',               'DAILY', 5482137),
  ('IMF', 'accepted',   'IMF Accepted',               'YTD',   118264509),
  ('IMF', 'rejected',   'IMF Rejected',               'DAILY', 612904),
  ('IMF', 'rejected',   'IMF Rejected',               'YTD',   14180337),
  ('IMF', 'imf_state',  'Total IMF State',            'DAILY', 3706215),
  ('IMF', 'imf_state',  'Total IMF State',            'YTD',   71358490),
  -- BMF ----------------------------------------------------------------------
  ('BMF', 'total',      'Total BMF',                  'DAILY', 928389),
  ('BMF', 'total',      'Total BMF',                  'YTD',   27230006),
  ('BMF', 'accepted',   'BMF Accepted',              'DAILY', 903516),
  ('BMF', 'accepted',   'BMF Accepted',              'YTD',   26417062),
  ('BMF', 'rejected',   'BMF Rejected',              'DAILY', 24873),
  ('BMF', 'rejected',   'BMF Rejected',              'YTD',   812944),
  ('BMF', 'bmf_state',  'Total BMF State',           'DAILY', 281407),
  ('BMF', 'bmf_state',  'Total BMF State',           'YTD',   6902733)
  AS seed(masterfile, measure, description, period, value);

-- ---------------------------------------------------------------------------
-- Validation-only: the sample report's STATED reject rates (percent), computed
-- from the synthetic accepted/rejected figures above and rounded to 2 decimals. NOT used to
-- present values; silver/gold compute rates from accepted/rejected. These are
-- kept solely so the local harness / a post-deploy check can assert that the
-- derived rate matches the report within rounding.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mef_volume_seed_rate_check (
  masterfile STRING,
  period     STRING,
  business_date DATE,
  stated_reject_rate_pct DOUBLE COMMENT 'reject rate as stated on the (synthetic) sample report, in percent'
)
COMMENT 'Sample-report stated reject rates (synthetic), for validation of the derived rate only.';

TRUNCATE TABLE mef_volume_seed_rate_check;

INSERT INTO mef_volume_seed_rate_check (masterfile, period, business_date, stated_reject_rate_pct)
SELECT masterfile, period, seed_as_of_date AS business_date, stated_reject_rate_pct
FROM VALUES
  ('IMF', 'DAILY', 10.06),
  ('IMF', 'YTD',   10.71),
  ('BMF', 'DAILY', 2.68),
  ('BMF', 'YTD',   2.99)
  AS rate(masterfile, period, stated_reject_rate_pct);
