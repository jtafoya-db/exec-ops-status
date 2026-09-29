#!/usr/bin/env python3
"""
Local logic validation for the MEF Volume medallion.

We cannot reach a Databricks SQL warehouse from the build environment, so this
harness proves the medallion LOGIC deterministically in SQLite:

  1. Loads the EXACT seed rows (parsed from 00_seed.sql's INSERT, so the seed
     numbers are validated as committed, not re-typed here).
  2. Re-expresses the swap-seam + silver + gold transforms in SQLite dialect (the
     committed .sql stays in Databricks SQL dialect; only the dialect is adapted
     here: CREATE OR REPLACE VIEW -> CREATE VIEW, dates as ISO strings, the
     seed_as_of_date session variable resolved to its declared DEFAULT, the dev-
     default USE CATALOG/SCHEMA header dropped since SQLite has no catalogs).
  3. Asserts every tidy view executes and dimension-filtered values reconcile 1:1 to the report,
     and that DERIVED reject rates match the report's STATED rates within rounding.
  4. MULTI-DATE FIXTURE (BLOCKING 2): injects a synthetic SECOND business_date
     (harness-only; NOT committed to the seed) and proves gold never combines
     values across snapshots and the CURRENT (today) tiles show only the latest
     date, while the full-history view keeps BOTH days.

Run:  python3 sql/mef_volume/validate_local.py
Exits non-zero on any mismatch.
"""
import os
import re
from datetime import date, timedelta
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SEED_SQL = os.path.join(HERE, "00_seed.sql")


# ---------------------------------------------------------------------------
# 1. Parse the seed rows straight out of 00_seed.sql (single source of truth).
# ---------------------------------------------------------------------------
def parse_seed_as_of(text):
    """The seed's single as-of date: the DEFAULT of the seed_as_of_date session
    variable declared in 00_seed.sql (every seed row is stamped with it)."""
    return re.search(
        r"DECLARE\s+OR\s+REPLACE\s+VARIABLE\s+seed_as_of_date\s+DATE\s+DEFAULT\s+DATE'([^']*)'",
        text, re.I,
    ).group(1)


def parse_seed(path):
    text = open(path).read()
    as_of = parse_seed_as_of(text)
    vol_block = re.search(
        r"INSERT INTO mef_volume_seed\b[^;]*?VALUES(.*?);", text, re.S
    ).group(1)
    vol_rows = []
    for m in re.finditer(
        r"\(\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*(\d+)\s*\)",
        vol_block,
    ):
        mf, meas, desc, period, val = m.groups()
        vol_rows.append((mf, meas, desc, period, as_of, int(val)))

    rate_block = re.search(
        r"INSERT INTO mef_volume_seed_rate_check[^;]*?VALUES(.*?);", text, re.S
    ).group(1)
    rate_rows = []
    for m in re.finditer(
        r"\(\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*([\d.]+)\s*\)",
        rate_block,
    ):
        mf, period, pct = m.groups()
        rate_rows.append((mf, period, as_of, float(pct)))
    return vol_rows, rate_rows, as_of


# ---------------------------------------------------------------------------
# 2. Build the medallion in SQLite (dialect-adapted, mirrors 10_silver/20_gold).
# ---------------------------------------------------------------------------
def _format_number(x, d):
    """Mirror Spark SQL format_number(x, d): thousands-separated, d decimals."""
    if x is None:
        return None
    return f"{float(x):,.{int(d)}f}"


