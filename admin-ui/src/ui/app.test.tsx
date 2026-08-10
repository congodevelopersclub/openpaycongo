// @vitest-environment happy-dom
import { cleanup, render, screen, waitFor } from "@testing-library/preact";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it } from "vitest";
import { ConnectionWorkspace, freshnessTtlMilliseconds, type ConnectionPort } from "../application/connection-workspace";
import { SalesDashboard } from "../application/sales-dashboard";
import type { ConnectionSnapshot } from "../domain/readiness";
import { App } from "./app";

const snapshot = (writeAdmission: "open" | "closed", observedAt = 10_000): ConnectionSnapshot => ({
  observedAt,
  process: "alive",
  identity: { build: "go-v1", contractVersion: "1", implementation: "go", adapter: "sqlite", migrationRevision: "0001" },
  readiness: {
    datastore: "ok",
    migration: "current",
    topology: "supported",
    projection: "healthy",
    writeAdmission,
    contractVersion: "1",
    implementation: "go",
    adapter: "sqlite",
    migrationRevision: "0001"
  }
});

const salesDashboard = (): SalesDashboard => new SalesDashboard({
  fetch: async (query) => {
    const etag = `"${"a".repeat(64)}"`;
    return {
      kind: "modified",
      etag,
      snapshot: {
        contractVersion: "sales-analytics-v1",
        projectionVersion: "b".repeat(64),
        readiness: "ready",
        tenantId: "test",
        snapshotAt: query.snapshotAt,
        observedAt: query.snapshotAt,
        timeZone: query.timeZone,
        current: { from: query.from, to: query.to, currencies: [], providers: [] },
        series: [],
        reconciliation: { lagSecondsMax: "0", unreconciledCount: "0" },
        sync: { status: "no_events" },
        actionRequired: [],
        etag
      }
    };
  }
}, { tenantId: "test", sessionCacheId: "app-test" });

const setVisibility = (value: DocumentVisibilityState): void => {
  Object.defineProperty(document, "visibilityState", { configurable: true, value });
};

afterEach(() => {
  cleanup();
  setVisibility("visible");
});

describe("App", () => {
  it("uses an announced busy live region during the automatic initial check", async () => {
    let complete: ((value: ConnectionSnapshot) => void) | undefined;
    const port: ConnectionPort = {
      fetchSnapshot: async () => await new Promise<ConnectionSnapshot>((resolve) => {
        complete = resolve;
      })
    };
    const workspace = new ConnectionWorkspace(port, { now: () => 10_000 }, { next: () => 0.5 });
    render(<App workspace={workspace} initialState={{ kind: "loading", circuit: "closed" }} salesDashboard={salesDashboard()} now={() => 10_000} />);
    const liveRegion = screen.getByRole("status", { name: "Payment readiness" });
    expect(liveRegion.getAttribute("aria-live")).toBe("polite");
    await waitFor(() => expect(liveRegion.getAttribute("aria-busy")).toBe("true"));
    if (complete === undefined) {
      throw new Error("Initial check did not reach the port.");
    }
    complete(snapshot("open"));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Payments may be accepted" })).toBeTruthy());
    expect(liveRegion.getAttribute("aria-busy")).toBe("false");
    expect(screen.getByText("just now")).toBeTruthy();
  });

  it("keeps keyboard focus after an operator retry", async () => {
    let calls = 0;
    const port: ConnectionPort = {
      fetchSnapshot: async () => {
        calls += 1;
        return snapshot("closed");
      }
    };
    const workspace = new ConnectionWorkspace(port, { now: () => 10_000 }, { next: () => 0.5 });
    render(<App workspace={workspace} initialState={{ kind: "loading", circuit: "closed" }} salesDashboard={salesDashboard()} now={() => 10_000} />);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Payments are paused" })).toBeTruthy());
    const button = screen.getByRole("button", { name: "Check again" });
    button.focus();
    await userEvent.keyboard("{Enter}");
    await waitFor(() => expect(calls).toBe(2));
    expect(document.activeElement).toBe(button);
  });

  it("announces stale evidence synchronously when a hidden expired page becomes visible", async () => {
    let now = 10_000;
    let calls = 0;
    let completeRefresh: ((value: ConnectionSnapshot) => void) | undefined;
    const port: ConnectionPort = {
      fetchSnapshot: async () => {
        calls += 1;
        if (calls === 1) {
          return snapshot("open", now);
        }
        return await new Promise<ConnectionSnapshot>((resolve) => {
          completeRefresh = resolve;
        });
      }
    };
    const workspace = new ConnectionWorkspace(port, { now: () => now }, { next: () => 0.5 });
    render(<App workspace={workspace} initialState={{ kind: "loading", circuit: "closed" }} salesDashboard={salesDashboard()} now={() => now} />);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Payments may be accepted" })).toBeTruthy());
    setVisibility("hidden");
    document.dispatchEvent(new Event("visibilitychange"));
    now += freshnessTtlMilliseconds + 1;
    setVisibility("visible");
    document.dispatchEvent(new Event("visibilitychange"));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Last check is stale" })).toBeTruthy());
    expect(screen.getByRole("status", { name: "Payment readiness" }).textContent).toContain("Payments must remain paused");
    if (completeRefresh === undefined) {
      throw new Error("Visible resume did not start a refresh.");
    }
    completeRefresh(snapshot("open", now));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Payments may be accepted" })).toBeTruthy());
  });

  it("labels an operator override accurately during automatic backoff", async () => {
    let calls = 0;
    const port: ConnectionPort = {
      fetchSnapshot: async () => {
        calls += 1;
        throw new Error("offline");
      }
    };
    const workspace = new ConnectionWorkspace(port, { now: () => 20_000 }, { next: () => 0.5 });
    render(<App workspace={workspace} initialState={{ kind: "loading", circuit: "closed" }} salesDashboard={salesDashboard()} now={() => 20_000} />);
    const button = await screen.findByRole("button", { name: "Check now" });
    expect(screen.getByRole("status", { name: "Payment readiness" }).textContent).toContain("overrides this backoff");
    await userEvent.click(button);
    await waitFor(() => expect(calls).toBe(2));
  });
});
