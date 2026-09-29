# MEF Volume — Handoff

A slim, self-contained Databricks Asset Bundle for the **MEF Volume dashboard** and the
job that builds its data. It deploys into **any** Databricks workspace (including
air-gapped) — nothing about the origin workspace is baked in, there is **no Python wheel
artifact** to build, and you supply the catalog / schema / warehouse as `--var`s.

The dashboard is the deliverable. The embed app is an optional bonus (see the appendix).

---

## 1. Unzip and authenticate

```sh
unzip mef-volume-handoff-<sha>.zip
cd mef-volume-handoff

databricks auth login --host https://<your-workspace-host> --profile <profile>
databricks current-user me -p <profile>   # sanity check
```

The bundle's only target, `handoff`, pins **no host** — it uses the host of `-p <profile>`.

## 2. Deploy and build the data

`catalog`, `schema`, and `warehouse_id` are required (no defaults). Point `warehouse_id`
at a running SQL warehouse.

```sh
# validate
databricks bundle validate -t handoff -p <profile> \
  --var catalog=<catalog> --var schema=<schema> --var warehouse_id=<warehouse_id>

# deploy (creates the dashboard + the medallion job; runs no SQL yet)
databricks bundle deploy -t handoff -p <profile> \
  --var catalog=<catalog> --var schema=<schema> --var warehouse_id=<warehouse_id>

# REQUIRED: build the data (seed -> silver -> gold). The dashboard does not render
# until this runs. Idempotent — safe to re-run.
databricks bundle run build_mef_volume_medallion -t handoff -p <profile> \
  --var catalog=<catalog> --var schema=<schema> --var warehouse_id=<warehouse_id>
```

> `handoff` is the default target, so `-t handoff` and omitting `-t` are equivalent.

## 3. Open the dashboard

```sh
databricks lakeview list -p <profile> --output json \
  | jq -r '.[] | select(.display_name | startswith("MEF Volume")) | "\(.display_name)\t\(.dashboard_id)"'
```

Open it in the workspace UI. On the (synthetic) seed data, **Total Submitted (YTD) = 237,936,075** —
that is your reconciliation check that the build succeeded.

---

# DATA CONTRACT — how real MeF data goes in

The dashboard ships on **seed** data. To show **real** data, land rows in the shape below
into the view **`mef_volume_source`** (the single swap seam in
`sql/mef_volume/10_silver.sql`), then re-run the build job. **Nothing downstream changes** —
silver, gold, and the dashboard all read this contract, never your raw table.

### The six-column shape (`mef_volume_source`)

| Column | Type | Meaning |
| --- | --- | --- |
| `masterfile` | `STRING` | File family / aggregate: `IMF`, `BMF`, `TOTAL` (`STATE` reserved for future detail rows). |
| `measure` | `STRING` | Machine-readable measure key (see allowed values). **New measures are new rows, never new columns.** |
| `description` | `STRING` | Human label for the detail table, e.g. `IMF Accepted`. Stable within a measure. |
| `period` | `STRING` | `DAILY` (value on `business_date`) or `YTD` (season-to-date as of `business_date`). |
| `business_date` | `DATE` | Snapshot/as-of date. Load both `DAILY` and `YTD` against the same date; later snapshots add a new date, they don't replace history. |
| `value` | `BIGINT` | Integer count. Not formatted text, not a percentage, not mixed units. |

**Grain:** one row per `(masterfile, measure, period, business_date)` — each key unique.

### Allowed dimension values

| `masterfile` | `measure` | Meaning |
| --- | --- | --- |
| `TOTAL` | `total_submitted` | All federal + state submissions |
| `TOTAL` | `total_fed` | Federal (IMF + BMF) |
| `TOTAL` | `total_states` | State submissions |
| `IMF` | `total` | Total IMF |
| `IMF` | `accepted` | Accepted IMF |
| `IMF` | `rejected` | Rejected IMF |
| `IMF` | `imf_state` | IMF state submissions (when supplied) |
| `BMF` | `total` | Total BMF |
| `BMF` | `accepted` | Accepted BMF |
| `BMF` | `rejected` | Rejected BMF |
| `BMF` | `bmf_state` | BMF state submissions (when supplied) |