def build(conn, vol_rows):
    # Register a format_number UDF so the harness mirrors the .sql display columns
    # (Spark's format_number has no SQLite builtin equivalent).
    conn.create_function("format_number", 2, _format_number)
    c = conn.cursor()
    c.execute(
        "CREATE TABLE mef_volume_seed "
        "(masterfile TEXT, measure TEXT, description TEXT, period TEXT, business_date TEXT, value INTEGER)"
    )
    c.executemany("INSERT INTO mef_volume_seed VALUES (?,?,?,?,?,?)", vol_rows)

    # SWAP SEAM — the single source relation (10_silver.sql).
    c.execute(
        """
        CREATE VIEW mef_volume_source AS
        SELECT masterfile, measure, description, period, business_date, value
        FROM mef_volume_seed
        """
    )
    # SILVER
    c.execute(
        """
        CREATE VIEW silver_mef_volume AS
        SELECT masterfile, measure, description, period, business_date, value
        FROM mef_volume_source
        """
    )
    c.execute(
        """
        CREATE VIEW silver_mef_reject_rate AS
        WITH ar AS (
          SELECT masterfile, period, business_date,
                 MAX(CASE WHEN measure='accepted' THEN value END) AS accepted,
                 MAX(CASE WHEN measure='rejected' THEN value END) AS rejected
          FROM silver_mef_volume
          WHERE masterfile IN ('IMF','BMF') AND measure IN ('accepted','rejected')
          GROUP BY masterfile, period, business_date
        )
        SELECT masterfile, period, business_date, accepted, rejected,
               (accepted + rejected) AS disposed,
               100.0 * CAST(rejected AS REAL) / NULLIF(CAST(accepted + rejected AS REAL), 0) AS reject_rate_pct
        FROM ar
        """
    )
    # GOLD (a) FULL HISTORY
    c.execute(
        """
        CREATE VIEW mef_mvp_gold_volume_history AS
        SELECT masterfile, measure, description, business_date,
               MAX(CASE WHEN period='DAILY' THEN value END) AS daily_value,
               MAX(CASE WHEN period='YTD'   THEN value END) AS ytd_value
        FROM silver_mef_volume
        GROUP BY masterfile, measure, description, business_date
        """
    )
    c.execute(
        """
        CREATE VIEW mef_mvp_gold_reject_rate_history AS
        SELECT masterfile, business_date,
               MAX(CASE WHEN period='DAILY' THEN reject_rate_pct END) AS daily_reject_rate_pct,
               MAX(CASE WHEN period='YTD'   THEN reject_rate_pct END) AS ytd_reject_rate_pct
        FROM silver_mef_reject_rate
        GROUP BY masterfile, business_date
        """
    )
    # as-of resolver (single date, computed once)
    c.execute("CREATE VIEW mef_mvp_gold_as_of AS SELECT MAX(business_date) AS as_of_date FROM silver_mef_volume")
    # GOLD (b) CURRENT — source detail
    c.execute(
        """
        CREATE VIEW mef_mvp_gold_volume AS
        SELECT h.masterfile, h.measure, h.description, h.business_date AS as_of_date,
               h.daily_value, h.ytd_value, NULL AS daily_rate, NULL AS ytd_rate,
               format_number(h.daily_value, 0) AS daily_display,
               format_number(h.ytd_value, 0)   AS ytd_display
        FROM mef_mvp_gold_volume_history h
        JOIN mef_mvp_gold_as_of a ON h.business_date = a.as_of_date
        UNION ALL
        SELECT r.masterfile, 'reject_rate' AS measure,
               r.masterfile || ' Reject Rate' AS description, r.business_date AS as_of_date,
               NULL AS daily_value, NULL AS ytd_value,
               r.daily_reject_rate_pct AS daily_rate, r.ytd_reject_rate_pct AS ytd_rate,
               format_number(r.daily_reject_rate_pct, 2) || '%' AS daily_display,
               format_number(r.ytd_reject_rate_pct, 2) || '%'   AS ytd_display
        FROM mef_mvp_gold_reject_rate_history r
        JOIN mef_mvp_gold_as_of a ON r.business_date = a.as_of_date
        """
    )
    c.execute(
        """
        CREATE VIEW mef_mvp_gold_composition AS
        SELECT as_of_date, 'Federal' AS segment, 'IMF' AS component, daily_value, ytd_value
          FROM mef_mvp_gold_volume WHERE masterfile='IMF' AND measure='total'
        UNION ALL
        SELECT as_of_date, 'Federal', 'BMF', daily_value, ytd_value
          FROM mef_mvp_gold_volume WHERE masterfile='BMF' AND measure='total'
        UNION ALL
        SELECT as_of_date, 'State', 'States', daily_value, ytd_value
          FROM mef_mvp_gold_volume WHERE masterfile='TOTAL' AND measure='total_states'
        """
    )
    c.execute(
        """
        CREATE VIEW mef_mvp_gold_disposition AS
        SELECT as_of_date, masterfile, 'Accepted' AS disposition, daily_value, ytd_value
          FROM mef_mvp_gold_volume WHERE masterfile IN ('IMF','BMF') AND measure='accepted'
        UNION ALL
        SELECT as_of_date, masterfile, 'Rejected', daily_value, ytd_value
          FROM mef_mvp_gold_volume WHERE masterfile IN ('IMF','BMF') AND measure='rejected'
        """
    )
    conn.commit()


class Checker:
    def __init__(self):
        self.failures = []

    def check(self, label, got, want, tol=0):
        ok = (abs(got - want) <= tol) if tol else (got == want)
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}: got={got} want={want}"
              + (f" tol={tol}" if tol else ""))
        if not ok:
            self.failures.append(label)

    def truthy(self, label, cond, detail=""):
        print(f"  [{'PASS' if cond else 'FAIL'}] {label}{(' — ' + detail) if detail else ''}")
        if not cond:
            self.failures.append(label)


