# MEF Volume Data Contract

This contract is the portable boundary for the MEF volume dashboard. To bring real MeF data into another workspace, produce rows in this shape into `mef_volume_source`; silver, gold, and the dashboard then work unchanged.

## Required source shape

`mef_volume_source` has exactly one typed numeric observation per row:

| Column | Type | Meaning |
| --- | --- | --- |
| `masterfile` | `STRING` | File family or aggregate that owns the measure. Expected report values are `IMF`, `BMF`, and `TOTAL`. `STATE` may be used by future source mappings for state-owned detail rows. |
| `measure` | `STRING` | Stable machine-readable measure key. Expected keys are described below. New measures are new rows, never new columns. |
| `description` | `STRING` | Human-readable label for the detail table, such as `IMF Accepted`. Keep it meaningful and stable within a measure. |
| `period` | `STRING` | `DAILY` for the value on `business_date`, or `YTD` for the season-to-date value as of `business_date`. |
| `business_date` | `DATE` | Snapshot/as-of date. Load both `DAILY` and `YTD` observations against the same date. A later snapshot is added with a later date; it does not replace history. |
| `value` | `BIGINT` | Count for this observation. Supply a numeric integer, not formatted text, a percentage, or a column containing mixed units. |

The grain is one row per `(masterfile, measure, period, business_date)`. `description` labels that observation and should not create duplicates at the grain. Each grain key must be unique.

## Expected dimension values

The current dashboard recognizes these rows:

| `masterfile` | `measure` | Meaning |
| --- | --- | --- |
| `TOTAL` | `total_submitted` | All federal and state submissions. |
| `TOTAL` | `total_fed` | Federal submissions: IMF plus BMF. |
| `TOTAL` | `total_states` | State submissions. |
| `IMF` | `total` | Total IMF submissions. |
| `IMF` | `accepted` | Accepted IMF submissions. |
| `IMF` | `rejected` | Rejected IMF submissions. |
| `IMF` | `imf_state` | IMF state submissions, when supplied by the report. |
| `BMF` | `total` | Total BMF submissions. |
| `BMF` | `accepted` | Accepted BMF submissions. |
| `BMF` | `rejected` | Rejected BMF submissions. |
| `BMF` | `bmf_state` | BMF state submissions, when supplied by the report. |

At minimum, supply `total_submitted`, `total_fed`, `total_states`, and the `total`, `accepted`, and `rejected` rows for both IMF and BMF for each displayed snapshot. The dashboard filters on these dimension values. Preserve their spelling and case when mapping a real source.

Additional masterfiles and measures are valid contract rows and do not require a schema change. They become visible to downstream consumers that select those dimensions; adding them to a specific dashboard visualization is a presentation change only.

## Derived values and consistency

Do not supply reject rate or KPI columns. Reject rate is derived for each masterfile, period, and business date as:

`rejected / (accepted + rejected) * 100`

The denominator is null-safe, and the result is a percentage on the 0–100 scale. Counter values, Federal/State composition, accepted-versus-rejected comparisons, and current-as-of projections are also derived from tidy rows. The retired wide KPI view is not part of the contract.

Before publishing a snapshot, check these expected relationships where the source supports them:

- `total_submitted = total_fed + total_states`
- `total_fed = IMF total + BMF total`
- For each IMF/BMF period, `total = accepted + rejected`
- There is one coherent `business_date` for all rows in a snapshot

## Porting real MEF data

Map the real table or Genie Code output to the six columns above in `mef_volume_source`. Normalize source labels to the expected dimension values, cast the date and numeric types, and emit separate rows for `DAILY` and `YTD`. Do not pivot measures into columns and do not add workspace-specific catalog or schema names to dashboard SQL.

After mapping, run the medallion build. `silver_mef_volume` applies the canonical types; tidy gold history retains every business date; current gold views select the latest coherent snapshot; and the dashboard continues to query those views without a schema change.
