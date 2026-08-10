import { useCallback, useEffect, useRef, useState } from "preact/hooks";
import { buildSalesQuery, type SalesPeriod } from "../application/sales-query";
import type { SalesDashboard, SalesDashboardState } from "../application/sales-dashboard";
import type { ActionRequired, CurrencyMetrics, SalesAnalyticsSnapshot } from "../domain/sales-analytics";

export interface SalesDashboardViewProps {
  readonly dashboard: SalesDashboard;
  readonly now?: () => number;
  readonly timeZone?: string;
}

const knownFractionDigits: Readonly<Record<string, number>> = { CDF: 2, USD: 2 };

const formatMinor = (minor: string, currency: string): string => {
  const digits = knownFractionDigits[currency];
  if (digits === undefined) {
    return `${currency} ${minor} minor units`;
  }
  const negative = minor.startsWith("-");
  const absolute = negative ? minor.slice(1) : minor;
  const padded = absolute.padStart(digits + 1, "0");
  const major = padded.slice(0, -digits);
  const fraction = padded.slice(-digits);
  const grouped = new Intl.NumberFormat("en", { maximumFractionDigits: 0 }).format(BigInt(major));
  return `${negative ? "−" : ""}${currency} ${grouped}.${fraction}`;
};

const comparisonText = (metrics: CurrencyMetrics, snapshot: SalesAnalyticsSnapshot): string => {
  const previous = snapshot.comparison?.currencies.find((candidate) => candidate.currency === metrics.currency);
  if (previous === undefined) {
    return "No comparable prior value";
  }
  const delta = BigInt(metrics.netMinor) - BigInt(previous.netMinor);
  if (delta === 0n) {
    return "Net unchanged from prior period";
  }
  const direction = delta > 0n ? "up" : "down";
  const absolute = delta > 0n ? delta : -delta;
  return `Net ${direction} ${formatMinor(absolute.toString(), metrics.currency)} from prior period`;
};

const actionCopy = (item: ActionRequired): string => {
  const copy: Record<ActionRequired["action"], string> = {
    review_offline_sync: "Review late offline events",
    repair_event_linkage: "Repair event linkage",
    review_refund_total: "Review refund total",
    reconcile_provider: "Reconcile provider records",
    check_replica_sync: "Check replica synchronisation",
    review_correction_order: "Review correction order",
    review_correction_identity: "Review correction identity",
    review_correction_lifecycle: "Review correction lifecycle"
  };
  return `${copy[item.action]} · ${item.count} affected`;
};

const stateTitle = (state: SalesDashboardState): string => {
  switch (state.kind) {
    case "loading": return "Loading sales evidence";
    case "ready": return "Sales are current";
    case "no_events": return "No sales in this period";
    case "stale": return "Sales data is stale";
    case "degraded": return "Sales need attention";
    case "error": return "Sales analytics are unavailable";
  }
};

const snapshotOf = (state: SalesDashboardState): SalesAnalyticsSnapshot | undefined => {
  switch (state.kind) {
    case "ready":
    case "no_events":
    case "stale":
    case "degraded":
      return state.snapshot;
    case "loading":
    case "error":
      return undefined;
  }
};

const reliabilityText = (snapshot: SalesAnalyticsSnapshot): string => {
  if (snapshot.sync.status === "no_events") {
    return "No payment event has been received for this window.";
  }
  return `${snapshot.sync.status === "fresh" ? "Fresh" : "Stale"} sync · ${snapshot.sync.freshnessSeconds} seconds since last receipt`;
};

const Totals = ({ snapshot }: { readonly snapshot: SalesAnalyticsSnapshot }) => (
  <div class="currency-grid" aria-label="Sales totals by currency">
    {snapshot.current.currencies.map((metrics) => (
      <article class="currency-card" key={metrics.currency}>
        <p class="currency-code">{metrics.currency}</p>
        <p class="gross-label">Gross volume</p>
        <p class="gross-value">{formatMinor(metrics.grossMinor, metrics.currency)}</p>
        <p class="trend">{comparisonText(metrics, snapshot)}</p>
        <dl class="metric-grid">
          <div><dt>Net</dt><dd>{formatMinor(metrics.netMinor, metrics.currency)}</dd></div>
          <div><dt>Payments</dt><dd>{metrics.paymentCount}</dd></div>
          <div><dt>Refunds</dt><dd>{formatMinor(metrics.refundsMinor, metrics.currency)} · {metrics.refundCount}</dd></div>
          <div><dt>Average ticket</dt><dd>{formatMinor(metrics.averageTicketMinor, metrics.currency)}</dd></div>
        </dl>
      </article>
    ))}
  </div>
);

