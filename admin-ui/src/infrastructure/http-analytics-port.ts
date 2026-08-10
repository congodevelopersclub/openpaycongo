import type { AnalyticsFetchResult, AnalyticsPort } from "../application/sales-dashboard";
import type {
  ActionKind,
  ActionName,
  ActionRequired,
  CurrencyMetrics,
  ProviderMetrics,
  SalesAnalyticsSnapshot,
  SalesQuery,
  SalesSync,
  SalesWindow
} from "../domain/sales-analytics";
import type { DeadlineScheduler, FetchLike } from "./http-connection-port";
import { BoundaryFailure, isRecord, readBoundedJsonObject } from "./bounded-json";

const maximumAnalyticsBytes = 524_288;
const requestDeadlineMilliseconds = 3_000;
const utcSecond = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;
const hash = /^[a-f0-9]{64}$/;
const etagPattern = /^"[a-f0-9]{64}"$/;
const countPattern = /^(0|[1-9][0-9]*)$/;
const amountPattern = /^-?(0|[1-9][0-9]{0,25})$/;
const identifierPattern = /^[A-Za-z0-9._:-]{1,128}$/;
const currencyPattern = /^[A-Z]{3}$/;

export type AnalyticsFailureKind = "aborted" | "http" | "mime" | "oversize" | "shape" | "network";

export class AnalyticsFailure extends Error {
  public constructor(public readonly kind: AnalyticsFailureKind, message: string) {
    super(message);
    this.name = "AnalyticsFailure";
  }
}

const assertExactKeys = (record: Record<string, unknown>, required: readonly string[], optional: readonly string[] = []): void => {
  const allowed = new Set([...required, ...optional]);
  const invalid = required.some((key) => !(key in record)) || Object.keys(record).some((key) => !allowed.has(key));
  if (invalid) {
    throw new AnalyticsFailure("shape", "Analytics response contains missing or unexpected fields.");
  }
};

const objectField = (record: Record<string, unknown>, name: string): Record<string, unknown> => {
  const value = record[name];
  if (!isRecord(value)) {
    throw new AnalyticsFailure("shape", `Invalid ${name}.`);
  }
  return value;
};

const stringField = (record: Record<string, unknown>, name: string, pattern: RegExp, maximumLength = 128): string => {
  const value = record[name];
  if (typeof value !== "string" || value.length > maximumLength || !pattern.test(value)) {
    throw new AnalyticsFailure("shape", `Invalid ${name}.`);
  }
  return value;
};

const timestampField = (record: Record<string, unknown>, name: string): string => {
  const value = stringField(record, name, utcSecond, 20);
  if (Number.isNaN(Date.parse(value))) {
    throw new AnalyticsFailure("shape", `Invalid ${name}.`);
  }
  return value;
};

const arrayField = (record: Record<string, unknown>, name: string, maximum: number): readonly unknown[] => {
  const value = record[name];
  if (!Array.isArray(value) || value.length > maximum) {
    throw new AnalyticsFailure("shape", `Invalid ${name}.`);
  }
  return value;
};

const decodeCurrency = (value: unknown): CurrencyMetrics => {
  if (!isRecord(value)) {
    throw new AnalyticsFailure("shape", "Invalid currency metrics.");
  }
  assertExactKeys(value, ["currency", "gross_minor", "refunds_minor", "net_minor", "payment_count", "refund_count", "average_ticket_minor"]);
  return {
    currency: stringField(value, "currency", currencyPattern, 3),
    grossMinor: stringField(value, "gross_minor", amountPattern, 27),
    refundsMinor: stringField(value, "refunds_minor", amountPattern, 27),
    netMinor: stringField(value, "net_minor", amountPattern, 27),
    paymentCount: stringField(value, "payment_count", countPattern, 26),
    refundCount: stringField(value, "refund_count", countPattern, 26),
    averageTicketMinor: stringField(value, "average_ticket_minor", amountPattern, 27)
  };
};

const decodeProvider = (value: unknown): ProviderMetrics => {
  if (!isRecord(value)) {
    throw new AnalyticsFailure("shape", "Invalid provider metrics.");
  }
  assertExactKeys(value, ["provider", "currencies"]);
  return {
    provider: stringField(value, "provider", identifierPattern),
    currencies: arrayField(value, "currencies", 16).map(decodeCurrency)
  };
};

