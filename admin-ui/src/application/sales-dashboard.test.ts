import { describe, expect, it } from "vitest";
import { SalesDashboard, type AnalyticsFetchResult, type AnalyticsPort } from "./sales-dashboard";
import type { SalesAnalyticsSnapshot, SalesQuery } from "../domain/sales-analytics";

const query: SalesQuery = {
  from: "2026-11-01T04:00:00Z",
  to: "2026-11-02T05:00:00Z",
  snapshotAt: "2026-11-02T12:00:00Z",
  timeZone: "America/New_York",
  interval: "day",
  comparison: true
};
const principal = { tenantId: "tenant-test", sessionCacheId: "admin-session" } as const;

const snapshot = (syncStatus: "no_events" | "fresh" | "stale", actions = 0): SalesAnalyticsSnapshot => ({
  contractVersion: "sales-analytics-v1",
  projectionVersion: "a".repeat(64),
  readiness: "ready",
  tenantId: "tenant-test",
  snapshotAt: query.snapshotAt,
  observedAt: query.snapshotAt,
  timeZone: query.timeZone,
  current: {
    from: query.from,
    to: query.to,
    currencies: syncStatus === "no_events" ? [] : [{ currency: "CDF", grossMinor: "100", refundsMinor: "0", netMinor: "100", paymentCount: "1", refundCount: "0", averageTicketMinor: "100" }],
    providers: []
  },
  series: [],
  reconciliation: { lagSecondsMax: "0", unreconciledCount: "0" },
  sync: syncStatus === "no_events" ? { status: "no_events" } : { status: syncStatus, lastReceivedAt: query.to, freshnessSeconds: syncStatus === "fresh" ? "0" : "901" },
  actionRequired: Array.from({ length: actions }, () => ({ kind: "stale_sync", count: "1", action: "check_replica_sync" })),
  etag: `"${"b".repeat(64)}"`
});

describe("SalesDashboard", () => {
  it("classifies ready, no-event, stale, and action-required projections explicitly", async () => {
    for (const [projection, kind] of [[snapshot("fresh"), "ready"], [snapshot("no_events"), "no_events"], [snapshot("stale"), "stale"], [snapshot("fresh", 1), "degraded"]] as const) {
      const port: AnalyticsPort = { fetch: async () => ({ kind: "modified", snapshot: projection, etag: projection.etag }) };
      await expect(new SalesDashboard(port, principal).load(query)).resolves.toMatchObject({ kind });
    }
  });

  it("reuses only its validated cached snapshot after a matching 304", async () => {
    const projection = snapshot("fresh");
    let calls = 0;
    const port: AnalyticsPort = { fetch: async (_query, _signal, _tenant, etag) => {
      calls += 1;
      return calls === 1 ? { kind: "modified", snapshot: projection, etag: projection.etag } : { kind: "not_modified", etag: etag ?? "" };
    } };
    const dashboard = new SalesDashboard(port, principal);
    await dashboard.load(query);
    await expect(dashboard.load(query)).resolves.toMatchObject({ kind: "ready", revalidated: true });
  });

  it("aborts and ignores a superseded period request", async () => {
    let firstSignal: AbortSignal | undefined;
    let releaseFirst: ((result: AnalyticsFetchResult) => void) | undefined;
    let calls = 0;
    const ready = snapshot("fresh");
    const port: AnalyticsPort = { fetch: async (_query, signal) => {
      calls += 1;
      if (calls === 1) {
        firstSignal = signal;
        return await new Promise((resolve) => {
          releaseFirst = resolve;
        });
      }
      return { kind: "modified", snapshot: ready, etag: ready.etag };
    } };
    const dashboard = new SalesDashboard(port, principal);
    const first = dashboard.load(query);
    const second = dashboard.load({ ...query, from: "2026-10-27T04:00:00Z", interval: "day" });
    expect(firstSignal?.aborted).toBe(true);
    releaseFirst?.({ kind: "modified", snapshot: ready, etag: ready.etag });
    await expect(first).resolves.toBeUndefined();
    await expect(second).resolves.toMatchObject({ kind: "ready" });
  });

  it("pins the authenticated tenant and fails closed if it changes", async () => {
    const first = snapshot("fresh");
    const second = { ...snapshot("fresh"), tenantId: "tenant-other" };
    let calls = 0;
    let expectedTenant: string | undefined;
    const port: AnalyticsPort = { fetch: async (_query, _signal, tenant) => {
      calls += 1;
      expectedTenant = tenant;
      const projection = calls === 1 ? first : second;
      return { kind: "modified", snapshot: projection, etag: projection.etag };
    } };
    const dashboard = new SalesDashboard(port, principal);
    await dashboard.load(query);
    await expect(dashboard.load({ ...query, snapshotAt: "2026-11-02T12:00:01Z" })).resolves.toMatchObject({ kind: "error" });
    expect(expectedTenant).toBe("tenant-test");
  });
});
