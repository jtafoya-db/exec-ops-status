# optional/ — bonus Databricks App (not required for the dashboard)

The MEF Volume dashboard is the deliverable; **this app is optional.** It embeds the
dashboard inside the executive-agenda shell. The dashboard works fully on its own
without ever deploying this app.

`exec-ops-status/` ships a prebuilt frontend (`dist/`) and a dependency-free Node server
(`server.mjs`, Node built-ins only) with **no `package.json`**, so the Databricks Apps
runtime performs no `npm install`. See the "Optional: embed app" appendix in ../HANDOFF.md.
