// @vitest-environment happy-dom
import { cleanup, render, screen, waitFor } from "@testing-library/preact";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it } from "vitest";
import { SalesDashboard, type AnalyticsFetchResult } from "../application/sales-dashboard";
import type { SalesAnalyticsSnapshot } from "../domain/sales-analytics";
import type { SalesQuery } from "../domain/sales-analytics";
import { SalesDashboardView } from "./sales-dashboard";

const etag = `"${"c".repeat(64)}"`;
const projection: SalesAnalyticsSnapshot = {
  contractVersion: "sales-analytics-v1",
  projectionVersion: "d".repeat(64),
  readiness: "ready",
  tenantId: "tenant-test",
  snapshotAt: "2026-11-02T12:00:00Z",
  observedAt: "2026-11-02T12:00:00Z",
  timeZone: "America/New_York",
  current: {
    from: "2026-11-02T05:00:00Z",
    to: "2026-11-02T12:00:00Z",
    currencies: [{ currency: "CDF", grossMinor: "10000", refundsMinor: "2000", netMinor: "8000", paymentCount: "1", refundCount: "1", averageTicketMinor: "10000" }],
    providers: [{ provider: "orange-money", currencies: [{ currency: "CDF", grossMinor: "10000", refundsMinor: "2000", netMinor: "8000", paymentCount: "1", refundCount: "1", averageTicketMinor: "10000" }] }]
  },
  series: [],
  reconciliation: { lagSecondsMax: "99000", unreconciledCount: "1" },
  sync: { status: "stale", lastReceivedAt: "2026-11-01T08:30:00Z", freshnessSeconds: "99000" },
  actionRequired: [{ kind: "stale_sync", count: "1", action: "check_replica_sync" }],
  etag
};

afterEach(cleanup);

describe("SalesDashboardView", () => {
  it("announces loading and stale confidence while keeping currencies explicit", async () => {
    const dashboard = new SalesDashboard({ fetch: async (): Promise<AnalyticsFetchResult> => ({ kind: "modified", snapshot: projection, etag }) }, { tenantId: "tenant-test", sessionCacheId: "ui-test" });
    render(<SalesDashboardView dashboard={dashboard} now={() => Date.parse(projection.snapshotAt)} timeZone={projection.timeZone} />);
    const live = screen.getByRole("status");
    expect(live.getAttribute("aria-live")).toBe("polite");
    await waitFor(() => expect(screen.getByRole("heading", { name: "Sales data is stale" })).toBeTruthy());
    expect(screen.getAllByText("CDF 100.00").length).toBeGreaterThan(0);
    expect(screen.getByText("Check replica synchronisation · 1 affected")).toBeTruthy();
  });

  it("does not retain totals after an explicit transport failure", async () => {
    let calls = 0;
    const dashboard = new SalesDashboard({ fetch: async (): Promise<AnalyticsFetchResult> => {
      calls += 1;
      if (calls === 1) {
        return { kind: "modified", snapshot: projection, etag };
      }
      throw new Error("offline");
    } }, { tenantId: "tenant-test", sessionCacheId: "ui-test" });
    render(<SalesDashboardView dashboard={dashboard} now={() => Date.parse(projection.snapshotAt)} timeZone={projection.timeZone} />);
    await waitFor(() => expect(screen.getAllByText("CDF 100.00").length).toBeGreaterThan(0));
    await userEvent.click(screen.getByRole("button", { name: "Refresh sales" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Sales analytics are unavailable" })).toBeTruthy());
    expect(screen.queryAllByText("CDF 100.00")).toHaveLength(0);
  });

  it("captures a fresh cutoff and window end for every operator refresh", async () => {
    let currentTime = Date.parse("2026-11-02T12:00:00Z");
    const queries: SalesQuery[] = [];
    const dashboard = new SalesDashboard({ fetch: async (query): Promise<AnalyticsFetchResult> => {
      queries.push(query);
      const empty: SalesAnalyticsSnapshot = {
        ...projection,
        snapshotAt: query.snapshotAt,
        observedAt: query.snapshotAt,
        timeZone: query.timeZone,
        current: { from: query.from, to: query.to, currencies: [], providers: [] },
        series: [],
        reconciliation: { lagSecondsMax: "0", unreconciledCount: "0" },
        sync: { status: "no_events" },
        actionRequired: []
      };
      return { kind: "modified", snapshot: empty, etag };
    } }, { tenantId: "tenant-test", sessionCacheId: "ui-refresh-test" });
    render(<SalesDashboardView dashboard={dashboard} now={() => currentTime} timeZone="America/New_York" />);
    await waitFor(() => expect(queries).toHaveLength(1));
    currentTime += 2_000;
    await userEvent.click(screen.getByRole("button", { name: "Refresh sales" }));
    await waitFor(() => expect(queries).toHaveLength(2));
    expect(queries[1]?.snapshotAt).toBe("2026-11-02T12:00:02Z");
    expect(queries[1]?.to).toBe("2026-11-02T12:00:02Z");
  });
});
