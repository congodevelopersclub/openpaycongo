import assert from "node:assert/strict";
import { chromium } from "playwright";

const setMode = async (mode) => {
  const response = await fetch(`http://upstream:9090/__mode/${mode}`, { method: "POST" });
  assert.equal(response.status, 204);
};
const setAnalyticsMode = async (mode) => {
  const response = await fetch(`http://upstream:9090/__analytics/${mode}`, { method: "POST" });
  assert.equal(response.status, 204);
};
await setMode("ready");
await setAnalyticsMode("fixture");
const publicHealth = await fetch("http://admin:8080/ui-healthz");
assert.equal(publicHealth.status, 200);
const unauthenticatedNavigation = await fetch("http://admin:8080/", { redirect: "manual" });
assert.equal(unauthenticatedNavigation.status, 401);
assert.match(unauthenticatedNavigation.headers.get("www-authenticate") ?? "", /^Basic realm="OpenPay Congo Admin"/);
const unauthenticatedBootstrap = await fetch("http://admin:8080/backend/v1/session/bootstrap", { redirect: "manual" });
assert.equal(unauthenticatedBootstrap.status, 401);
const wrongCredentials = Buffer.from("admin:wrong-password", "utf8").toString("base64");
const rejectedCredentials = await fetch("http://admin:8080/", {
  headers: { Authorization: `Basic ${wrongCredentials}` },
  redirect: "manual"
});
assert.equal(rejectedCredentials.status, 401);
const browser = await chromium.launch();
try {
  const context = await browser.newContext({
    viewport: { width: 360, height: 720 },
    reducedMotion: "reduce",
    timezoneId: "America/New_York",
    httpCredentials: { username: "admin", password: "test-password" }
  });
  const page = await context.newPage();
  const browserAuthorizationHeaders = [];
  page.on("request", (request) => {
    if (request.url().includes("/backend/v1/session/bootstrap") || request.url().includes("/backend/v1/analytics/sales")) {
      browserAuthorizationHeaders.push(request.headers().authorization);
    }
  });
  const navigation = await page.goto("http://admin:8080/", { waitUntil: "domcontentloaded" });
  assert.ok(navigation);
  assert.equal(navigation.status(), 200);
  assert.match(navigation.headers()["content-security-policy"] ?? "", /form-action 'none'/);
  assert.match(navigation.headers()["cache-control"] ?? "", /no-store/);
  await page.getByRole("heading", { name: "Payments may be accepted" }).waitFor();
  await page.getByRole("heading", { name: "Sales data is stale" }).waitFor();
  await page.getByText("CDF 100.00", { exact: true }).first().waitFor();
  await page.getByText("USD 5.00", { exact: true }).first().waitFor();
  await page.getByText("Reconcile provider records · 1 affected", { exact: true }).waitFor();
  await page.getByText("Provider mix").click();
  await page.getByRole("heading", { name: "orange-money" }).waitFor();
  await page.getByRole("heading", { name: "mpesa" }).waitFor();
  const bootstrapResponse = await context.request.get("http://admin:8080/backend/v1/session/bootstrap");
  assert.equal(bootstrapResponse.status(), 200);
  assert.equal(bootstrapResponse.headers()["cache-control"], "private, no-store");
  assert.equal(bootstrapResponse.headers().vary, "Authorization");
  assert.ok(browserAuthorizationHeaders.length >= 2);
  assert.equal(browserAuthorizationHeaders.some((value) => value?.startsWith("Bearer ")), false);
  assert.equal(browserAuthorizationHeaders.some((value) => value?.includes("compose-test-backend-token-000001")), false);
  const renderedPage = await page.content();
  assert.equal(renderedPage.includes("compose-test-backend-token-000001"), false);
  assert.equal(renderedPage.includes("test-password"), false);
  const proxyObservationResponse = await fetch("http://upstream:9090/__proxy-observation");
  assert.equal(proxyObservationResponse.status, 200);
  const proxyObservation = await proxyObservationResponse.json();
  assert.deepEqual(proxyObservation, { authorization_scheme: "bearer", admin_user: "admin" });
  const operationsObservationResponse = await fetch("http://upstream:9090/__operations-observation");
  assert.equal(operationsObservationResponse.status, 200);
  const operationsObservation = await operationsObservationResponse.json();
  assert.deepEqual(operationsObservation.paths, ["/healthz", "/readyz", "/version"]);
  assert.equal(operationsObservation.authorization_seen, false);
  assert.equal(operationsObservation.admin_user_seen, false);
  const missingBearer = await context.request.get("http://upstream:9090/v1/session/bootstrap");
  assert.equal(missingBearer.status(), 401);
  const wrongBearer = await context.request.get("http://upstream:9090/v1/session/bootstrap", { headers: { Authorization: "Bearer wrong" } });
  assert.equal(wrongBearer.status(), 401);
  const analyticsResponse = await context.request.get("http://admin:8080/backend/v1/analytics/sales?from=2026-11-01T04%3A00%3A00Z&to=2026-11-02T05%3A00%3A00Z&snapshot_at=2026-11-02T12%3A00%3A00Z&time_zone=America%2FNew_York&interval=day&comparison=true");
  assert.equal(analyticsResponse.status(), 200);
  assert.equal(analyticsResponse.headers()["cache-control"], "private, max-age=30, must-revalidate");
  assert.equal(analyticsResponse.headers().vary, "Authorization");
  const conditionalAnalytics = await context.request.get(analyticsResponse.url(), { headers: { "If-None-Match": analyticsResponse.headers().etag } });
  assert.equal(conditionalAnalytics.status(), 304);
  assert.equal(conditionalAnalytics.headers()["cache-control"], "private, max-age=30, must-revalidate");
  const viewportFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  assert.equal(viewportFits, true);
  const animation = await page.locator(".focus").evaluate((element) => getComputedStyle(element).animationName);
  assert.equal(animation, "none");
  const salesAnimation = await page.locator(".sales").evaluate((element) => getComputedStyle(element).animationName);
  assert.equal(salesAnimation, "none");

  await setAnalyticsMode("error");
  await page.getByRole("button", { name: "Refresh sales" }).click();
  await page.getByRole("heading", { name: "Sales analytics are unavailable" }).waitFor();
  assert.equal(await page.getByText("CDF 100.00", { exact: true }).count(), 0);
  await setAnalyticsMode("fixture");
  await page.getByRole("button", { name: "Refresh sales" }).click();
  await page.getByRole("heading", { name: "Sales data is stale" }).waitFor();
  const html = await page.content();
  const assetPath = html.match(/src="([^"]+\.js)"/)?.[1];
  assert.ok(assetPath);
  const asset = await context.request.get(`http://admin:8080${assetPath}`);
  assert.equal(asset.status(), 200);
  assert.match(asset.headers()["cache-control"] ?? "", /immutable/);
  const unauthenticatedAsset = await fetch(`http://admin:8080${assetPath}`, { redirect: "manual" });
  assert.equal(unauthenticatedAsset.status, 401);

  await setMode("hang");
  await page.getByRole("heading", { name: "Last check is stale" }).waitFor({ timeout: 20_000 });
  const liveRegion = page.getByRole("status", { name: "Payment readiness" });
  assert.match(await liveRegion.textContent(), /Payments must remain paused/);
  await setMode("degraded");
  await page.getByRole("heading", { name: "Payments are paused" }).waitFor();
  const readinessResponse = await context.request.get("http://admin:8080/backend/readyz");
  assert.equal(readinessResponse.status(), 503);
  assert.match(readinessResponse.headers()["cache-control"] ?? "", /no-store/);
  assert.equal((await readinessResponse.json()).write_admission, "closed");

  assert.equal((await context.request.get("http://admin:8080/healthz")).status(), 404);
  assert.equal((await context.request.get("http://admin:8080/ui-healthz")).status(), 200);
  await context.close();
} finally {
  await browser.close();
}
