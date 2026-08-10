import { createServer } from "node:http";
import { chmodSync, copyFileSync, readFileSync } from "node:fs";
copyFileSync("/test/openpay_admin.htpasswd", "/output/openpay_admin_htpasswd");
chmodSync("/output/openpay_admin_htpasswd", 0o444);
const identity = { build: "test", contract_version: "1", implementation: "go", adapter: "sqlite", migration_revision: "0001" };
const expectedBackendToken = process.env.EXPECTED_BACKEND_TOKEN;
if (expectedBackendToken === undefined || expectedBackendToken.length === 0) {
  throw new Error("EXPECTED_BACKEND_TOKEN is required for fake upstream.");
}
const expectedAdminUser = process.env.EXPECTED_ADMIN_USER;
if (expectedAdminUser === undefined || expectedAdminUser.length === 0) {
  throw new Error("EXPECTED_ADMIN_USER is required for fake upstream.");
}
let proxyObservation = { authorization_scheme: "none", admin_user: null };
const operationalPaths = new Set();
let operationalAuthorizationSeen = false;
let operationalAdminUserSeen = false;
const observeProxyIdentity = (request) => {
  const authorization = request.headers.authorization;
  let authorizationScheme = "none";
  if (authorization?.startsWith("Bearer ")) {
    authorizationScheme = "bearer";
  } else if (authorization?.startsWith("Basic ")) {
    authorizationScheme = "basic";
  } else if (authorization !== undefined) {
    authorizationScheme = "other";
  }
  proxyObservation = {
    authorization_scheme: authorizationScheme,
    admin_user: request.headers["x-openpay-admin-user"] ?? null
  };
};
const hasProxyIdentity = (request) => {
  observeProxyIdentity(request);
  return request.headers.authorization === `Bearer ${expectedBackendToken}`
    && request.headers["x-openpay-admin-user"] === expectedAdminUser;
};
const operationalRequestHasCredentials = (request) => {
  operationalPaths.add(request.url ?? "missing");
  if (request.headers.authorization !== undefined) {
    operationalAuthorizationSeen = true;
  }
  if (request.headers["x-openpay-admin-user"] !== undefined) {
    operationalAdminUserSeen = true;
  }
  return request.headers.authorization !== undefined
    || request.headers["x-openpay-admin-user"] !== undefined;
};
const rejectOperationalCredentials = (request, response) => {
  if (!operationalRequestHasCredentials(request)) {
    return false;
  }
  response.writeHead(400, { "content-type": "application/problem+json", "cache-control": "no-store" });
  response.end(JSON.stringify({ title: "operational credentials rejected", status: 400 }));
  return true;
};
const readiness = { datastore: "ok", migration: "current", topology: "supported", projection: "healthy", write_admission: "open", contract_version: "1", implementation: "go", adapter: "sqlite", migration_revision: "0001" };
let mode = "ready";
let analyticsMode = "fixture";
const analyticsFixture = JSON.parse(readFileSync("/fixture/sales-analytics-response.valid.json", "utf8"));
const analyticsEtag = analyticsFixture.etag;
const responseForQuery = (requestUrl) => {
  const parsed = new URL(requestUrl, "http://upstream");
  const from = parsed.searchParams.get("from");
  const to = parsed.searchParams.get("to");
  const snapshotAt = parsed.searchParams.get("snapshot_at");
  const timeZone = parsed.searchParams.get("time_zone");
  if (from === null || to === null || snapshotAt === null || timeZone === null) {
    return undefined;
  }
  const duration = Date.parse(to) - Date.parse(from);
  if (!Number.isFinite(duration) || duration <= 0) {
    return undefined;
  }
  const projection = structuredClone(analyticsFixture);
  projection.snapshot_at = snapshotAt;
  projection.observed_at = snapshotAt;
  projection.time_zone = timeZone;
  projection.current = { ...projection.current, from, to };
  projection.comparison = {
    ...projection.comparison,
    from: new Date(Date.parse(from) - duration).toISOString().replace(".000Z", "Z"),
    to: from
  };
  projection.series = [{ ...projection.current }];
  projection.sync.last_received_at = new Date(Date.parse(snapshotAt) - Number(projection.sync.freshness_seconds) * 1_000).toISOString().replace(".000Z", "Z");
  return JSON.stringify(projection);
};
const pendingReadiness = new Set();
const writeDegradedReadiness = (response) => {
  response.writeHead(503, { "content-type": "application/json" });
  response.end(JSON.stringify({ ...readiness, datastore: "failed", write_admission: "closed" }));
};
createServer((request, response) => {
  if (request.method === "GET" && request.url === "/__proxy-observation") {
    response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    response.end(JSON.stringify(proxyObservation));
    return;
  }
  if (request.method === "GET" && request.url === "/__operations-observation") {
    response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    response.end(JSON.stringify({
      paths: [...operationalPaths].sort(),
      authorization_seen: operationalAuthorizationSeen,
      admin_user_seen: operationalAdminUserSeen
    }));
    return;
  }
  if (request.method === "POST" && request.url?.startsWith("/__analytics/")) {
    const requestedMode = request.url.slice("/__analytics/".length);
    if (requestedMode !== "fixture" && requestedMode !== "error") {
      response.writeHead(422);
      response.end();
      return;
    }
    analyticsMode = requestedMode;
    response.writeHead(204);
    response.end();
    return;
  }
  if (request.method === "POST" && request.url?.startsWith("/__mode/")) {
    const requestedMode = request.url.slice("/__mode/".length);
    if (requestedMode !== "ready" && requestedMode !== "degraded" && requestedMode !== "hang") {
      response.writeHead(422);
      response.end();
      return;
    }
    mode = requestedMode;
    if (mode === "degraded") {
      for (const pendingResponse of pendingReadiness) {
        writeDegradedReadiness(pendingResponse);
      }
      pendingReadiness.clear();
    }
    response.writeHead(204);
    response.end();
    return;
  }
  if (request.url === "/healthz") {
    if (rejectOperationalCredentials(request, response)) {
      return;
    }
    response.writeHead(200, { "content-type": "text/plain" });
    response.end("backend-ok");
    return;
  }
  if (request.url === "/v1/session/bootstrap") {
    if (!hasProxyIdentity(request)) {
      response.writeHead(401, { "content-type": "application/problem+json", "cache-control": "private, no-store", vary: "Authorization" });
      response.end(JSON.stringify({ title: "authentication required", status: 401 }));
      return;
    }
    response.writeHead(200, { "content-type": "application/json", "cache-control": "private, no-store", vary: "Authorization" });
    response.end(JSON.stringify({ tenant_id: "tenant-demo", session_cache_id: "browser-session-1" }));
    return;
  }
  if (request.url === "/version") {
    if (rejectOperationalCredentials(request, response)) {
      return;
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(identity));
    return;
  }
  if (request.url === "/readyz" && rejectOperationalCredentials(request, response)) {
    return;
  }
  if (request.url === "/readyz" && mode === "hang") {
    pendingReadiness.add(response);
    request.once("close", () => pendingReadiness.delete(response));
    return;
  }
  if (request.url === "/readyz" && mode === "degraded") {
    writeDegradedReadiness(response);
    return;
  }
  if (request.url === "/readyz") { response.writeHead(200, { "content-type": "application/json" }); response.end(JSON.stringify(readiness)); return; }
  if (request.url?.startsWith("/v1/analytics/sales")) {
    if (!hasProxyIdentity(request)) {
      response.writeHead(401, { "content-type": "application/problem+json", "cache-control": "no-store" });
      response.end(JSON.stringify({ title: "authentication required", status: 401 }));
      return;
    }
    if (analyticsMode === "error") {
      response.writeHead(503, { "content-type": "application/problem+json", "cache-control": "no-store" });
      response.end(JSON.stringify({ title: "projection unavailable", status: 503 }));
      return;
    }
    const responseHeaders = { etag: analyticsEtag, "cache-control": "private, max-age=30, must-revalidate", vary: "Authorization" };
    if (request.headers["if-none-match"] === analyticsEtag) {
      response.writeHead(304, responseHeaders);
      response.end();
      return;
    }
    const responseBody = responseForQuery(request.url);
    if (responseBody === undefined) {
      response.writeHead(422, { "content-type": "application/problem+json", "cache-control": "no-store" });
      response.end(JSON.stringify({ title: "invalid analytics query", status: 422 }));
      return;
    }
    response.writeHead(200, { ...responseHeaders, "content-type": "application/json" });
    response.end(responseBody);
    return;
  }
  response.writeHead(404); response.end();
}).listen(9090, "0.0.0.0");
