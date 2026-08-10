import { describe, expect, it } from "vitest";
import {
  ConnectionWorkspace,
  boundedFullJitterDelay,
  freshnessTtlMilliseconds,
  maximumDelayMilliseconds,
  type Clock,
  type ConnectionPort,
  type Random,
  type WorkspaceState
} from "./connection-workspace";
import type { ConnectionSnapshot } from "../domain/readiness";

const fixedRandom: Random = { next: () => 0.5 };
const readySnapshot = (observedAt: number): ConnectionSnapshot => ({
  observedAt,
  process: "alive",
  identity: { build: "go-v1", contractVersion: "1", implementation: "go", adapter: "sqlite", migrationRevision: "0001" },
  readiness: {
    datastore: "ok",
    migration: "current",
    topology: "supported",
    projection: "healthy",
    writeAdmission: "open",
    contractVersion: "1",
    implementation: "go",
    adapter: "sqlite",
    migrationRevision: "0001"
  }
});

const retryAtOf = (state: WorkspaceState): number => {
  if (state.kind !== "offline" && state.kind !== "stale") {
    throw new Error("Expected an unavailable state.");
  }
  return state.retryAt;
};

describe("ConnectionWorkspace", () => {
  it("closes after a successful snapshot and marks it stale after the TTL", async () => {
    let now = 10_000;
    const clock: Clock = { now: () => now };
    const port: ConnectionPort = { fetchSnapshot: async () => readySnapshot(10_000) };
    const workspace = new ConnectionWorkspace(port, clock, fixedRandom);
    expect((await workspace.refresh()).kind).toBe("ready");
    now += freshnessTtlMilliseconds + 1;
    expect(workspace.current()).toMatchObject({ kind: "stale", reason: "expired", checkedAgeMs: freshnessTtlMilliseconds + 1 });
  });

  it("enforces backoff at failures one, two, and three before a half-open probe", async () => {
    let now = 20_000;
    let calls = 0;
    const clock: Clock = { now: () => now };
    const port: ConnectionPort = {
      fetchSnapshot: async () => {
        calls += 1;
        throw new Error("unavailable");
      }
    };
    const workspace = new ConnectionWorkspace(port, clock, fixedRandom);

    const failureOne = await workspace.refresh();
    expect(failureOne).toMatchObject({ failures: 1, circuit: "closed", retryAt: 20_500 });
    await workspace.refresh();
    expect(calls).toBe(1);

    now = retryAtOf(failureOne);
    const failureTwo = await workspace.refresh();
    expect(failureTwo).toMatchObject({ failures: 2, circuit: "closed", retryAt: 21_500 });
    await workspace.refresh();
    expect(calls).toBe(2);

    now = retryAtOf(failureTwo);
    const failureThree = await workspace.refresh();
    expect(failureThree).toMatchObject({ failures: 3, circuit: "open", retryAt: 23_500 });
    await workspace.refresh();
    expect(calls).toBe(3);

    now = retryAtOf(failureThree);
    const firstProbe = workspace.refresh();
    const coalescedProbe = workspace.refresh();
    expect(firstProbe).toBe(coalescedProbe);
    expect((await firstProbe).circuit).toBe("open");
    expect(calls).toBe(4);
  });

  it("allows an explicit operator override during pre-threshold backoff", async () => {
    let calls = 0;
    const port: ConnectionPort = {
      fetchSnapshot: async () => {
        calls += 1;
        throw new Error("down");
      }
    };
    const workspace = new ConnectionWorkspace(port, { now: () => 30_000 }, fixedRandom);
    await workspace.refresh();
    await workspace.refresh("operator");
    expect(calls).toBe(2);
  });

  it("closes a half-open circuit after recovery", async () => {
    let now = 40_000;
    let calls = 0;
    const clock: Clock = { now: () => now };
    const port: ConnectionPort = {
      fetchSnapshot: async () => {
        calls += 1;
        if (calls <= 3) {
          throw new Error("down");
        }
        return readySnapshot(now);
      }
    };
    const workspace = new ConnectionWorkspace(port, clock, fixedRandom);
    const first = await workspace.refresh();
    now = retryAtOf(first);
    const second = await workspace.refresh();
    now = retryAtOf(second);
    const opened = await workspace.refresh();
    now = retryAtOf(opened);
    expect(await workspace.refresh()).toMatchObject({ kind: "ready", circuit: "closed" });
  });

  it("pauses writes when version and readiness identities disagree", async () => {
    const inconsistent = readySnapshot(50_000);
    const port: ConnectionPort = {
      fetchSnapshot: async () => ({ ...inconsistent, readiness: { ...inconsistent.readiness, migrationRevision: "0002" } })
    };
    const workspace = new ConnectionWorkspace(port, { now: () => 50_000 }, fixedRandom);
    await expect(workspace.refresh()).resolves.toMatchObject({ kind: "degraded", message: "Operational endpoints disagree about the deployed backend." });
  });

  it("uses bounded full jitter without zero-delay hot loops", () => {
    expect(boundedFullJitterDelay(99, { next: () => 1 })).toBeLessThanOrEqual(maximumDelayMilliseconds);
    expect(boundedFullJitterDelay(1, { next: () => 0 })).toBe(1);
  });
});