const decodeWindow = (value: unknown): SalesWindow => {
  if (!isRecord(value)) {
    throw new AnalyticsFailure("shape", "Invalid analytics window.");
  }
  assertExactKeys(value, ["from", "to", "currencies", "providers"]);
  const from = timestampField(value, "from");
  const to = timestampField(value, "to");
  if (Date.parse(from) >= Date.parse(to)) {
    throw new AnalyticsFailure("shape", "Analytics window must have a positive duration.");
  }
  return {
    from,
    to,
    currencies: arrayField(value, "currencies", 16).map(decodeCurrency),
    providers: arrayField(value, "providers", 64).map(decodeProvider)
  };
};

const actionKinds: readonly ActionKind[] = ["late_arrival", "orphan_correction", "over_refund", "reconciliation_overdue", "stale_sync", "correction_after_void", "correction_mismatch", "lifecycle_conflict"];
const actionNames: readonly ActionName[] = ["review_offline_sync", "repair_event_linkage", "review_refund_total", "reconcile_provider", "check_replica_sync", "review_correction_order", "review_correction_identity", "review_correction_lifecycle"];

const enumField = <T extends string>(record: Record<string, unknown>, name: string, values: readonly T[]): T => {
  const value = record[name];
  const match = values.find((candidate) => candidate === value);
  if (match === undefined) {
    throw new AnalyticsFailure("shape", `Invalid ${name}.`);
  }
  return match;
};

const decodeAction = (value: unknown): ActionRequired => {
  if (!isRecord(value)) {
    throw new AnalyticsFailure("shape", "Invalid action-required item.");
  }
  assertExactKeys(value, ["kind", "count", "action"]);
  return {
    kind: enumField(value, "kind", actionKinds),
    count: stringField(value, "count", countPattern, 26),
    action: enumField(value, "action", actionNames)
  };
};

const decodeSync = (value: Record<string, unknown>): SalesSync => {
  const status = enumField(value, "status", ["no_events", "fresh", "stale"] as const);
  if (status === "no_events") {
    assertExactKeys(value, ["status"]);
    return { status };
  }
  assertExactKeys(value, ["status", "last_received_at", "freshness_seconds"]);
  return {
    status,
    lastReceivedAt: timestampField(value, "last_received_at"),
    freshnessSeconds: stringField(value, "freshness_seconds", countPattern, 26)
  };
};

export const decodeSalesAnalytics = (record: Record<string, unknown>): SalesAnalyticsSnapshot => {
  assertExactKeys(record, ["contract_version", "projection_version", "readiness", "tenant_id", "snapshot_at", "observed_at", "time_zone", "current", "series", "reconciliation", "sync", "action_required", "etag"], ["comparison"]);
  if (record["contract_version"] !== "sales-analytics-v1" || record["readiness"] !== "ready") {
    throw new AnalyticsFailure("shape", "Unsupported analytics contract or readiness state.");
  }
  const reconciliation = objectField(record, "reconciliation");
  assertExactKeys(reconciliation, ["lag_seconds_max", "unreconciled_count"]);
  const base = {
    contractVersion: "sales-analytics-v1" as const,
    projectionVersion: stringField(record, "projection_version", hash, 64),
    readiness: "ready" as const,
    tenantId: stringField(record, "tenant_id", identifierPattern),
    snapshotAt: timestampField(record, "snapshot_at"),
    observedAt: timestampField(record, "observed_at"),
    timeZone: stringField(record, "time_zone", /^.{1,64}$/u, 64),
    current: decodeWindow(record["current"]),
    series: arrayField(record, "series", 500).map(decodeWindow),
    reconciliation: {
      lagSecondsMax: stringField(reconciliation, "lag_seconds_max", countPattern, 26),
      unreconciledCount: stringField(reconciliation, "unreconciled_count", countPattern, 26)
    },
    sync: decodeSync(objectField(record, "sync")),
    actionRequired: arrayField(record, "action_required", 32).map(decodeAction),
    etag: stringField(record, "etag", etagPattern, 66)
  };
  if (record["comparison"] === undefined) {
    return base;
  }
  return { ...base, comparison: decodeWindow(record["comparison"]) };
};

