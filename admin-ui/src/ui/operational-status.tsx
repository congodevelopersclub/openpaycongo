export type OperationalStatusKind =
  | "loading"
  | "empty"
  | "stale"
  | "conflict"
  | "recovery_required"
  | "unavailable";

export interface OperationalStatus {
  readonly kind: OperationalStatusKind;
}

export interface OperationalStatusViewProps {
  /** Synthetic, already-classified state. This component has no read port. */
  readonly status: OperationalStatus;
}

const copy: Readonly<Record<OperationalStatusKind, { readonly title: string; readonly detail: string }>> = {
  loading: {
    title: "Loading operational evidence",
    detail: "No totals or reconciliation decision is shown until a validated source is available."
  },
  empty: {
    title: "No operational evidence for this period",
    detail: "No totals have been invented."
  },
  stale: {
    title: "Operational evidence is stale",
    detail: "Do not treat any previously displayed value as current until newer authoritative evidence is available."
  },
  conflict: {
    title: "Operational evidence conflicts",
    detail: "Preserve immutable evidence and require an authorized reconciliation review; do not overwrite or retry with a new identity."
  },
  recovery_required: {
    title: "Recovery required",
    detail: "Normal mutation and export claims must remain paused until approved recovery validation completes."
  },
  unavailable: {
    title: "Operational evidence is unavailable",
    detail: "An empty, zero, or successful result must not be substituted for unavailable evidence."
  }
};

/**
 * A route-free, session-independent presentation boundary.
 *
 * It intentionally accepts only a pre-classified synthetic state: it cannot
 * select a tenant, fetch data, create an operator authority, or render money.
 */
export const OperationalStatusView = ({ status }: OperationalStatusViewProps) => {
  const message = copy[status.kind];
  return (
    <section
      class={`operational-status operational-status--${status.kind}`}
      role="status"
      aria-live="polite"
      aria-busy={status.kind === "loading"}
      aria-labelledby="operational-status-title"
    >
      <p class="eyebrow">Operational state</p>
      <h2 id="operational-status-title">{message.title}</h2>
      <p>{message.detail}</p>
    </section>
  );
};
