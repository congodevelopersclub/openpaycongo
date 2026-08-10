import type { ConnectionSnapshot } from "../domain/readiness";
import { hasConsistentIdentity, isWriteReady } from "../domain/readiness";

export interface Clock { readonly now: () => number; }
export interface Random { readonly next: () => number; }
export interface ConnectionPort { readonly fetchSnapshot: () => Promise<ConnectionSnapshot>; }
export type CircuitState = "closed" | "open" | "half_open";
export type StaleReason = "expired" | "transport_failure";
export type RefreshReason = "automatic" | "operator";

export type WorkspaceState =
  | { readonly kind: "loading"; readonly circuit: "closed" }
  | { readonly kind: "ready"; readonly snapshot: ConnectionSnapshot; readonly checkedAgeMs: number; readonly circuit: "closed" }
  | { readonly kind: "degraded"; readonly snapshot: ConnectionSnapshot; readonly checkedAgeMs: number; readonly circuit: "closed"; readonly message: string }
  | { readonly kind: "offline"; readonly circuit: CircuitState; readonly failures: number; readonly retryAt: number }
  | { readonly kind: "stale"; readonly snapshot: ConnectionSnapshot; readonly checkedAgeMs: number; readonly circuit: CircuitState; readonly failures: number; readonly retryAt: number; readonly reason: StaleReason };

export const freshnessTtlMilliseconds = 15_000;
export const breakerFailureThreshold = 3;
export const baseDelayMilliseconds = 1_000;
export const maximumDelayMilliseconds = 30_000;
const maximumRecordedFailures = 6;

export const boundedFullJitterDelay = (failures: number, random: Random): number => {
  const boundedFailures = Math.min(Math.max(failures, 1), maximumRecordedFailures);
  const exponentialCeiling = baseDelayMilliseconds * 2 ** (boundedFailures - 1);
  const ceiling = Math.min(exponentialCeiling, maximumDelayMilliseconds);
  const boundedSample = Math.min(Math.max(random.next(), 0), 0.999_999_999);
  return Math.max(1, Math.floor(boundedSample * ceiling));
};

export class ConnectionWorkspace {
  private failures = 0;
  private circuit: CircuitState = "closed";
  private retryAt = 0;
  private lastSnapshot: ConnectionSnapshot | undefined;
  private inFlight: Promise<WorkspaceState> | undefined;

  public constructor(
    private readonly port: ConnectionPort,
    private readonly clock: Clock,
    private readonly random: Random
  ) {}

  public refresh(reason: RefreshReason = "automatic"): Promise<WorkspaceState> {
    this.current();
    if (this.inFlight !== undefined) {
      return this.inFlight;
    }
    if (this.isBackoffActive() && reason === "automatic") {
      return Promise.resolve(this.unavailableState("transport_failure"));
    }
    if (this.circuit === "open") {
      this.circuit = "half_open";
    }
    const probe = this.performProbe();
    this.inFlight = probe;
    void probe.finally(() => {
      this.inFlight = undefined;
    });
    return probe;
  }

  public current(): WorkspaceState {
    if (this.lastSnapshot === undefined) {
      return this.failures === 0 ? this.loadingState() : this.unavailableState("transport_failure");
    }
    const checkedAgeMs = this.ageOf(this.lastSnapshot);
    if (checkedAgeMs > freshnessTtlMilliseconds) {
      return this.staleState(this.lastSnapshot, checkedAgeMs, "expired");
    }
    return this.evaluate(this.lastSnapshot);
  }

  private async performProbe(): Promise<WorkspaceState> {
    try {
      const snapshot = await this.port.fetchSnapshot();
      this.assertSnapshot(snapshot);
      this.lastSnapshot = snapshot;
      this.failures = 0;
      this.retryAt = 0;
      this.circuit = "closed";
      return this.evaluate(snapshot);
    } catch {
      this.recordFailure();
      return this.unavailableState("transport_failure");
    }
  }

  private evaluate(snapshot: ConnectionSnapshot): WorkspaceState {
    const checkedAgeMs = this.ageOf(snapshot);
    if (checkedAgeMs > freshnessTtlMilliseconds) {
      return this.staleState(snapshot, checkedAgeMs, "expired");
    }
    if (!hasConsistentIdentity(snapshot)) {
      return this.degradedState(snapshot, checkedAgeMs, "Operational endpoints disagree about the deployed backend.");
    }
    if (!isWriteReady(snapshot.readiness)) {
      return this.degradedState(snapshot, checkedAgeMs, "Payment writes are currently closed.");
    }
    return { kind: "ready", snapshot, checkedAgeMs, circuit: "closed" };
  }

  private recordFailure(): void {
    this.failures = Math.min(this.failures + 1, maximumRecordedFailures);
    this.retryAt = this.clock.now() + boundedFullJitterDelay(this.failures, this.random);
    this.circuit = this.failures >= breakerFailureThreshold ? "open" : "closed";
  }

  private loadingState(): WorkspaceState {
    return { kind: "loading", circuit: "closed" };
  }

  private degradedState(snapshot: ConnectionSnapshot, checkedAgeMs: number, message: string): WorkspaceState {
    return { kind: "degraded", snapshot, checkedAgeMs, circuit: "closed", message };
  }

  private staleState(snapshot: ConnectionSnapshot, checkedAgeMs: number, reason: StaleReason): WorkspaceState {
    return {
      kind: "stale",
      snapshot,
      checkedAgeMs,
      circuit: this.circuit,
      failures: this.failures,
      retryAt: Math.max(this.retryAt, this.clock.now()),
      reason
    };
  }

  private unavailableState(reason: StaleReason): WorkspaceState {
    if (this.lastSnapshot === undefined) {
      return { kind: "offline", circuit: this.circuit, failures: this.failures, retryAt: this.retryAt };
    }
    return this.staleState(this.lastSnapshot, this.ageOf(this.lastSnapshot), reason);
  }

  private isBackoffActive(): boolean {
    return this.failures > 0 && this.clock.now() < this.retryAt;
  }

  private ageOf(snapshot: ConnectionSnapshot): number {
    return Math.max(0, this.clock.now() - snapshot.observedAt);
  }

  private assertSnapshot(snapshot: ConnectionSnapshot): void {
    const observedAtIsValid = Number.isSafeInteger(snapshot.observedAt) && snapshot.observedAt >= 0 && snapshot.observedAt <= this.clock.now();
    if (!observedAtIsValid) {
      throw new Error("Invalid snapshot observation time.");
    }
  }
}