const validateQuery = (query: SalesQuery): void => {
  const timestampsValid = utcSecond.test(query.from) && utcSecond.test(query.to) && utcSecond.test(query.snapshotAt);
  const rangeMilliseconds = Date.parse(query.to) - Date.parse(query.from);
  const rangeValid = rangeMilliseconds >= 60_000 && rangeMilliseconds <= 93 * 86_400_000 && Date.parse(query.to) <= Date.parse(query.snapshotAt);
  if (!timestampsValid || !rangeValid || query.timeZone.length === 0 || query.timeZone.length > 64) {
    throw new AnalyticsFailure("shape", "Invalid analytics query.");
  }
};

const requireCacheHeaders = (response: Response): string => {
  const etag = response.headers.get("etag") ?? "";
  const cacheControl = response.headers.get("cache-control") ?? "";
  const vary = response.headers.get("vary") ?? "";
  const exactCacheControl = cacheControl.toLowerCase() === "private, max-age=30, must-revalidate";
  const exactVary = vary.trim().toLowerCase() === "authorization";
  if (!etagPattern.test(etag) || !exactCacheControl || !exactVary) {
    throw new AnalyticsFailure("shape", "Analytics cache headers are unsafe or incomplete.");
  }
  return etag;
};

const compareCurrency = (left: CurrencyMetrics, right: CurrencyMetrics): boolean => {
  return left.currency === right.currency
    && left.grossMinor === right.grossMinor
    && left.refundsMinor === right.refundsMinor
    && left.netMinor === right.netMinor
    && left.paymentCount === right.paymentCount
    && left.refundCount === right.refundCount
    && left.averageTicketMinor === right.averageTicketMinor;
};

const sumCurrency = (items: readonly CurrencyMetrics[], currency: string): CurrencyMetrics => {
  const matching = items.filter((item) => item.currency === currency);
  const sum = (select: (item: CurrencyMetrics) => string): string => matching.reduce((total, item) => total + BigInt(select(item)), 0n).toString();
  const grossMinor = sum((item) => item.grossMinor);
  const paymentCount = sum((item) => item.paymentCount);
  const count = BigInt(paymentCount);
  const gross = BigInt(grossMinor);
  const averageTicketMinor = count === 0n ? "0" : ((gross * 2n + count) / (count * 2n)).toString();
  return {
    currency,
    grossMinor,
    refundsMinor: sum((item) => item.refundsMinor),
    netMinor: sum((item) => item.netMinor),
    paymentCount,
    refundCount: sum((item) => item.refundCount),
    averageTicketMinor
  };
};

const requireOrderedUnique = (values: readonly string[], label: string): void => {
  for (let index = 0; index < values.length; index += 1) {
    const previous = values[index - 1];
    const current = values[index];
    if (current === undefined || (previous !== undefined && previous >= current)) {
      throw new AnalyticsFailure("shape", `${label} must be unique and lexically ordered.`);
    }
  }
};

const validateMetrics = (metrics: CurrencyMetrics): void => {
  const gross = BigInt(metrics.grossMinor);
  const refunds = BigInt(metrics.refundsMinor);
  const net = BigInt(metrics.netMinor);
  const payments = BigInt(metrics.paymentCount);
  const average = BigInt(metrics.averageTicketMinor);
  if (gross < 0n || refunds < 0n || average < 0n || net !== gross - refunds) {
    throw new AnalyticsFailure("shape", `Invalid ${metrics.currency} financial arithmetic.`);
  }
  const expectedAverage = payments === 0n ? 0n : (gross * 2n + payments) / (payments * 2n);
  if ((payments === 0n && gross !== 0n) || average !== expectedAverage) {
    throw new AnalyticsFailure("shape", `Invalid ${metrics.currency} average ticket.`);
  }
};

const validateWindowMetrics = (window: SalesWindow): void => {
  requireOrderedUnique(window.currencies.map((item) => item.currency), "Currencies");
  requireOrderedUnique(window.providers.map((item) => item.provider), "Providers");
  window.currencies.forEach(validateMetrics);
  const currencyNames = new Set(window.currencies.map((item) => item.currency));
  for (const provider of window.providers) {
    requireOrderedUnique(provider.currencies.map((item) => item.currency), `Provider ${provider.provider} currencies`);
    provider.currencies.forEach(validateMetrics);
    if (provider.currencies.some((item) => !currencyNames.has(item.currency))) {
      throw new AnalyticsFailure("shape", "Provider metrics contain an unknown window currency.");
    }
  }
  const providerCurrencies = window.providers.flatMap((provider) => provider.currencies);
  for (const expected of window.currencies) {
    const aggregate = sumCurrency(providerCurrencies, expected.currency);
    if (!compareCurrency(expected, aggregate)) {
      throw new AnalyticsFailure("shape", `Provider totals do not reconcile for ${expected.currency}.`);
    }
  }
};