def reconcile(c, chk, rate_rows):
    print("== every view executes & returns rows ==")
    for v in ("mef_volume_source", "silver_mef_volume", "silver_mef_reject_rate",
              "mef_mvp_gold_volume_history", "mef_mvp_gold_reject_rate_history",
              "mef_mvp_gold_as_of", "mef_mvp_gold_volume",
              "mef_mvp_gold_composition", "mef_mvp_gold_disposition"):
        n = c.execute(f"SELECT COUNT(*) FROM {v}").fetchone()[0]
        chk.truthy(f"{v}: {n} rows", n > 0)

    print("== dimension-filtered tidy reconciliation to report ==")
    def volume(masterfile, measure):
        return c.execute(
            "SELECT daily_value, ytd_value, daily_rate, ytd_rate "
            "FROM mef_mvp_gold_volume WHERE masterfile=? AND measure=?",
            (masterfile, measure),
        ).fetchone()

    total = volume("TOTAL", "total_submitted")
    imf_accepted = volume("IMF", "accepted")
    bmf_accepted = volume("BMF", "accepted")
    imf_rate = volume("IMF", "reject_rate")
    bmf_rate = volume("BMF", "reject_rate")
    kpi = {
        "total_submitted_daily": total[0], "total_submitted_ytd": total[1],
        "imf_accepted_daily": imf_accepted[0], "imf_accepted_ytd": imf_accepted[1],
        "bmf_accepted_daily": bmf_accepted[0], "bmf_accepted_ytd": bmf_accepted[1],
        "imf_reject_rate_daily": imf_rate[2], "imf_reject_rate_ytd": imf_rate[3],
        "bmf_reject_rate_daily": bmf_rate[2], "bmf_reject_rate_ytd": bmf_rate[3],
    }
    chk.check("Total Submitted daily", kpi["total_submitted_daily"], 11011052)
    chk.check("Total Submitted YTD",   kpi["total_submitted_ytd"],   237936075)
    chk.check("IMF Accepted daily",    kpi["imf_accepted_daily"],    5482137)
    chk.check("IMF Accepted YTD",      kpi["imf_accepted_ytd"],      118264509)
    chk.check("BMF Accepted daily",    kpi["bmf_accepted_daily"],    903516)
    chk.check("BMF Accepted YTD",      kpi["bmf_accepted_ytd"],      26417062)

    print("== derived reject rate (percent) matches report stated rate (within rounding) ==")
    stated = {(mf, per): pct for (mf, per, _bd, pct) in rate_rows}
    chk.check("IMF reject rate daily %", round(kpi["imf_reject_rate_daily"], 2), round(stated[("IMF", "DAILY")], 2), tol=0.01)
    chk.check("IMF reject rate YTD %",   round(kpi["imf_reject_rate_ytd"], 2),   round(stated[("IMF", "YTD")], 2), tol=0.01)
    chk.check("BMF reject rate daily %", round(kpi["bmf_reject_rate_daily"], 2), round(stated[("BMF", "DAILY")], 2), tol=0.01)
    chk.check("BMF reject rate YTD %",   round(kpi["bmf_reject_rate_ytd"], 2),   round(stated[("BMF", "YTD")], 2), tol=0.01)
    print(f"    IMF YTD derived = {kpi['imf_reject_rate_ytd']:.4f}%  (= 14,180,337 / 132,444,846 * 100)")

    print("== internal consistency (fed = imf + bmf) ==")
    row = c.execute(
        "SELECT "
        "(SELECT daily_value FROM mef_mvp_gold_volume WHERE masterfile='TOTAL' AND measure='total_fed'),"
        "(SELECT daily_value FROM mef_mvp_gold_volume WHERE masterfile='IMF' AND measure='total'),"
        "(SELECT daily_value FROM mef_mvp_gold_volume WHERE masterfile='BMF' AND measure='total')"
    ).fetchone()
    chk.check("Total Fed daily == IMF total + BMF total", row[1] + row[2], row[0])

    print("== detail-table display columns: zero nulls + correct formatting ==")
    # Every row must have exactly one non-null Daily and one non-null YTD string.
    nulls = c.execute(
        "SELECT COUNT(*) FROM mef_mvp_gold_volume "
        "WHERE daily_display IS NULL OR ytd_display IS NULL"
    ).fetchone()[0]
    chk.check("detail-table Daily/YTD display columns have zero nulls", nulls, 0)
    total_rows = c.execute("SELECT COUNT(*) FROM mef_mvp_gold_volume").fetchone()[0]
    chk.truthy(f"detail table has rows to display ({total_rows})", total_rows > 0)

    # a count row formats with thousands separators, no decimals
    ts = c.execute(
        "SELECT daily_display, ytd_display FROM mef_mvp_gold_volume "
        "WHERE masterfile='TOTAL' AND measure='total_submitted'"
    ).fetchone()
    chk.truthy("Total Submitted Daily formats as 11,011,052", ts[0] == "11,011,052", f"got={ts[0]}")
    chk.truthy("Total Submitted YTD formats as 237,936,075", ts[1] == "237,936,075", f"got={ts[1]}")

    # a rate row formats as a 2-decimal percent with '%'
    imf = c.execute(
        "SELECT daily_display, ytd_display FROM mef_mvp_gold_volume "
        "WHERE masterfile='IMF' AND measure='reject_rate'"
    ).fetchone()
    chk.truthy("IMF Reject Rate Daily formats as 10.06%", imf[0] == "10.06%", f"got={imf[0]}")
    chk.truthy("IMF Reject Rate YTD formats as 10.71%", imf[1] == "10.71%", f"got={imf[1]}")