Minimum for a snapshot: `total_submitted`, `total_fed`, `total_states`, and `total` +
`accepted` + `rejected` for both `IMF` and `BMF`. Preserve exact spelling/case.

**Do NOT** supply reject-rate or KPI columns — they are derived
(`rejected / (accepted + rejected) * 100`). Emit **separate rows for `DAILY` and `YTD`**;
never pivot measures into columns. Sanity relationships:
`total_submitted = total_fed + total_states`; `total_fed = IMF total + BMF total`;
per masterfile/period `total = accepted + rejected`.

### Paste-ready Genie Code prompt (reshape real data → contract)

Open a Genie Code / notebook cell against your real MeF table and paste:

```text
I have a real MeF submission table at <catalog>.<schema>.<your_real_table>. I need to
reshape it into a tidy view named `mef_volume_source` with EXACTLY these six columns and
types, one typed observation per row (no pivoting, no derived rates):

  masterfile    STRING   -- one of 'IMF','BMF','TOTAL' (map my file-type column onto these)
  measure       STRING   -- one of: total_submitted, total_fed, total_states (for TOTAL);
                          --         total, accepted, rejected (for IMF and BMF)
  description   STRING    -- human label, e.g. 'IMF Accepted'
  period        STRING    -- 'DAILY' or 'YTD' (emit BOTH as separate rows)
  business_date DATE      -- the snapshot / as-of date
  value         BIGINT    -- integer count only

Rules:
- Grain is one row per (masterfile, measure, period, business_date); keep it unique.
- Do NOT compute reject rate or any KPI column — the medallion derives those.
- Emit separate DAILY and YTD rows against the same business_date.
- Preserve the exact measure spellings above; map my source labels onto them.
- Keep totals consistent: total_submitted = total_fed + total_states,
  total_fed = IMF.total + BMF.total, and per masterfile/period total = accepted + rejected.

Generate a single `CREATE OR REPLACE VIEW mef_volume_source AS SELECT ... FROM
<catalog>.<schema>.<your_real_table>` that produces this shape, aliasing my real columns
onto the six contract columns.
```

Put the resulting `CREATE OR REPLACE VIEW mef_volume_source ...` into
`sql/mef_volume/10_silver.sql` in place of the seed-backed definition (it is clearly marked
there), then **re-run the build**:

```sh
databricks bundle run build_mef_volume_medallion -p <profile> \
  --var catalog=<catalog> --var schema=<schema> --var warehouse_id=<warehouse_id>
```

Full walkthrough with the exact edit location: `docs/MEF-VOLUME-PATHWAY.md`.
Local validation of the contract without a workspace: `sql/mef_volume/validate_local.py`.

---

## Appendix — optional: the embed app

The dashboard stands alone; deploy this only if you want the executive-agenda embed.
Files are under `optional/exec-ops-status/` (prebuilt, dependency-free, **no `package.json`**
so the Apps runtime runs no `npm install`).

1. **Publish the dashboard with embedded credentials** (the embed needs this):
   ```sh
   DASHBOARD_ID=$(databricks lakeview list -p <profile> --output json \
     | jq -r '.[]|select(.display_name|startswith("MEF Volume"))|.dashboard_id')
   databricks lakeview publish "$DASHBOARD_ID" --embed-credentials -p <profile>
   ```
   **Re-publish after every `bundle deploy`** — a redeploy resets published state, and the
   embed 401/403s until you re-publish. (API equivalent:
   `POST /api/2.0/lakeview/dashboards/$DASHBOARD_ID/published` with
   `{"embed_credentials": true, "warehouse_id": "<warehouse_id>"}`.)

2. **Create + deploy the app**, setting env in `optional/exec-ops-status/app.yaml`
   (replace `REPLACE_WITH_*`; `DATABRICKS_HOST` is auto-injected by the Apps runtime):
   - `DATABRICKS_WORKSPACE_ID` = your numeric workspace id (the `o=` value)
   - `DASHBOARD_ID` = the id from step 1
   ```sh
   cd optional/exec-ops-status
   databricks apps create exec-ops-status -p <profile>
   DEST="/Workspace/Users/$(databricks current-user me -p <profile> | jq -r .userName)/exec-ops-status"
   databricks sync . "$DEST" -p <profile>
   databricks apps deploy exec-ops-status --source-code-path "$DEST" -p <profile>
   ```