const actionPairs: Readonly<Record<ActionKind, ActionName>> = {
  late_arrival: "review_offline_sync",
  orphan_correction: "repair_event_linkage",
  over_refund: "review_refund_total",
  reconciliation_overdue: "reconcile_provider",
  stale_sync: "check_replica_sync",
  correction_after_void: "review_correction_order",
  correction_mismatch: "review_correction_identity",
  lifecycle_conflict: "review_correction_lifecycle"
};

const validateActions = (actions: readonly ActionRequired[]): void => {
  requireOrderedUnique(actions.map((item) => item.kind), "Action-required kinds");
  for (const item of actions) {
    if (actionPairs[item.kind] !== item.action || BigInt(item.count) === 0n) {
      throw new AnalyticsFailure("shape", "Invalid action-required kind, action, or count.");
    }
  }
};

const validateSeries = (snapshot: SalesAnalyticsSnapshot): void => {
  if (snapshot.series.length === 0) {
    if (snapshot.current.currencies.length !== 0) {
      throw new AnalyticsFailure("shape", "A non-empty projection requires bounded series evidence.");
    }
    return;
  }
  let boundary = snapshot.current.from;
  for (const bucket of snapshot.series) {
    if (bucket.from !== boundary || Date.parse(bucket.to) <= Date.parse(bucket.from) || Date.parse(bucket.to) > Date.parse(snapshot.current.to)) {
      throw new AnalyticsFailure("shape", "Analytics series windows must be ordered, contiguous, and bounded.");
    }
    validateWindowMetrics(bucket);
    boundary = bucket.to;
  }
  if (boundary !== snapshot.current.to) {
    throw new AnalyticsFailure("shape", "Analytics series does not cover the requested window.");
  }
  const seriesCurrencies = snapshot.series.flatMap((window) => window.currencies);
  const currentCurrencyNames = new Set(snapshot.current.currencies.map((item) => item.currency));
  if (seriesCurrencies.some((item) => !currentCurrencyNames.has(item.currency))) {
    throw new AnalyticsFailure("shape", "Analytics series contains an unexpected currency.");
  }
  for (const expected of snapshot.current.currencies) {
    if (!compareCurrency(expected, sumCurrency(seriesCurrencies, expected.currency))) {
      throw new AnalyticsFailure("shape", `Series totals do not reconcile for ${expected.currency}.`);
    }
  }
};

const validateSnapshot = (snapshot: SalesAnalyticsSnapshot, query: SalesQuery, expectedTenantId?: string): void => {
  const queryBound = snapshot.snapshotAt === query.snapshotAt
    && snapshot.timeZone === query.timeZone
    && snapshot.current.from === query.from
    && snapshot.current.to === query.to;
  if (!queryBound || (expectedTenantId !== undefined && snapshot.tenantId !== expectedTenantId)) {
    throw new AnalyticsFailure("shape", "Analytics response is not bound to the requested query and principal.");
  }
  if (Date.parse(snapshot.observedAt) < Date.parse(snapshot.snapshotAt)) {
    throw new AnalyticsFailure("shape", "Server observation predates the immutable snapshot.");
  }
  if (snapshot.sync.status !== "no_events" && Date.parse(snapshot.sync.lastReceivedAt) > Date.parse(snapshot.snapshotAt)) {
    throw new AnalyticsFailure("shape", "Analytics source watermark exceeds the immutable snapshot.");
  }
  if (snapshot.sync.status !== "no_events") {
    const freshnessMilliseconds = Date.parse(snapshot.observedAt) - Date.parse(snapshot.sync.lastReceivedAt);
    const exactSeconds = freshnessMilliseconds >= 0 && freshnessMilliseconds % 1_000 === 0;
    if (!exactSeconds || BigInt(freshnessMilliseconds / 1_000) !== BigInt(snapshot.sync.freshnessSeconds)) {
      throw new AnalyticsFailure("shape", "Analytics sync freshness is inconsistent with trusted clocks.");
    }
    const shouldBeStale = BigInt(snapshot.sync.freshnessSeconds) > 900n;
    if ((snapshot.sync.status === "stale") !== shouldBeStale) {
      throw new AnalyticsFailure("shape", "Analytics sync state contradicts its freshness threshold.");
    }
  }
  validateWindowMetrics(snapshot.current);
  if (query.comparison !== (snapshot.comparison !== undefined)) {
    throw new AnalyticsFailure("shape", "Analytics comparison presence does not match the request.");
  }
  if (snapshot.comparison !== undefined) {
    const duration = Date.parse(query.to) - Date.parse(query.from);
    const expectedFrom = new Date(Date.parse(query.from) - duration).toISOString().replace(".000Z", "Z");
    if (snapshot.comparison.to !== query.from || snapshot.comparison.from !== expectedFrom) {
      throw new AnalyticsFailure("shape", "Comparison is not the immediately preceding equal-duration window.");
    }
    validateWindowMetrics(snapshot.comparison);
  }
  validateSeries(snapshot);
  validateActions(snapshot.actionRequired);
};

