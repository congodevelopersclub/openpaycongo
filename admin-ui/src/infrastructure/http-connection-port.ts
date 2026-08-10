import type { ConnectionPort } from "../application/connection-workspace";
import type { ConnectionSnapshot, Readiness, ServerIdentity } from "../domain/readiness";
import { BoundaryFailure, readBoundedJsonObject } from "./bounded-json";

export interface FetchLike {
  readonly fetch: (input: string, init: RequestInit) => Promise<Response>;
}
export interface BaseUrl {
  readonly value: string;
}
export interface DeadlineScheduler {
  readonly schedule: (operation: () => void, delayMs: number) => ReturnType<typeof setTimeout>;
  readonly cancel: (handle: ReturnType<typeof setTimeout>) => void;
}
export type TransportFailureKind = "aborted" | "http" | "mime" | "oversize" | "shape" | "network";
export class TransportFailure extends Error {
  public constructor(public readonly kind: TransportFailureKind, message: string) {
    super(message);
    this.name = "TransportFailure";
  }
}

const maximumResponseBytes = 16_384;
const maximumFieldLength = 128;
const requestDeadlineMilliseconds = 3_000;
const requiredString = (record: Record<string, unknown>, name: string): string => {
  const value = record[name];
  const valid = typeof value === "string" && value.length > 0 && value.length <= maximumFieldLength;
  if (!valid) {
    throw new TransportFailure("shape", `Invalid ${name}.`);
  }
  return value;
};
const requiredEnum = <T extends string>(record: Record<string, unknown>, name: string, allowed: readonly T[]): T => {
  const value = requiredString(record, name);
  const match = allowed.find((candidate) => candidate === value);
  if (match === undefined) {
    throw new TransportFailure("shape", `Invalid ${name}.`);
  }
  return match;
};
const validateBaseUrl = (baseUrl: BaseUrl): string => {
  const invalidLengthOrSuffix = baseUrl.value.length === 0 || baseUrl.value.length > 2_048 || baseUrl.value.includes("?") || baseUrl.value.includes("#");
  if (invalidLengthOrSuffix) {
    throw new Error("Invalid backend base URL.");
  }
  if (baseUrl.value.startsWith("/") && !baseUrl.value.startsWith("//")) {
    return baseUrl.value.replace(/\/$/, "");
  }
  const parsed = new URL(baseUrl.value);
  const unsafeAbsoluteUrl = parsed.protocol !== "https:" || parsed.username !== "" || parsed.password !== "";
  if (unsafeAbsoluteUrl) {
    throw new Error("Backend base URL must be relative or HTTPS without credentials.");
  }
  return baseUrl.value.replace(/\/$/, "");
};

const readBoundedObject = async (response: Response): Promise<Record<string, unknown>> => {
  try {
    return await readBoundedJsonObject(response, maximumResponseBytes);
  } catch (error: unknown) {
    if (error instanceof BoundaryFailure) {
      throw new TransportFailure(error.kind, `Operational ${error.message.toLowerCase()}`);
    }
    throw error;
  }
};

const readIdentity = (value: Record<string, unknown>): ServerIdentity => ({
  build: requiredString(value, "build"),
  contractVersion: requiredString(value, "contract_version"),
  implementation: requiredString(value, "implementation"),
  adapter: requiredString(value, "adapter"),
  migrationRevision: requiredString(value, "migration_revision")
});
const readReadiness = (value: Record<string, unknown>): Readiness => ({
  datastore: requiredEnum(value, "datastore", ["ok", "failed"]),
  migration: requiredEnum(value, "migration", ["current", "pending", "failed"]),
  topology: requiredEnum(value, "topology", ["supported", "unsupported"]),
  projection: requiredEnum(value, "projection", ["healthy", "rebuilding", "failed"]),
  writeAdmission: requiredEnum(value, "write_admission", ["open", "closed"]),
  contractVersion: requiredString(value, "contract_version"),
  implementation: requiredString(value, "implementation"),
  adapter: requiredString(value, "adapter"),
  migrationRevision: requiredString(value, "migration_revision")
});

export class HttpConnectionPort implements ConnectionPort {
  private readonly backendBaseUrl: string;
  public constructor(
    private readonly client: FetchLike,
    baseUrl: BaseUrl,
    private readonly now: () => number,
    private readonly scheduler: DeadlineScheduler
  ) {
    this.backendBaseUrl = validateBaseUrl(baseUrl);
  }

  public async fetchSnapshot(): Promise<ConnectionSnapshot> {
    const controller = new AbortController();
    const deadline = this.scheduler.schedule(() => controller.abort(), requestDeadlineMilliseconds);
    try {
      await this.requireHealthy(controller.signal);
      const [identity, readiness] = await this.fetchOperationalPair(controller);
      return { observedAt: this.now(), process: "alive", identity, readiness };
    } catch (error: unknown) {
      const deadlineExpired = controller.signal.aborted;
      controller.abort();
      if (error instanceof TransportFailure) {
        throw error;
      }
      if (deadlineExpired) {
        throw new TransportFailure("aborted", "Operational request deadline exceeded.");
      }
      throw new TransportFailure("network", "Operational request failed.");
    } finally {
      this.scheduler.cancel(deadline);
    }
  }

  private async requireHealthy(signal: AbortSignal): Promise<void> {
    const response = await this.request("healthz", signal);
    if (response.status !== 200) {
      throw new TransportFailure("http", `Liveness returned HTTP ${response.status}.`);
    }
  }

  private async fetchOperationalPair(controller: AbortController): Promise<readonly [ServerIdentity, Readiness]> {
    try {
      const versionPromise = this.fetchIdentity(controller.signal);
      const readinessPromise = this.fetchReadiness(controller.signal);
      return await Promise.all([versionPromise, readinessPromise]);
    } catch (error: unknown) {
      controller.abort();
      throw error;
    }
  }

  private async fetchIdentity(signal: AbortSignal): Promise<ServerIdentity> {
    const response = await this.request("version", signal);
    if (response.status !== 200) {
      throw new TransportFailure("http", `Version returned HTTP ${response.status}.`);
    }
    return readIdentity(await readBoundedObject(response));
  }

  private async fetchReadiness(signal: AbortSignal): Promise<Readiness> {
    const response = await this.request("readyz", signal);
    if (response.status !== 200 && response.status !== 503) {
      throw new TransportFailure("http", `Readiness returned HTTP ${response.status}.`);
    }
    const readiness = readReadiness(await readBoundedObject(response));
    if (response.status === 503 && readiness.writeAdmission !== "closed") {
      throw new TransportFailure("shape", "HTTP 503 readiness must close write admission.");
    }
    return readiness;
  }

  private request(path: "healthz" | "version" | "readyz", signal: AbortSignal): Promise<Response> {
    return this.client.fetch(`${this.backendBaseUrl}/${path}`, {
      method: "GET",
      cache: "no-store",
      credentials: "same-origin",
      redirect: "error",
      signal,
      headers: { accept: "application/json" }
    });
  }
}
