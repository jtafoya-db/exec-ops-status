# MEF Volume — medallion pipeline + AI/BI dashboard

A portable [Declarative Automation Bundle](https://docs.databricks.com/dev-tools/bundles/)
(formerly Databricks Asset Bundles) that builds an **MEF / e-File volume** reporting model
and dashboard on Databricks:

- **Medallion pipeline** — a job (`resources/mef_volume.job.yml`) runs the notebook
  `src/build_mef_volume_medallion_nb.ipynb`, which executes `sql/mef_volume/`
  in order: seed → silver → gold.
- **AI/BI dashboard** — `src/mef_volume.lvdash.json`, deployed by
  `resources/mef_volume.dashboard.yml`, reads the gold tables.
- **Optional Databricks App** — `optional/exec-ops-status/` is a prebuilt,
  dependency-free Node app that embeds the dashboard. The dashboard works on its own
  without it.

> **The seed data is synthetic sample data.** It exists only so the dashboard renders
> end-to-end. It does not describe any real organization, system, or filing season.
> `docs/DATA-CONTRACT.md` describes the shape real data must take to replace it.

## Quick start

Requirements: the [Databricks CLI](https://docs.databricks.com/dev-tools/cli/install.html),
a workspace with Unity Catalog, a catalog/schema you can write to, and a SQL warehouse.

```bash
databricks bundle validate -t handoff -p <profile> \
  --var catalog=<catalog> --var schema=<schema> --var warehouse_id=<warehouse_id>
databricks bundle deploy   -t handoff -p <profile> \
  --var catalog=<catalog> --var schema=<schema> --var warehouse_id=<warehouse_id>
databricks bundle run build_mef_volume_medallion -t handoff -p <profile> \
  --var catalog=<catalog> --var schema=<schema> --var warehouse_id=<warehouse_id>
```

See **[HANDOFF.md](HANDOFF.md)** for the full walkthrough (deploy, build the data, open
the dashboard, swap in real data, and the optional embed app), and
[docs/MEF-VOLUME-PATHWAY.md](docs/MEF-VOLUME-PATHWAY.md) for how each KPI flows from
source to dashboard.

## Repository layout

| Path | What it is |
|---|---|
| `databricks.yml` | Bundle definition: one `handoff` target; catalog/schema/warehouse are required vars |
| `resources/` | The medallion job and dashboard resources |
| `src/` | The medallion notebook and the dashboard definition |
| `sql/mef_volume/` | Seed, silver, and gold SQL, plus `validate_local.py` |
| `docs/` | Data contract and pipeline pathway |
| `optional/exec-ops-status/` | Optional dashboard-embed Databricks App |

## License

© 2026 Databricks, Inc. All rights reserved. The source in this repository is provided
subject to the [Databricks License](LICENSE). Third-party components are acknowledged in
[NOTICE](NOTICE). See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
