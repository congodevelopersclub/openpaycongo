export interface VerifiedAnalyticsPrincipal {
  readonly tenantId: string;
  readonly sessionCacheId: string;
}

export type AuthenticatedBootstrap =
  | { readonly kind: "verified"; readonly principal: VerifiedAnalyticsPrincipal }
  | { readonly kind: "missing" }
  | { readonly kind: "invalid" };

export interface AuthenticatedBootstrapPort {
  readonly fetch: (signal: AbortSignal) => Promise<VerifiedAnalyticsPrincipal>;
}

const identifier = /^[A-Za-z0-9._:-]{1,128}$/;

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === "object" && value !== null && !Array.isArray(value);
};

export const readAuthenticatedBootstrap = (value: unknown): AuthenticatedBootstrap => {
  if (value === undefined) {
    return { kind: "missing" };
  }
  if (!isRecord(value) || Object.keys(value).length !== 2) {
    return { kind: "invalid" };
  }
  const tenantId = value["tenant_id"];
  const sessionCacheId = value["session_cache_id"];
  if (typeof tenantId !== "string" || typeof sessionCacheId !== "string" || !identifier.test(tenantId) || !identifier.test(sessionCacheId)) {
    return { kind: "invalid" };
  }
  return { kind: "verified", principal: { tenantId, sessionCacheId } };
};
