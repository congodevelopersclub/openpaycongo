import { describe, expect, it } from "vitest";
import type { SalesQuery } from "../domain/sales-analytics";
import { AnalyticsFailure, HttpAnalyticsPort } from "./http-analytics-port";
import type { DeadlineScheduler, FetchLike } from "./http-connection-port";

const etag = `"${"a".repeat(64)}"`;
const query: SalesQuery = { from: "2026-11-02T05:00:00Z", to: "2026-11-02T12:00:00Z", snapshotAt: "2026-11-02T12:00:00Z", timeZone: "America/New_York", interval: "hour", comparison: true };
const currency = { currency: "CDF", gross_minor: "100", refunds_minor: "0", net_minor: "100", payment_count: "1", refund_count: "0", average_ticket_minor: "100" };
const provider = { provider: "orange-money", currencies: [currency] };
const current = { from: query.from, to: query.to, currencies: [currency], providers: [provider] };
const comparison = { from: "2026-11-01T22:00:00Z", to: query.from, currencies: [currency], providers: [provider] };
const body = {
  contract_version: "sales-analytics-v1",
  projection_version: "b".repeat(64),
  readiness: "ready",
  tenant_id: "tenant-test",
  snapshot_at: query.snapshotAt,
  observed_at: query.snapshotAt,
  time_zone: query.timeZone,
  current,
  comparison,
  series: [current],
  reconciliation: { lag_seconds_max: "0", unreconciled_count: "0" },
  sync: { status: "fresh", last_received_at: query.to, freshness_seconds: "0" },
  action_required: [],
  etag
};
const headers = { "content-type": "application/json", etag, "cache-control": "private, max-age=30, must-revalidate", vary: "Authorization" };
const scheduler: DeadlineScheduler = { schedule: () => 1 as ReturnType<typeof setTimeout>, cancel: () => undefined };

describe("HttpAnalyticsPort", () => {
  it("decodes the exact contract and sends bounded revalidation requests", async () => {
    let input = "";
    let init: RequestInit | undefined;
    const client: FetchLike = { fetch: async (nextInput, nextInit) => {
      input = nextInput;
      init = nextInit;
      return new Response(JSON.stringify(body), { status: 200, headers });
    } };
    const result = await new HttpAnalyticsPort(client, scheduler).fetch(query, new AbortController().signal, undefined, etag);
    expect(result).toMatchObject({ kind: "modified", etag });
    expect(input).toContain("/backend/v1/analytics/sales?");
    expect(input).toContain("comparison=true");
    expect(init?.cache).toBe("no-store");
    expect(new Headers(init?.headers).get("if-none-match")).toBe(etag);
  });

  it("accepts a header-complete 304 without reading totals", async () => {
    const client: FetchLike = { fetch: async () => new Response(null, { status: 304, headers }) };
    await expect(new HttpAnalyticsPort(client, scheduler).fetch(query, new AbortController().signal, "tenant-test", etag)).resolves.toEqual({ kind: "not_modified", etag });
  });

  it("rejects unsafe cache metadata and unexpected DTO fields", async () => {
    const unsafe = { ...body, invented_total: "9" };
    const client: FetchLike = { fetch: async () => new Response(JSON.stringify(unsafe), { status: 200, headers: { ...headers, vary: "Origin" } }) };
    await expect(new HttpAnalyticsPort(client, scheduler).fetch(query, new AbortController().signal)).rejects.toMatchObject({ kind: "shape" } satisfies Partial<AnalyticsFailure>);
  });

  it("rejects public, no-store, or approximate analytics cache policy", async () => {
    for (const cacheControl of ["public, max-age=30", "no-store", "private, max-age=30"] as const) {
      const client: FetchLike = { fetch: async () => new Response(JSON.stringify(body), { status: 200, headers: { ...headers, "cache-control": cacheControl } }) };
      await expect(new HttpAnalyticsPort(client, scheduler).fetch(query, new AbortController().signal)).rejects.toMatchObject({ kind: "shape" });
    }
  });

  it("cancels streaming 200 bodies when cache headers are invalid", async () => {
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new Uint8Array(1_024));
      },
      cancel() {
        cancelled = true;
      }
    });
    const client: FetchLike = { fetch: async () => new Response(stream, { status: 200, headers: { ...headers, "cache-control": "public, max-age=30" } }) };
    await expect(new HttpAnalyticsPort(client, scheduler).fetch(query, new AbortController().signal, "tenant-test")).rejects.toMatchObject({ kind: "shape" });
    expect(cancelled).toBe(true);
  });

  it("binds totals to the requested tenant, window, clocks, and financial arithmetic", async () => {
    const cases: Array<Record<string, unknown>> = [];
    const wrongTenant = structuredClone(body);
    wrongTenant.tenant_id = "tenant-other";
    cases.push(wrongTenant);
    const wrongWindow = structuredClone(body);
    wrongWindow.current.from = "2026-11-02T06:00:00Z";
    cases.push(wrongWindow);
    const earlyObservation = structuredClone(body);
    earlyObservation.observed_at = "2026-11-02T11:59:59Z";
    cases.push(earlyObservation);
    const futureWatermark = structuredClone(body);
    futureWatermark.sync.last_received_at = "2026-11-02T12:00:01Z";
    cases.push(futureWatermark);
    const brokenNet = structuredClone(body);
    const brokenCurrency = brokenNet.current.currencies[0];
    if (brokenCurrency === undefined) {
      throw new Error("Test fixture must contain a currency.");
    }
    brokenCurrency.net_minor = "99";
    cases.push(brokenNet);
    for (const invalid of cases) {
      const client: FetchLike = { fetch: async () => new Response(JSON.stringify(invalid), { status: 200, headers }) };
      await expect(new HttpAnalyticsPort(client, scheduler).fetch(query, new AbortController().signal, "tenant-test")).rejects.toMatchObject({ kind: "shape" });
    }
  });

  it("branches on non-success status and cancels its body without requiring cache headers", async () => {
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new Uint8Array(1_024));
      },
      cancel() {
        cancelled = true;
      }
    });
    const client: FetchLike = { fetch: async () => new Response(stream, { status: 503, headers: { "content-type": "application/problem+json" } }) };
    await expect(new HttpAnalyticsPort(client, scheduler).fetch(query, new AbortController().signal)).rejects.toMatchObject({ kind: "http" });
    expect(cancelled).toBe(true);
  });

  it("cancels a chunked response as soon as its byte bound is crossed", async () => {
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new Uint8Array(300_000));
      },
      cancel() {
        cancelled = true;
      }
    });
    const client: FetchLike = { fetch: async () => new Response(stream, { status: 200, headers }) };
    await expect(new HttpAnalyticsPort(client, scheduler).fetch(query, new AbortController().signal)).rejects.toMatchObject({ kind: "oversize" } satisfies Partial<AnalyticsFailure>);
    expect(cancelled).toBe(true);
  });

  it("aborts a hanging request at the shared deadline", async () => {
    let deadline: (() => void) | undefined;
    const deadlineScheduler: DeadlineScheduler = {
      schedule: (operation) => {
        deadline = operation;
        return 1 as ReturnType<typeof setTimeout>;
      },
      cancel: () => undefined
    };
    const client: FetchLike = { fetch: async (_input, init) => await new Promise<Response>((_resolve, reject) => {
      init.signal?.addEventListener("abort", () => reject(new Error("aborted")));
      deadline?.();
    }) };
    await expect(new HttpAnalyticsPort(client, deadlineScheduler).fetch(query, new AbortController().signal)).rejects.toMatchObject({ kind: "aborted" } satisfies Partial<AnalyticsFailure>);
  });
});
