export type AnalyticsInterval = "hour" | "day";
export type SyncStatus = "no_events" | "fresh" | "stale";
export type ActionKind =
  | "late_arrival"
  | "orphan_correction"
  | "over_refund"
  | "reconciliation_overdue"
  | "stale_sync"
  | "correction_after_void"
  | "correction_mismatch"
  | "lifecycle_conflict";
export type ActionName =
  | "review_offline_sync"
  | "repair_event_linkage"
  | "review_refund_total"
  | "reconcile_provider"
  | "check_replica_sync"
  | "review_correction_order"
  | "review_correction_identity"
  | "review_correction_lifecycle";

export interface SalesQuery {
  readonly from: string;
  readonly to: string;
  readonly snapshotAt: string;
  readonly timeZone: string;
  readonly interval: AnalyticsInterval;
  readonly comparison: boolean;
}

export interface CurrencyMetrics {
  readonly currency: string;
  readonly grossMinor: string;
  readonly refundsMinor: string;
  readonly netMinor: string;
  readonly paymentCount: string;
  readonly refundCount: string;
  readonly averageTicketMinor: string;
}

export interface ProviderMetrics {
  readonly provider: string;
  readonly currencies: readonly CurrencyMetrics[];
}

export interface SalesWindow {
  readonly from: string;
  readonly to: string;
  readonly currencies: readonly CurrencyMetrics[];
  readonly providers: readonly ProviderMetrics[];
}

export interface ReconciliationState {
  readonly lagSecondsMax: string;
  readonly unreconciledCount: string;
}

export type SalesSync =
  | { readonly status: "no_events" }
  | { readonly status: "fresh" | "stale"; readonly lastReceivedAt: string; readonly freshnessSeconds: string };

export interface ActionRequired {
  readonly kind: ActionKind;
  readonly count: string;
  readonly action: ActionName;
}

export interface SalesAnalyticsSnapshot {
  readonly contractVersion: "sales-analytics-v1";
  readonly projectionVersion: string;
  readonly readiness: "ready";
  readonly tenantId: string;
  readonly snapshotAt: string;
  readonly observedAt: string;
  readonly timeZone: string;
  readonly current: SalesWindow;
  readonly comparison?: SalesWindow;
  readonly series: readonly SalesWindow[];
  readonly reconciliation: ReconciliationState;
  readonly sync: SalesSync;
  readonly actionRequired: readonly ActionRequired[];
  readonly etag: string;
}

export const hasEvents = (snapshot: SalesAnalyticsSnapshot): boolean => {
  return snapshot.current.currencies.some((metrics) => BigInt(metrics.paymentCount) > 0n || BigInt(metrics.refundCount) > 0n);
};
