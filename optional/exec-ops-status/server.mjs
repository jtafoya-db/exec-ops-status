import { createHmac } from "node:crypto";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const port = Number(process.env.DATABRICKS_APP_PORT || process.env.PORT || 8000);

// All workspace-specific config comes from the environment — nothing is baked in, so the
// same build runs in any workspace (including an air-gapped one). DATABRICKS_HOST is
// auto-injected by the Databricks Apps runtime; DATABRICKS_WORKSPACE_ID and DASHBOARD_ID
// are set in app.yaml (see HANDOFF.md). We fail loudly at startup if any are missing
// rather than silently pointing at someone else's workspace.
const required = {
  DATABRICKS_HOST: process.env.DATABRICKS_HOST,
  DATABRICKS_WORKSPACE_ID: process.env.DATABRICKS_WORKSPACE_ID,
  DASHBOARD_ID: process.env.DASHBOARD_ID,
};
const missing = Object.entries(required)
  .filter(([, value]) => !value || !String(value).trim())
  .map(([name]) => name);
if (missing.length > 0) {
  console.error(
    `[exec-ops-status] Missing required environment: ${missing.join(", ")}. ` +
      `Set these on the app (DATABRICKS_HOST is auto-injected in Databricks Apps; ` +
      `DATABRICKS_WORKSPACE_ID and DASHBOARD_ID come from app.yaml). See HANDOFF.md.`,
  );
  process.exit(1);
}

// The Databricks Apps runtime injects DATABRICKS_HOST as a bare hostname (no scheme);
// a manually-set value may include https://. Normalize to a scheme-qualified origin so
// URL parsing (token exchange) works in every workspace.
const rawHost = required.DATABRICKS_HOST.trim().replace(/\/$/, "");
const host = /^https?:\/\//i.test(rawHost) ? rawHost : `https://${rawHost}`;
const workspaceId = required.DATABRICKS_WORKSPACE_ID;
const dashboardId = required.DASHBOARD_ID;
const clientId = process.env.DATABRICKS_CLIENT_ID;
const clientSecret = process.env.DATABRICKS_CLIENT_SECRET;
const tokenUrl = `${host}/oidc/v1/token?o=${workspaceId}`;
// Optional server-side key: when set, the per-user external_viewer_id is an HMAC of the
// SCIM user id instead of the raw id. Never sent to the browser.
const viewerIdHmacKey = process.env.VIEWER_ID_HMAC_KEY;
// Fixed, non-PII viewer id used when no user token is forwarded (user authorization not
// enabled, or local dev). The dashboard still renders; only attribution is degraded.
const anonymousViewerId = "exec-ops-status-anon";

// Node header values may be string | string[] | undefined, and duplicate headers are
// comma-joined in request.headers. Take a single value (headersDistinct keeps duplicates
// apart), cut at any comma, and treat empty as missing so the Bearer value is one token.
function readForwardedToken(request) {
  const name = "x-forwarded-access-token";
  const raw = request.headersDistinct?.[name] ?? request.headers[name];
  const value = (Array.isArray(raw) ? raw[0] : raw) || "";
  return value.split(",")[0].trim() || null;
}

function scimMeError(message) {
  return Object.assign(new Error(message), { reason: "scim-me-failed" });
}

// On-behalf-of-user identity, for ATTRIBUTION ONLY. With user authorization enabled, the
// Apps proxy forwards the signed-in user's token in x-forwarded-access-token; we use it
// solely to call SCIM /Me (allowed by the default iam.current-user:read scope). Queries
// still run as the service principal / publisher via the embed token below.
async function resolveViewer(request) {
  const userToken = readForwardedToken(request);
  if (!userToken) return null;
  const meUrl = new URL(`${host}/api/2.0/preview/scim/v2/Me`);
  meUrl.searchParams.set("o", workspaceId);
  const response = await fetch(meUrl, { headers: { authorization: `Bearer ${userToken}` } });
  if (!response.ok) throw scimMeError(`SCIM /Me failed (${response.status})`);
  const me = await response.json();
  if (!me.id) throw scimMeError("SCIM /Me returned no user id");
  const userId = String(me.id);
  // external_viewer_id lands in dashboard audit logs and must not contain PII, so it is
  // derived from the opaque SCIM id only — never the email/userName.
  const viewerId = viewerIdHmacKey
    ? createHmac("sha256", viewerIdHmacKey).update(userId).digest("hex")
    : userId;
  return { userId, userName: me.userName || me.emails?.[0]?.value || null, viewerId: viewerId.slice(0, 128) };
}

