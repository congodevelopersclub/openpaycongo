import type { AuthenticatedBootstrapPort, VerifiedAnalyticsPrincipal } from "../application/authenticated-bootstrap";
import { readAuthenticatedBootstrap } from "../application/authenticated-bootstrap";
import { BoundaryFailure, readBoundedJsonObject } from "./bounded-json";
import type { DeadlineScheduler, FetchLike } from "./http-connection-port";

export type BootstrapFailureKind = "aborted" | "unauthenticated" | "http" | "headers" | "body" | "network";

export class BootstrapFailure extends Error {
  public constructor(public readonly kind: BootstrapFailureKind, message: string) {
    super(message);
    this.name = "BootstrapFailure";
  }
}

const maximumBootstrapBytes = 4_096;
const requestDeadlineMilliseconds = 3_000;

const requirePrivateHeaders = (response: Response): void => {
  const cacheControl = response.headers.get("cache-control")?.trim().toLowerCase();
  const vary = response.headers.get("vary")?.trim().toLowerCase();
  if (cacheControl !== "private, no-store" || vary !== "authorization") {
    throw new BootstrapFailure("headers", "Authenticated bootstrap cache headers are unsafe.");
  }
};

export class HttpAuthenticatedBootstrapPort implements AuthenticatedBootstrapPort {
  public constructor(private readonly client: FetchLike, private readonly scheduler: DeadlineScheduler) {}

  public async fetch(signal: AbortSignal): Promise<VerifiedAnalyticsPrincipal> {
    const controller = new AbortController();
    const abortFromCaller = (): void => controller.abort(signal.reason);
    signal.addEventListener("abort", abortFromCaller, { once: true });
    if (signal.aborted) {
      abortFromCaller();
    }
    const deadline = this.scheduler.schedule(() => controller.abort("bootstrap deadline exceeded"), requestDeadlineMilliseconds);
    try {
      const response = await this.client.fetch("/backend/v1/session/bootstrap", {
        method: "GET",
        cache: "no-store",
        credentials: "same-origin",
        redirect: "error",
        signal: controller.signal,
        headers: { accept: "application/json" }
      });
      if (response.status !== 200) {
        await response.body?.cancel();
        const kind: BootstrapFailureKind = response.status === 401 ? "unauthenticated" : "http";
        throw new BootstrapFailure(kind, `Authenticated bootstrap returned HTTP ${response.status}.`);
      }
      try {
        requirePrivateHeaders(response);
      } catch (error: unknown) {
        await response.body?.cancel();
        throw error;
      }
      const decoded = readAuthenticatedBootstrap(await readBoundedJsonObject(response, maximumBootstrapBytes));
      if (decoded.kind !== "verified") {
        throw new BootstrapFailure("body", "Authenticated bootstrap body is invalid.");
      }
      return decoded.principal;
    } catch (error: unknown) {
      if (error instanceof BootstrapFailure) {
        throw error;
      }
      if (error instanceof BoundaryFailure) {
        throw new BootstrapFailure("body", error.message);
      }
      if (controller.signal.aborted) {
        throw new BootstrapFailure("aborted", "Authenticated bootstrap request deadline exceeded.");
      }
      throw new BootstrapFailure("network", "Authenticated bootstrap request failed.");
    } finally {
      signal.removeEventListener("abort", abortFromCaller);
      this.scheduler.cancel(deadline);
    }
  }
}