export class HttpAnalyticsPort implements AnalyticsPort {
  public constructor(
    private readonly client: FetchLike,
    private readonly scheduler: DeadlineScheduler
  ) {}

  public async fetch(query: SalesQuery, signal: AbortSignal, expectedTenantId?: string, etag?: string): Promise<AnalyticsFetchResult> {
    validateQuery(query);
    if (etag !== undefined && !etagPattern.test(etag)) {
      throw new AnalyticsFailure("shape", "Invalid cached analytics ETag.");
    }
    const controller = new AbortController();
    const abortFromCaller = (): void => controller.abort(signal.reason);
    signal.addEventListener("abort", abortFromCaller, { once: true });
    if (signal.aborted) {
      abortFromCaller();
    }
    const deadline = this.scheduler.schedule(() => controller.abort(), requestDeadlineMilliseconds);
    try {
      const response = await this.client.fetch(this.url(query), {
        method: "GET",
        cache: "no-store",
        credentials: "same-origin",
        redirect: "error",
        signal: controller.signal,
        headers: etag === undefined
          ? { accept: "application/json" }
          : { accept: "application/json", "if-none-match": etag }
      });
      if (response.status === 304) {
        const responseEtag = requireCacheHeaders(response);
        await response.body?.cancel();
        return { kind: "not_modified", etag: responseEtag };
      }
      if (response.status !== 200) {
        await response.body?.cancel();
        throw new AnalyticsFailure("http", `Analytics returned HTTP ${response.status}.`);
      }
      let responseEtag: string;
      try {
        responseEtag = requireCacheHeaders(response);
      } catch (error: unknown) {
        await response.body?.cancel();
        throw error;
      }
      const snapshot = decodeSalesAnalytics(await readBoundedJsonObject(response, maximumAnalyticsBytes));
      if (snapshot.etag !== responseEtag) {
        throw new AnalyticsFailure("shape", "Analytics body and response ETags differ.");
      }
      validateSnapshot(snapshot, query, expectedTenantId);
      return { kind: "modified", snapshot, etag: responseEtag };
    } catch (error: unknown) {
      if (error instanceof AnalyticsFailure) {
        throw error;
      }
      if (error instanceof BoundaryFailure) {
        throw new AnalyticsFailure(error.kind, error.message);
      }
      if (controller.signal.aborted) {
        throw new AnalyticsFailure("aborted", "Analytics request deadline exceeded.");
      }
      throw new AnalyticsFailure("network", "Analytics request failed.");
    } finally {
      signal.removeEventListener("abort", abortFromCaller);
      this.scheduler.cancel(deadline);
    }
  }

  private url(query: SalesQuery): string {
    const parameters = new URLSearchParams({
      from: query.from,
      to: query.to,
      snapshot_at: query.snapshotAt,
      time_zone: query.timeZone,
      interval: query.interval,
      comparison: query.comparison ? "true" : "false"
    });
    return `/backend/v1/analytics/sales?${parameters.toString()}`;
  }
}
