import { describe, expect, it } from "vitest";
import { HttpConnectionPort, TransportFailure, type DeadlineScheduler, type FetchLike } from "./http-connection-port";

const jsonResponse = (value: object, status = 200): Response => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
const identity = { build: "go-v1", contract_version: "1", implementation: "go", adapter: "sqlite", migration_revision: "0001" };
const readiness = { datastore: "ok", migration: "current", topology: "supported", projection: "healthy", write_admission: "open", contract_version: "1", implementation: "go", adapter: "sqlite", migration_revision: "0001" };
const passiveScheduler: DeadlineScheduler = { schedule: (operation, delay) => setTimeout(operation, delay), cancel: (handle) => clearTimeout(handle) };

const chunkedOversizeResponse = (contentLength?: string): { readonly response: Response; readonly wasCancelled: () => boolean } => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new Uint8Array(10_000));
      controller.enqueue(new Uint8Array(7_000));
    },
    cancel() {
      cancelled = true;
    }
  });
  const headers = new Headers({ "content-type": "application/json" });
  if (contentLength !== undefined) {
    headers.set("content-length", contentLength);
  }
  return {
    response: new Response(body, { status: 200, headers }),
    wasCancelled: () => cancelled
  };
};

const sequenceClient = (responses: readonly Response[]): FetchLike => {
  let index = 0;
  return { fetch: async () => {
    const response = responses[index];
    index += 1;
    if (response === undefined) throw new Error("Unexpected fetch.");
    return response;
  }};
};

describe("HttpConnectionPort", () => {
  it("returns a fully modelled atomic operational snapshot", async () => {
    const port = new HttpConnectionPort(sequenceClient([new Response(null, { status: 200 }), jsonResponse(identity), jsonResponse(readiness)]), { value: "/backend" }, () => 42, passiveScheduler);
    await expect(port.fetchSnapshot()).resolves.toMatchObject({ observedAt: 42, process: "alive", identity: { implementation: "go" }, readiness: { writeAdmission: "open" } });
  });

  it("accepts a contract-valid HTTP 503 as structured degraded evidence", async () => {
    const closed = { ...readiness, datastore: "failed", write_admission: "closed" };
    const port = new HttpConnectionPort(
      sequenceClient([new Response(null, { status: 200 }), jsonResponse(identity), jsonResponse(closed, 503)]),
      { value: "/backend" },
      () => 42,
      passiveScheduler
    );
    await expect(port.fetchSnapshot()).resolves.toMatchObject({ readiness: { datastore: "failed", writeAdmission: "closed" } });
  });

  it("rejects an HTTP 503 body that illegally leaves write admission open", async () => {
    const port = new HttpConnectionPort(
      sequenceClient([new Response(null, { status: 200 }), jsonResponse(identity), jsonResponse(readiness, 503)]),
      { value: "/backend" },
      () => 42,
      passiveScheduler
    );
    await expect(port.fetchSnapshot()).rejects.toMatchObject({ kind: "shape" });
  });

  it("uses no-store and same-origin credentials", async () => {
    const requests: RequestInit[] = [];
    const responses = [new Response(null, { status: 200 }), jsonResponse(identity), jsonResponse(readiness)];
    const client: FetchLike = { fetch: async (_input, init) => { requests.push(init); const response = responses.shift(); if (response === undefined) throw new Error("Unexpected fetch."); return response; } };
    await new HttpConnectionPort(client, { value: "/backend" }, () => 42, passiveScheduler).fetchSnapshot();
    expect(requests).toHaveLength(3);
    expect(requests.every((request) => request.cache === "no-store" && request.credentials === "same-origin")).toBe(true);
  });

  it.each([
    ["HTTP 503", [new Response(null, { status: 503 })], "http"],
    ["wrong MIME", [new Response(null, { status: 200 }), new Response("{}", { status: 200, headers: { "content-type": "text/html" } }), jsonResponse(readiness)], "mime"],
    ["oversize", [new Response(null, { status: 200 }), new Response("x".repeat(16_385), { status: 200, headers: { "content-type": "application/json" } }), jsonResponse(readiness)], "oversize"],
    ["bad shape", [new Response(null, { status: 200 }), jsonResponse({ build: "go-v1" }), jsonResponse(readiness)], "shape"]
  ] as const)("rejects %s responses as typed failures", async (_label, responses, kind) => {
    const port = new HttpConnectionPort(sequenceClient(responses), { value: "/backend" }, () => 42, passiveScheduler);
    await expect(port.fetchSnapshot()).rejects.toMatchObject({ name: "TransportFailure", kind });
  });

  it("aborts a hanging request at the shared deadline", async () => {
    let expire: (() => void) | undefined;
    const scheduler: DeadlineScheduler = { schedule: (operation) => { expire = operation; return setTimeout(() => undefined, 60_000); }, cancel: (handle) => clearTimeout(handle) };
    const client: FetchLike = { fetch: async (_input, init) => await new Promise<Response>((_resolve, reject) => { init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true }); }) };
    const pending = new HttpConnectionPort(client, { value: "/backend" }, () => 42, scheduler).fetchSnapshot();
    if (expire === undefined) throw new Error("Deadline was not scheduled.");
    expire();
    await expect(pending).rejects.toEqual(expect.objectContaining<Partial<TransportFailure>>({ kind: "aborted" }));
  });

  it("cancels a chunked response without content-length as soon as it crosses 16 KiB", async () => {
    const oversized = chunkedOversizeResponse();
    const port = new HttpConnectionPort(
      sequenceClient([new Response(null, { status: 200 }), oversized.response, jsonResponse(readiness)]),
      { value: "/backend" },
      () => 42,
      passiveScheduler
    );
    await expect(port.fetchSnapshot()).rejects.toMatchObject({ kind: "oversize" });
    expect(oversized.wasCancelled()).toBe(true);
  });

  it("cancels a response whose content-length lies below its streamed byte count", async () => {
    const oversized = chunkedOversizeResponse("12");
    const port = new HttpConnectionPort(
      sequenceClient([new Response(null, { status: 200 }), oversized.response, jsonResponse(readiness)]),
      { value: "/backend" },
      () => 42,
      passiveScheduler
    );
    await expect(port.fetchSnapshot()).rejects.toMatchObject({ kind: "oversize" });
    expect(oversized.wasCancelled()).toBe(true);
  });

  it("distinguishes immediate network failures from deadline expiry", async () => {
    const client: FetchLike = { fetch: async () => { throw new Error("network down"); } };
    const pending = new HttpConnectionPort(client, { value: "/backend" }, () => 42, passiveScheduler).fetchSnapshot();
    await expect(pending).rejects.toEqual(expect.objectContaining<Partial<TransportFailure>>({ kind: "network" }));
  });
});
