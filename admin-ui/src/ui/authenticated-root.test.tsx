// @vitest-environment happy-dom
import { cleanup, render, screen, waitFor } from "@testing-library/preact";
import { afterEach, describe, expect, it } from "vitest";
import { ConnectionWorkspace, type ConnectionPort } from "../application/connection-workspace";
import type { AnalyticsPort } from "../application/sales-dashboard";
import type { ConnectionSnapshot } from "../domain/readiness";
import { AuthenticatedRoot, authenticatedPrincipalChangedEvent } from "./authenticated-root";
import type { AuthenticatedBootstrapPort, VerifiedAnalyticsPrincipal } from "../application/authenticated-bootstrap";

const connectionSnapshot: ConnectionSnapshot = {
  observedAt: Date.now(),
  process: "alive",
  identity: { build: "test", contractVersion: "1", implementation: "go", adapter: "sqlite", migrationRevision: "1" },
  readiness: { datastore: "ok", migration: "current", topology: "supported", projection: "healthy", writeAdmission: "open", contractVersion: "1", implementation: "go", adapter: "sqlite", migrationRevision: "1" }
};
const connectionPort: ConnectionPort = { fetchSnapshot: async () => connectionSnapshot };

afterEach(() => {
  cleanup();
});

describe("AuthenticatedRoot", () => {
  it("shows no dashboard when authenticated bootstrap is absent", async () => {
    const workspace = new ConnectionWorkspace(connectionPort, { now: Date.now }, { next: () => 0.5 });
    const analyticsPort: AnalyticsPort = { fetch: async () => { throw new Error("must not fetch"); } };
    const bootstrapPort: AuthenticatedBootstrapPort = { fetch: async () => { throw new Error("unauthenticated"); } };
    render(<AuthenticatedRoot workspace={workspace} initialState={{ kind: "loading", circuit: "closed" }} analyticsPort={analyticsPort} bootstrapPort={bootstrapPort} />);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Sign in before viewing payment data" })).toBeTruthy());
    expect(screen.getByRole("alert").textContent).toContain("Sales totals are hidden");
    expect(screen.queryByText("Sales evidence")).toBeNull();
  });

  it("recreates dashboard and cache when verified auth identity changes", async () => {
    let principal: VerifiedAnalyticsPrincipal = { tenantId: "tenant-a", sessionCacheId: "session-a" };
    const bootstrapPort: AuthenticatedBootstrapPort = { fetch: async () => principal };
    const tenants: string[] = [];
    const analyticsPort: AnalyticsPort = { fetch: async (query, _signal, expectedTenantId) => {
      if (expectedTenantId === undefined) {
        throw new Error("Verified tenant is required.");
      }
      tenants.push(expectedTenantId);
      const etag = `"${"a".repeat(64)}"`;
      return { kind: "modified", etag, snapshot: {
        contractVersion: "sales-analytics-v1", projectionVersion: "b".repeat(64), readiness: "ready", tenantId: expectedTenantId,
        snapshotAt: query.snapshotAt, observedAt: query.snapshotAt, timeZone: query.timeZone,
        current: { from: query.from, to: query.to, currencies: [], providers: [] }, series: [],
        reconciliation: { lagSecondsMax: "0", unreconciledCount: "0" }, sync: { status: "no_events" }, actionRequired: [], etag
      } };
    } };
    const workspace = new ConnectionWorkspace(connectionPort, { now: Date.now }, { next: () => 0.5 });
    render(<AuthenticatedRoot workspace={workspace} initialState={{ kind: "loading", circuit: "closed" }} analyticsPort={analyticsPort} bootstrapPort={bootstrapPort} />);
    await waitFor(() => expect(tenants).toContain("tenant-a"));
    principal = { tenantId: "tenant-b", sessionCacheId: "session-b" };
    window.dispatchEvent(new Event(authenticatedPrincipalChangedEvent));
    await waitFor(() => expect(tenants).toContain("tenant-b"));
  });
});