async function requestBroadToken() {
  const response = await fetch(tokenUrl, {
    method: "POST",
    headers: {
      authorization: `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString("base64")}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ grant_type: "client_credentials", scope: "all-apis" }),
  });
  console.log(JSON.stringify({ event: "embed-token-exchange", step: "broad-token", status: response.status }));
  if (!response.ok) throw new Error(`Broad token request failed (${response.status})`);
  return (await response.json()).access_token;
}

async function requestScopedToken(externalViewerId) {
  if (!clientId || !clientSecret) throw new Error("Managed service-principal credentials are unavailable");
  const broadToken = await requestBroadToken();
  const infoUrl = new URL(`${host}/api/2.0/lakeview/dashboards/${dashboardId}/published/tokeninfo`);
  infoUrl.searchParams.set("o", workspaceId);
  infoUrl.searchParams.set("external_viewer_id", externalViewerId);
  const infoResponse = await fetch(infoUrl, { headers: { authorization: `Bearer ${broadToken}` } });
  console.log(JSON.stringify({ event: "embed-token-exchange", step: "published-tokeninfo", status: infoResponse.status }));
  if (!infoResponse.ok) throw new Error(`published/tokeninfo failed (${infoResponse.status})`);

  const tokenInfo = await infoResponse.json();
  const { authorization_details: authorizationDetails, ...tokenParams } = tokenInfo;
  const response = await fetch(tokenUrl, {
    method: "POST",
    headers: {
      authorization: `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString("base64")}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      ...tokenParams,
      authorization_details: JSON.stringify(authorizationDetails),
    }),
  });
  console.log(JSON.stringify({ event: "embed-token-exchange", step: "scoped-token", status: response.status }));
  if (!response.ok) throw new Error(`Scoped token request failed (${response.status})`);
  return (await response.json()).access_token;
}

const dist = path.join(path.dirname(fileURLToPath(import.meta.url)), "dist");

function sendJson(response, statusCode, body) {
  response.writeHead(statusCode, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify(body));
}

createServer(async (request, response) => {
  const url = new URL(request.url || "/", "http://localhost");
  if (url.pathname === "/api/config") {
    // Public, non-secret runtime config for the browser bundle. The service-principal
    // client id/secret are never sent to the client.
    return sendJson(response, 200, {
      instanceUrl: host,
      workspaceId,
      dashboardId,
    });
  }
  if (url.pathname === "/api/embed-token") {
    try {
      // Every degraded-attribution case logs one embed-token-no-obo line with a reason:
      // no-forwarded-token | scim-me-failed (non-2xx / no id) | obo-error (anything else).
      let viewer = null;
      let degraded = { reason: "no-forwarded-token" };
      try {
        viewer = await resolveViewer(request);
      } catch (error) {
        degraded = { reason: error.reason || "obo-error", message: error.message };
      }
      // Opaque and non-PII. The viewer id is stable per user, so SDK refreshes stay bound
      // to the same viewer while each request mints a new token.
      const viewerId = viewer ? viewer.viewerId : anonymousViewerId;
      const token = await requestScopedToken(viewerId);
      // App audit trail: the real identity stays server-side in the app log only.
      console.log(
        JSON.stringify(
          viewer
            ? { event: "embed-token-issued", user_id: viewer.userId, user_name: viewer.userName, viewer_id: viewerId, ts: new Date().toISOString() }
            : { event: "embed-token-no-obo", ...degraded, viewer_id: viewerId, ts: new Date().toISOString() },
        ),
      );
      sendJson(response, 200, { token });
    } catch (error) {
      console.error(JSON.stringify({ event: "embed-token-error", message: error.message }));
      sendJson(response, 502, { error: error.message });
    }
    return;
  }
  if (url.pathname === "/api/health") return sendJson(response, 200, { status: "ok" });

  let file = path.join(dist, url.pathname === "/" ? "index.html" : url.pathname);
  if (!file.startsWith(dist)) file = path.join(dist, "index.html");
  try {
    if (!(await stat(file)).isFile()) throw new Error("not a file");
  } catch {
    file = path.join(dist, "index.html");
  }
  const type = file.endsWith(".js") ? "text/javascript" : file.endsWith(".css") ? "text/css" : "text/html";
  response.writeHead(200, { "content-type": type });
  createReadStream(file).pipe(response);
}).listen(port, "0.0.0.0", () => console.log(`Executive Operations Status listening on ${port}`));
