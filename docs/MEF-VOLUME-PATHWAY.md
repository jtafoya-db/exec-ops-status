# MEF Volume — Pipeline Pathway (how the snapshot goes real)

**Phase 1 deliverable.** This is the one-page map of how each executive KPI flows
from source → silver → gold → dashboard, and exactly what changes when a real
MEF volume feed from your upstream source system lands.

The Phase-1 dashboard ships on **synthetic seed** data shaped like a daily
**MEF VOLUME DATA** report (daily as-of snapshot + season YTD); the figures are
invented sample values, not real filing volume. It is
a portable Databricks Asset Bundle: it deploys to any Databricks workspace by
setting target variables only. Nothing is hardcoded.

> **The payoff is history, not the PDF.** Rebuilding the paper report is not the
> value. The value is what the lakehouse can do that the paper report structurally
> cannot: **accumulate daily snapshots into history.** The moment a real daily MEF
> feed lands in the silver source, this same model — with **no rework** — unlocks
> daily/YTD **trend lines**, **season-over-season / year-over-year** comparison
> (prior season vs current season vs …), and **trajectory / anomaly detection** ("reject rate
> climbing across the last N days", "volume vs. projection"). The accumulating
> `masterfile × measure × business_date` grain (see `00_seed.sql`) is what keeps
> that door open. Phase 1 seeds a single as-of day (the sample snapshot date,
> parameterized as `seed_as_of_date`) + the YTD figures —
> **no fabricated history** — but the grain is built so a second day of real data
> is all it takes to make the trend visuals real.

## The swap seam (going real is one localized edit)

The swap is **localized to one view**: `mef_volume_source` in
`sql/mef_volume/10_silver.sql`. It is the only place that touches the raw source.
Everything else — `silver_mef_volume`, the derived rates, all `mef_mvp_gold_*`
views, and the dashboard — reads the **silver column contract**, never the raw
table, so nothing downstream changes on the swap.

Honest scope: it is **not** literally a one-character change, because the real
source table will not have the seed's exact column names. It **is** a single,
self-contained edit in one clearly-marked view: repoint the `FROM` at the real
table and alias its columns onto the contract. Today (seed):

```sql
CREATE OR REPLACE VIEW mef_volume_source AS
SELECT masterfile, measure, description, period, business_date, value
FROM mef_volume_seed;   -- <-- the sole edit location
```

Going real (illustrative — map the real column names on the left of each `AS`):

```sql
CREATE OR REPLACE VIEW mef_volume_source AS
SELECT
  file_type      AS masterfile,     -- 'IMF' | 'BMF' | 'STATE' | 'TOTAL'
  metric_key     AS measure,        -- total_submitted | total | accepted | rejected | ...
  row_label      AS description,    -- report row text for the source-detail table
  agg_period     AS period,         -- 'DAILY' | 'YTD'
  as_of_dt       AS business_date,  -- DATE — the accumulating-history grain key
  submission_cnt AS value           -- BIGINT count
FROM <your_catalog>.<your_schema>.<your_mef_volume_table>;  -- your upstream MEF volume table
```

### Silver column contract (what the real source table must supply)

| Contract column | Type | Meaning | Real-source note |
|---|---|---|---|
| `masterfile` | STRING | `IMF` \| `BMF` \| `STATE` \| `TOTAL` | map/normalize the source's file-type code |
| `measure` | STRING | `total_submitted` \| `total_fed` \| `total_states` \| `total` \| `accepted` \| `rejected` \| `imf_state` \| `bmf_state` | map the source's metric identifier |
| `description` | STRING | report row label (for the source-detail table) | any human label; used for display only |
| `period` | STRING | `DAILY` (as-of day) \| `YTD` (season-to-date) | if the real feed is daily-only, `YTD` can be **computed** by summing `DAILY` rows |
| `business_date` | DATE | as-of date — the accumulating-history grain key | one real date per daily load |
| `value` | BIGINT | the counted volume | integer count |

Reject **rates** are **not** in the contract — they are derived downstream from
`accepted`/`rejected`, so the real source only supplies counts.

## Measure-by-measure map

| Dashboard KPI / element | Source (real feed = TODO) | Silver | Gold | Notes |
|---|---|---|---|---|
| Total Submitted (Daily + YTD) | upstream MEF: total submitted (Fed+State) | `silver_mef_volume` (`TOTAL`/`total_submitted`) | `mef_mvp_gold_volume` (`TOTAL`/`total_submitted`) | top-line tile + source table row |
| Total Fed (IMF + BMF) | upstream MEF: federal submitted | `silver_mef_volume` (`TOTAL`/`total_fed`) | `mef_mvp_gold_volume` | validated = IMF total + BMF total |
| Total States | upstream MEF: state submitted | `silver_mef_volume` (`TOTAL`/`total_states`) | `mef_mvp_gold_volume`, `mef_mvp_gold_composition` (State) | composition bar |
| IMF Accepted (Daily) | upstream MEF: IMF accepted | `silver_mef_volume` (`IMF`/`accepted`) | `mef_mvp_gold_disposition` (`IMF`/`Accepted`) | counter + disposition bar |
| BMF Accepted (Daily) | upstream MEF: BMF accepted | `silver_mef_volume` (`BMF`/`accepted`) | `mef_mvp_gold_disposition` (`BMF`/`Accepted`) | counter + disposition bar |
| IMF / BMF Rejected | upstream MEF: IMF/BMF rejected | `silver_mef_volume` (`*`/`rejected`) | `mef_mvp_gold_disposition`, feeds reject rate | disposition bar |
| IMF Reject Rate (Daily + YTD) | **DERIVED** — not sourced | `silver_mef_reject_rate` = `rejected / NULLIF(accepted+rejected,0)` | `mef_mvp_gold_volume` (`IMF`/`reject_rate`) | today-vs-YTD chart; computed, null-safe |
| BMF Reject Rate (Daily + YTD) | **DERIVED** — not sourced | `silver_mef_reject_rate` | `mef_mvp_gold_volume` (`BMF`/`reject_rate`) | today-vs-YTD chart; computed, null-safe |
| IMF / BMF total, State subtotals | upstream MEF: per-masterfile totals + state | `silver_mef_volume` | `mef_mvp_gold_volume`, `mef_mvp_gold_composition` | source detail table + composition |
| **Future: daily/YTD trend, YoY, anomaly** | real daily feed (multiple `business_date`s) | same grain, no rework | trend views added later | **not built in Phase 1** — the grain already supports it |

## Medallion layers (files)

- `sql/mef_volume/00_seed.sql` — **SEED**: synthetic sample report rows, typed BIGINT counts,
  real `DATE` business dates, grain `(masterfile, measure, period, business_date)`.
  Reject rates are **not** stored as values here (derived downstream); the report's
  stated rates live in `mef_volume_seed_rate_check` for validation only.
- `sql/mef_volume/10_silver.sql` — **SILVER**: `mef_volume_source` (**the swap seam** —
  the one view that touches the raw source), `silver_mef_volume` (typed staging over
  the contract), and `silver_mef_reject_rate` (null-safe derived reject rates).
- `sql/mef_volume/20_gold.sql` — **GOLD**, two tiers so history is never collapsed:
  - **Full history** at grain `(masterfile, measure, business_date)`:
    `mef_mvp_gold_volume_history`, `mef_mvp_gold_reject_rate_history` — trend / YoY
    read these; they accumulate automatically as real daily data lands.
  - **Current projection** — `mef_mvp_gold_as_of` resolves the single latest
    `business_date` **once**; `mef_mvp_gold_volume` (report-shaped detail),
    `mef_mvp_gold_composition`, and `mef_mvp_gold_disposition` all
    read only that one as-of date, so today-tiles never mix values across snapshots.
  - Named `mef_mvp_gold_*` to avoid colliding with any existing `gold_mef_volume`
    mart in the target schema.
- `src/build_mef_volume_medallion_nb.ipynb` — the build notebook: reads the three SQL
  files from Workspace Files and runs them **in order seed → silver → gold** under the
  parameterized catalog/schema. Wired as the `build_mef_volume_medallion` job.
  catalog/schema are **parameter-only** — the `.sql` files contain no catalog/schema
  literals and no `USE` statements; the notebook sets the context once from the job
  params (bound to `${var.catalog}`/`${var.schema}`) and fails fast if either is empty.
- `sql/mef_volume/validate_local.py` — deterministic local logic harness (SQLite);
  proves every view executes, reconciles 1:1 to the seed, AND (multi-date fixture)
  that gold keeps full history while current tiles show only the latest snapshot.

## Zip-and-deploy handoff

This ships as a portable package that deploys into any Databricks workspace. With
the Databricks CLI authed to the target workspace:

1. **Set the target vars** (in `databricks.yml` for the chosen target, or via
   `--var`): `catalog`, `schema`, `warehouse_id`, and the workspace `host`. Nothing
   else is environment-specific — the dashboard datasets carry **no** catalog/schema
   literals; `dataset_catalog`/`dataset_schema` (bound to these vars) retarget them at
   deploy.
2. **Deploy the bundle:**
   ```
   databricks bundle deploy -t <target>
   ```
3. **⚠️ REQUIRED — build the medallion** (deploy does NOT run any SQL):
   ```
   databricks bundle run build_mef_volume_medallion -t <target>
   ```
   This runs seed → silver → gold **in order**. **The dashboard is non-rendering
   until this job completes** — before it runs, the `mef_mvp_gold_*` relations do not
   exist and every tile errors on a missing relation. This is not optional.
4. **Open the dashboard** — "MEF Volume — Modernized e-File" — in the target
   workspace. It now renders from `mef_mvp_gold_*`.

> Optional: to also stamp catalog/schema onto the on-disk `.lvdash.json` datasets
> (e.g. for opening the raw file outside the bundle), run
> `python scripts/set_dashboard_catalog_schema.py --file src/mef_volume.lvdash.json
> --to-catalog <cat> --to-schema <sch>`. Not required for a correct deploy — the
> resource-level override already retargets at deploy time.

**Slip contingency:** if the real MEF feed hasn't landed by the ship date, this
same package demos on seed. Going real is the localized edit to the `mef_volume_source`
seam (see "The swap seam" above) — no dashboard rebuild, and history begins accruing
from the first real daily load.