def main():
    vol_rows, rate_rows, seed_as_of = parse_seed(SEED_SQL)
    chk = Checker()

    # ---- Pass 1: single-date (the committed seed) — the original 13 checks ----
    print("################ PASS 1 — single-date seed (report reconciliation) ################")
    conn = sqlite3.connect(":memory:")
    build(conn, vol_rows)
    reconcile(conn.cursor(), chk, rate_rows)
    conn.close()

    # ---- Pass 2: MULTI-DATE fixture (BLOCKING 2), harness-only synthetic day ----
    print("\n################ PASS 2 — multi-date fixture (no cross-snapshot mixing) ################")
    # Inject a synthetic EARLIER day (the seed's as-of date minus one day) with
    # DIFFERENT, smaller values, so if any current-tile leaked across dates it
    # would show a wrong (mixed) number. Dates derive from the seed; no literals.
    OLD_DATE = seed_as_of
    NEW_DATE = (date.fromisoformat(OLD_DATE) - timedelta(days=1)).isoformat()
    synthetic = []
    for (mf, meas, desc, period, bdate, val) in vol_rows:
        if bdate == OLD_DATE:
            # halve the value on the earlier day (distinct, deterministic)
            synthetic.append((mf, meas, desc, period, NEW_DATE, val // 2))
    multi_rows = vol_rows + synthetic

    conn2 = sqlite3.connect(":memory:")
    build(conn2, multi_rows)
    c2 = conn2.cursor()

    # as-of resolves to the LATEST date, once
    asof = c2.execute("SELECT as_of_date FROM mef_mvp_gold_as_of").fetchone()[0]
    chk.check("as-of resolves to single latest date", asof, OLD_DATE)

    # full history keeps BOTH days
    dates = sorted(r[0] for r in c2.execute("SELECT DISTINCT business_date FROM mef_mvp_gold_volume_history"))
    chk.truthy("full-history view keeps both snapshot days", dates == [NEW_DATE, OLD_DATE], f"dates={dates}")

    # CURRENT views show ONLY the latest date
    cur_dates = [r[0] for r in c2.execute("SELECT DISTINCT as_of_date FROM mef_mvp_gold_volume")]
    chk.truthy("current source-detail shows only latest date", cur_dates == [OLD_DATE], f"dates={cur_dates}")
    # counter datasets filter the tidy current view and show the LATEST value,
    # never a mix/sum across the two days.
    ts_daily = c2.execute(
        "SELECT daily_value FROM mef_mvp_gold_volume "
        "WHERE masterfile='TOTAL' AND measure='total_submitted'"
    ).fetchone()[0]
    chk.check("Total Submitted counter == latest day only (not summed/mixed)", ts_daily, 11011052)
    # and the earlier day's value is present in history but absent from current
    hist_new = c2.execute(
        "SELECT daily_value FROM mef_mvp_gold_volume_history "
        "WHERE masterfile='TOTAL' AND measure='total_submitted' AND business_date=?", (NEW_DATE,)
    ).fetchone()[0]
    chk.check("history retains earlier-day value (5505526)", hist_new, 11011052 // 2)
    # every current row is exactly the latest date (no row from the earlier day)
    leaked = c2.execute("SELECT COUNT(*) FROM mef_mvp_gold_volume WHERE as_of_date <> ?", (OLD_DATE,)).fetchone()[0]
    chk.check("zero current rows from a non-latest date", leaked, 0)
    conn2.close()

    print()
    if chk.failures:
        print(f"RESULT: FAIL ({len(chk.failures)} check(s)): {chk.failures}")
        sys.exit(1)
    print("RESULT: PASS — single-date reconciles 1:1 to the report AND multi-date "
          "keeps full history while current tiles show only the latest snapshot.")


if __name__ == "__main__":
    main()