const ProgressiveDetails = ({ snapshot }: { readonly snapshot: SalesAnalyticsSnapshot }) => (
  <div class="progressive">
    <details>
      <summary>Sales over time <span>{snapshot.series.length} intervals</span></summary>
      <div class="table-scroll" tabIndex={0} aria-label="Scrollable sales time series">
        <table>
          <thead><tr><th scope="col">Window start</th><th scope="col">Currency</th><th scope="col">Gross</th><th scope="col">Net</th><th scope="col">Payments</th></tr></thead>
          <tbody>{snapshot.series.flatMap((window) => window.currencies.map((metrics) => (
            <tr key={`${window.from}-${metrics.currency}`}><td><time dateTime={window.from}>{window.from}</time></td><td>{metrics.currency}</td><td>{formatMinor(metrics.grossMinor, metrics.currency)}</td><td>{formatMinor(metrics.netMinor, metrics.currency)}</td><td>{metrics.paymentCount}</td></tr>
          )))}</tbody>
        </table>
      </div>
    </details>
    <details>
      <summary>Provider mix <span>{snapshot.current.providers.length} providers</span></summary>
      <div class="provider-grid">{snapshot.current.providers.map((provider) => (
        <article key={provider.provider}><h3>{provider.provider}</h3>{provider.currencies.map((metrics) => (
          <p key={metrics.currency}>{metrics.currency} · {formatMinor(metrics.grossMinor, metrics.currency)} gross · {metrics.paymentCount} payments</p>
        ))}</article>
      ))}</div>
    </details>
  </div>
);

export const SalesDashboardView = ({ dashboard, now = Date.now, timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone }: SalesDashboardViewProps) => {
  const [period, setPeriod] = useState<SalesPeriod>("today");
  const [state, setState] = useState<SalesDashboardState>({ kind: "loading" });
  const [refreshing, setRefreshing] = useState(false);
  const loadGeneration = useRef(0);
  const load = useCallback(async (): Promise<void> => {
    loadGeneration.current += 1;
    const generation = loadGeneration.current;
    setRefreshing(true);
    try {
      const query = buildSalesQuery(period, now(), timeZone);
      const nextState = await dashboard.load(query);
      if (nextState !== undefined && generation === loadGeneration.current) {
        setState(nextState);
      }
    } finally {
      if (generation === loadGeneration.current) {
        setRefreshing(false);
      }
    }
  }, [dashboard, now, period, timeZone]);

  useEffect(() => {
    setState({ kind: "loading" });
    void load();
  }, [load]);

  const snapshot = snapshotOf(state);
  return (
    <section class={`sales sales--${state.kind}`} aria-labelledby="sales-title" aria-busy={refreshing}>
      <div class="sales-heading">
        <div>
          <p class="eyebrow">Sales evidence</p>
          <h1 id="sales-title">{stateTitle(state)}</h1>
        </div>
        <label class="period">Period
          <select value={period} onChange={(event) => setPeriod(event.currentTarget.value as SalesPeriod)}>
            <option value="today">Today</option>
            <option value="seven_days">Last 7 days</option>
          </select>
        </label>
      </div>
      <div class="sales-live" role="status" aria-live="polite">
        {state.kind === "loading" && <p>No totals are shown until the backend projection is validated.</p>}
        {state.kind === "error" && <p>{state.message}</p>}
        {state.kind === "stale" && <p>Values remain visible for investigation, but must not be treated as current.</p>}
        {state.kind === "degraded" && <p>The projection is readable, with reconciliation work still outstanding.</p>}
        {state.kind === "no_events" && <p>The backend reported no payment events; zero values have not been invented.</p>}
        {(state.kind === "ready" || state.kind === "stale" || state.kind === "degraded") && state.revalidated && <p>Revalidated with the backend; the projection is unchanged.</p>}
      </div>
      {snapshot !== undefined && (
        <>
          {snapshot.current.currencies.length > 0 && <Totals snapshot={snapshot} />}
          <section class="confidence" aria-labelledby="confidence-title">
            <div><p class="eyebrow" id="confidence-title">Confidence</p><p>{reliabilityText(snapshot)}</p></div>
            <dl><div><dt>Unreconciled</dt><dd>{snapshot.reconciliation.unreconciledCount}</dd></div><div><dt>Maximum lag</dt><dd>{snapshot.reconciliation.lagSecondsMax} seconds</dd></div></dl>
            <p class="observed">Observed by server <time dateTime={snapshot.observedAt}>{snapshot.observedAt}</time> · snapshot <time dateTime={snapshot.snapshotAt}>{snapshot.snapshotAt}</time></p>
          </section>
          {snapshot.actionRequired.length > 0 && <section class="actions" aria-labelledby="actions-title"><h2 id="actions-title">Action required</h2><ul>{snapshot.actionRequired.map((item) => <li key={`${item.kind}-${item.action}`}>{actionCopy(item)}</li>)}</ul></section>}
          <ProgressiveDetails snapshot={snapshot} />
        </>
      )}
      <button class="sales-refresh" type="button" onClick={() => void load()} disabled={refreshing}>{refreshing ? "Refreshing…" : "Refresh sales"}</button>
    </section>
  );
};
