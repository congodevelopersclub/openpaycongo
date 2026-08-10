import type { SalesAnalyticsSnapshot, SalesQuery } from "../domain/sales-analytics";
import { hasEvents } from "../domain/sales-analytics";
import type { VerifiedAnalyticsPrincipal } from "./authenticated-bootstrap";

export type AnalyticsFetchResult =
  | { readonly kind: "modified"; readonly snapshot: SalesAnalyticsSnapshot; readonly etag: string }
  | { readonly kind: "not_modified"; readonly etag: string };

export interface AnalyticsPort {
  readonly fetch: (query: SalesQuery, signal: AbortSignal, expectedTenantId?: string, etag?: string) => Promise<AnalyticsFetchResult>;
}

export type SalesDashboardState =
  | { readonly kind: "loading" }
  | { readonly kind: "ready"; readonly snapshot: SalesAnalyticsSnapshot; readonly revalidated: boolean }
  | { readonly kind: "no_events"; readonly snapshot: SalesAnalyticsSnapshot; readonly revalidated: boolean }
  | { readonly kind: "stale"; readonly snapshot: SalesAnalyticsSnapshot; readonly revalidated: boolean }
  | { readonly kind: "degraded"; readonly snapshot: SalesAnalyticsSnapshot; readonly revalidated: boolean }
  | { readonly kind: "error"; readonly message: string };

interface CacheEntry {
  readonly queryKey: string;
  readonly cacheScope: string;
  readonly tenantId: string;
  readonly etag: string;
  readonly snapshot: SalesAnalyticsSnapshot;
}

const queryKey = (query: SalesQuery): string => {
  return `${query.from}|${query.to}|${query.snapshotAt}|${query.timeZone}|${query.interval}|${query.comparison ? "1" : "0"}`;
};

export class SalesDashboard {
  private cache: CacheEntry | undefined;
  private active: AbortController | undefined;
  private generation = 0;

  public constructor(private readonly port: AnalyticsPort, private readonly principal: VerifiedAnalyticsPrincipal) {
    const valid = /^[A-Za-z0-9._:-]{1,128}$/;
    if (!valid.test(principal.tenantId) || !valid.test(principal.sessionCacheId)) {
      throw new Error("Invalid verified analytics principal.");
    }
  }

  public async load(query: SalesQuery): Promise<SalesDashboardState | undefined> {
    this.generation += 1;
    const generation = this.generation;
    this.active?.abort("superseded analytics request");
    const controller = new AbortController();
    this.active = controller;
    const state = await this.performLoad(query, controller.signal);
    if (generation !== this.generation) {
      return undefined;
    }
    if (this.active === controller) {
      this.active = undefined;
    }
    return state;
  }

  public dispose(): void {
    this.generation += 1;
    this.active?.abort("authenticated analytics principal changed");
    this.active = undefined;
    this.cache = undefined;
  }

  private async performLoad(query: SalesQuery, signal: AbortSignal): Promise<SalesDashboardState> {
    const key = queryKey(query);
    const cached = this.cache?.queryKey === key && this.cache.cacheScope === this.principal.sessionCacheId && this.cache.tenantId === this.principal.tenantId ? this.cache : undefined;
    try {
      const result = await this.port.fetch(query, signal, this.principal.tenantId, cached?.etag);
      if (result.kind === "not_modified") {
        if (cached === undefined || result.etag !== cached.etag) {
          return { kind: "error", message: "The analytics cache could not be safely revalidated." };
        }
        return this.classify(cached.snapshot, true);
      }
      if (result.snapshot.etag !== result.etag) {
        return { kind: "error", message: "The analytics response ETag is inconsistent." };
      }
      if (result.snapshot.tenantId !== this.principal.tenantId) {
        this.cache = undefined;
        return { kind: "error", message: "The analytics response does not match the authenticated tenant." };
      }
      this.cache = { queryKey: key, cacheScope: this.principal.sessionCacheId, tenantId: this.principal.tenantId, etag: result.etag, snapshot: result.snapshot };
      return this.classify(result.snapshot, false);
    } catch {
      return { kind: "error", message: "Sales analytics are unavailable. No current totals can be shown." };
    }
  }

  private classify(snapshot: SalesAnalyticsSnapshot, revalidated: boolean): SalesDashboardState {
    if (snapshot.sync.status === "no_events" || !hasEvents(snapshot)) {
      return { kind: "no_events", snapshot, revalidated };
    }
    if (snapshot.sync.status === "stale") {
      return { kind: "stale", snapshot, revalidated };
    }
    if (snapshot.actionRequired.length > 0 || BigInt(snapshot.reconciliation.unreconciledCount) > 0n) {
      return { kind: "degraded", snapshot, revalidated };
    }
    return { kind: "ready", snapshot, revalidated };
  }
}
