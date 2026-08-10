import { useCallback, useEffect, useMemo, useState } from "preact/hooks";
import {
  freshnessTtlMilliseconds,
  type ConnectionWorkspace,
  type RefreshReason,
  type WorkspaceState
} from "../application/connection-workspace";
import type { ConnectionSnapshot } from "../domain/readiness";

export interface AppProps {
  readonly workspace: ConnectionWorkspace;
  readonly initialState: WorkspaceState;
  readonly now?: () => number;
}

interface StatusCopy {
  readonly eyebrow: string;
  readonly title: string;
  readonly detail: string;
}

const snapshotOf = (state: WorkspaceState): ConnectionSnapshot | undefined => {
  switch (state.kind) {
    case "ready":
    case "degraded":
    case "stale":
      return state.snapshot;
    case "loading":
    case "offline":
      return undefined;
  }
};

const retryDetail = (state: Extract<WorkspaceState, { kind: "offline" | "stale" }>, now: number): string => {
  const seconds = Math.max(0, Math.ceil((state.retryAt - now) / 1_000));
  const circuit = state.circuit.replace("_", "-");
  return `Automatic checks resume in ${seconds} seconds. Circuit: ${circuit}. “Check now” overrides this backoff.`;
};

const statusCopy = (state: WorkspaceState, now: number): StatusCopy => {
  switch (state.kind) {
    case "loading":
      return { eyebrow: "Connection", title: "Checking the payment path", detail: "No write decision is available yet." };
    case "ready":
      return { eyebrow: "Write admission", title: "Payments may be accepted", detail: "Every required server readiness gate is open." };
    case "degraded":
      return { eyebrow: "Write admission", title: "Payments are paused", detail: state.message };
    case "offline":
      return { eyebrow: "Connection", title: "Server cannot be reached", detail: `There is no current evidence that payment writes are safe. ${retryDetail(state, now)}` };
    case "stale":
      return { eyebrow: "Connection", title: "Last check is stale", detail: `The current server state is unknown. Payments must remain paused. ${retryDetail(state, now)}` };
  }
};

const details = (snapshot: ConnectionSnapshot | undefined): readonly [string, string][] => {
  if (snapshot === undefined) {
    return [];
  }
  return [
    ["Implementation", snapshot.identity.implementation],
    ["Datastore adapter", snapshot.identity.adapter],
    ["Build", snapshot.identity.build],
    ["Migration", snapshot.identity.migrationRevision],
    ["Contract", snapshot.identity.contractVersion]
  ];
};

const checkedAge = (state: WorkspaceState): number | undefined => {
  switch (state.kind) {
    case "ready":
    case "degraded":
    case "stale":
      return state.checkedAgeMs;
    case "loading":
    case "offline":
      return undefined;
  }
};

const formatAge = (milliseconds: number): string => {
  return milliseconds < 1_000 ? "just now" : `${Math.floor(milliseconds / 1_000)} seconds ago`;
};

const useWorkspaceState = (
  workspace: ConnectionWorkspace,
  initialState: WorkspaceState,
  now: () => number
): readonly [WorkspaceState, boolean, (reason: RefreshReason) => Promise<void>] => {
  const [state, setState] = useState(initialState);
  const [refreshing, setRefreshing] = useState(false);

  const refresh = useCallback(async (reason: RefreshReason): Promise<void> => {
    setState(workspace.current());
    setRefreshing(true);
    try {
      setState(await workspace.refresh(reason));
    } finally {
      setRefreshing(false);
    }
  }, [workspace]);

  useEffect(() => {
    void refresh("automatic");
  }, [refresh]);

  useEffect(() => {
    const resume = (): void => {
      if (document.visibilityState === "visible" && navigator.onLine) {
        void refresh("automatic");
      }
    };
    document.addEventListener("visibilitychange", resume);
    window.addEventListener("online", resume);
    return () => {
      document.removeEventListener("visibilitychange", resume);
      window.removeEventListener("online", resume);
    };
  }, [refresh]);

  useEffect(() => {
    if (refreshing || document.visibilityState !== "visible" || !navigator.onLine) {
      return undefined;
    }
    const snapshot = snapshotOf(state);
    const retryAt = state.kind === "offline" || state.kind === "stale" ? state.retryAt : undefined;
    const dueAt = retryAt ?? (snapshot === undefined ? undefined : snapshot.observedAt + freshnessTtlMilliseconds + 1);
    if (dueAt === undefined) {
      return undefined;
    }
    const boundedDelay = Math.min(Math.max(dueAt - now(), 1), freshnessTtlMilliseconds + 1);
    const handle = window.setTimeout(() => {
      void refresh("automatic");
    }, boundedDelay);
    return () => {
      window.clearTimeout(handle);
    };
  }, [now, refresh, refreshing, state, workspace]);

  return [state, refreshing, refresh];
};

export const App = ({ workspace, initialState, now = Date.now }: AppProps) => {
  const [state, refreshing, refresh] = useWorkspaceState(workspace, initialState, now);
  const copy = statusCopy(state, now());
  const snapshot = snapshotOf(state);
  const metadata = useMemo(() => details(snapshot), [snapshot]);
  const age = checkedAge(state);
  const operatorLabel = state.kind === "offline" || state.kind === "stale" ? "Check now" : "Check again";

  return (
    <main class="shell">
      <header>
        <span class="mark" aria-hidden="true">OP</span>
        <div>
          <p class="product">OpenPay Congo</p>
          <p class="area">Operations console</p>
        </div>
        <span class="mode">Read-only</span>
      </header>
      <section class={`focus focus--${state.kind}`} role="status" aria-live="polite" aria-busy={refreshing}>
        <p class="eyebrow">{copy.eyebrow}</p>
        <h1>{copy.title}</h1>
        <p class="detail">{copy.detail}</p>
        {snapshot !== undefined && (
          <p class="freshness">
            Checked <time dateTime={new Date(snapshot.observedAt).toISOString()}>{age === undefined ? "unknown" : formatAge(age)}</time>
          </p>
        )}
        <button type="button" onClick={() => void refresh("operator")} disabled={refreshing}>
          {refreshing ? "Checking…" : operatorLabel}
        </button>
      </section>
      <section class="evidence" aria-labelledby="evidence-title">
        <div>
          <p class="eyebrow" id="evidence-title">Evidence</p>
          <p class="fine">This read-only screen reflects the backend operational endpoints. Stale or missing evidence always closes the payment path.</p>
        </div>
        <dl>
          {metadata.map(([label, value]) => (
            <div key={label}>
              <dt>{label}</dt>
              <dd>{value}</dd>
            </div>
          ))}
        </dl>
      </section>
    </main>
  );
};
