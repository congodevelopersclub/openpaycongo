import { describe, expect, it } from "vitest";
import { BootstrapFailure, HttpAuthenticatedBootstrapPort } from "./http-authenticated-bootstrap-port";
import type { DeadlineScheduler, FetchLike } from "./http-connection-port";

const headers = { "content-type": "application/json", "cache-control": "private, no-store", vary: "Authorization" };
const scheduler: DeadlineScheduler = { schedule: () => 1 as ReturnType<typeof setTimeout>, cancel: () => undefined };

describe("HttpAuthenticatedBootstrapPort", () => {
  it("loads exact verified principal using credentialed no-store request", async () => {
    let input = "";
    let init: RequestInit | undefined;
    const client: FetchLike = { fetch: async (nextInput, nextInit) => {
      input = nextInput;
      init = nextInit;
      return new Response(JSON.stringify({ tenant_id: "tenant-demo", session_cache_id: "session-1" }), { status: 200, headers });
    } };
    await expect(new HttpAuthenticatedBootstrapPort(client, scheduler).fetch(new AbortController().signal)).resolves.toEqual({ tenantId: "tenant-demo", sessionCacheId: "session-1" });
    expect(input).toBe("/backend/v1/session/bootstrap");
    expect(init).toMatchObject({ method: "GET", cache: "no-store", credentials: "same-origin", redirect: "error" });
  });

  it("cancels 401 and invalid-header streaming bodies", async () => {
    for (const status of [401, 200] as const) {
      let cancelled = false;
      const stream = new ReadableStream<Uint8Array>({
        pull(controller) {
          controller.enqueue(new Uint8Array(1_024));
        },
        cancel() {
          cancelled = true;
        }
      });
      const responseHeaders = status === 200 ? { ...headers, "cache-control": "public" } : headers;
      const client: FetchLike = { fetch: async () => new Response(stream, { status, headers: responseHeaders }) };
      await expect(new HttpAuthenticatedBootstrapPort(client, scheduler).fetch(new AbortController().signal)).rejects.toBeInstanceOf(BootstrapFailure);
      expect(cancelled).toBe(true);
    }
  });

  it("rejects and cancels oversized chunked bootstrap data", async () => {
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new Uint8Array(3_000));
      },
      cancel() {
        cancelled = true;
      }
    });
    const client: FetchLike = { fetch: async () => new Response(stream, { status: 200, headers }) };
    await expect(new HttpAuthenticatedBootstrapPort(client, scheduler).fetch(new AbortController().signal)).rejects.toMatchObject({ kind: "body" });
    expect(cancelled).toBe(true);
  });

  it("aborts hanging bootstrap at deadline", async () => {
    let deadline: (() => void) | undefined;
    const deadlineScheduler: DeadlineScheduler = { schedule: (operation) => { deadline = operation; return 1 as ReturnType<typeof setTimeout>; }, cancel: () => undefined };
    const client: FetchLike = { fetch: async (_input, init) => await new Promise<Response>((_resolve, reject) => {
      init.signal?.addEventListener("abort", () => reject(new Error("aborted")));
      deadline?.();
    }) };
    await expect(new HttpAuthenticatedBootstrapPort(client, deadlineScheduler).fetch(new AbortController().signal)).rejects.toMatchObject({ kind: "aborted" });
  });
});