3. **Grant the app's service principal** access. A new app gets a brand-new service
   principal with no access to anything, so this step is required every time the app is
   (re)created, not only the first time:
   ```sh
   SP=$(databricks apps get exec-ops-status -p <profile> --output json | jq -r .service_principal_client_id)
   # CAN RUN on the published dashboard
   databricks lakeview set-permissions "$DASHBOARD_ID" -p <profile> --json \
     '{"access_control_list":[{"service_principal_name":"'"$SP"'","permission_level":"CAN_RUN"}]}'
   # CAN USE on the dashboard's SQL warehouse
   WAREHOUSE_ID=$(databricks lakeview get "$DASHBOARD_ID" -p <profile> --output json | jq -r .warehouse_id)
   databricks warehouses update-permissions "$WAREHOUSE_ID" -p <profile> --json \
     '{"access_control_list":[{"service_principal_name":"'"$SP"'","permission_level":"CAN_USE"}]}'
   # SELECT on the gold schema (run in a SQL editor if your CLI lacks `sql query`):
   #   GRANT SELECT ON SCHEMA <catalog>.<schema> TO `<SP>`;
   ```

4. **Enable user authorization for viewer attribution** (recommended; the app still
   renders without it, but every viewer is logged as `exec-ops-status-anon`):
   ```sh
   databricks apps create-update exec-ops-status -p <profile> --json \
     '{"update_mask":"user_api_scopes","app":{"user_api_scopes":["iam.current-user:read","iam.access-control:read"]}}'
   ```
   (Or: Edit app → User authorization, with no extra scopes; Databricks assigns these two
   by default.) `user_api_scopes` is an app setting, not an `app.yaml` key. The app reads
   the viewer's `x-forwarded-access-token` **only** to call SCIM `/Me`. It passes the
   opaque, non-PII SCIM user id (HMAC'd if `VIEWER_ID_HMAC_KEY` is set) as
   `external_viewer_id`, and logs `{"event":"embed-token-issued","user_id",...,"user_name",...}`
   to the app log for audit. Queries still run as the publisher / SP, so steps 1 and 3
   (published with embedded credentials, SP has CAN RUN) are still required. Viewers need
   no extra dashboard grant; access to the app is the gate.

5. Open the app URL from `databricks apps get exec-ops-status -p <profile>`; confirm
   `GET /api/config` and `GET /api/embed-token` return 200 and the widgets render. In the
   app logs, expect `embed-token-issued` with your user (or `embed-token-no-obo` if user
   authorization is off).

### Troubleshooting the embed

Read the app log with `databricks apps logs exec-ops-status -p <profile>`. The browser
console shows the same failures as `Lakeview page mef_volume unavailable: ...`.

| Symptom | Cause | Fix |
|---|---|---|
| `published/tokeninfo failed (404)`, `/api/embed-token` returns 502 | The app's service principal can't see the dashboard. The workspace reports a dashboard you have no access to as "not found". Usual after creating a new app. | Step 3: grant the SP CAN RUN on the dashboard and CAN USE on the warehouse. |
| Same 404, SP already granted | The dashboard is published without embedded credentials, often because a `bundle deploy` republished it. Check with `databricks lakeview get-published "$DASHBOARD_ID" -p <profile>`; look for `"embed_credentials": true`. | Step 1: re-publish with `--embed-credentials`. |
| Works for you with your own token but not in the app | The app calls Databricks as its service principal, not as you, so a working `curl` with your token proves nothing about the SP. | Step 3. |
| Log shows `embed-token-no-obo` with `reason: no-forwarded-token` | User authorization is off. The dashboard still renders, but viewers aren't identified. | Step 4. |
| Log shows `embed-token-no-obo` with `reason: scim-me-failed` | The user token can't call SCIM `/Me`. | Check the app's `effective_user_api_scopes` (`databricks apps get`) include `iam.current-user:read`. |
| Page loads but still shows an old error after a fix | The browser cached the failed token. | Hard-reload (Cmd-Shift-R). |

A new app can't take over an old app's name or permissions: Databricks Apps can't be
renamed, and each app has its own service principal. Moving to a new app name means
steps 2–4 again for the new app.
