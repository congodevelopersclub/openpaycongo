import assert from "node:assert/strict";
import { chromium } from "playwright";

const setMode = async (mode) => {
  const response = await fetch(`http://upstream:9090/__mode/${mode}`, { method: "POST" });
  assert.equal(response.status, 204);
};

await setMode("ready");
const browser = await chromium.launch();
try {
  const context = await browser.newContext({ viewport: { width: 360, height: 720 }, reducedMotion: "reduce" });
  const page = await context.newPage();
  const navigation = await page.goto("http://admin:8080/", { waitUntil: "domcontentloaded" });
  assert.ok(navigation);
  assert.equal(navigation.status(), 200);
  assert.match(navigation.headers()["content-security-policy"] ?? "", /form-action 'none'/);
  assert.match(navigation.headers()["cache-control"] ?? "", /no-store/);
  await page.getByRole("heading", { name: "Payments may be accepted" }).waitFor();
  const viewportFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  assert.equal(viewportFits, true);
  const animation = await page.locator(".focus").evaluate((element) => getComputedStyle(element).animationName);
  assert.equal(animation, "none");

  const html = await page.content();
  const assetPath = html.match(/src="([^"]+\.js)"/)?.[1];
  assert.ok(assetPath);
  const asset = await context.request.get(`http://admin:8080${assetPath}`);
  assert.equal(asset.status(), 200);
  assert.match(asset.headers()["cache-control"] ?? "", /immutable/);

  await setMode("hang");
  await page.getByRole("heading", { name: "Last check is stale" }).waitFor({ timeout: 20_000 });
  const liveRegion = page.getByRole("status");
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
