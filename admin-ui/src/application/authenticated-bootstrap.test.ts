import { describe, expect, it } from "vitest";
import { readAuthenticatedBootstrap } from "./authenticated-bootstrap";

describe("readAuthenticatedBootstrap", () => {
  it("fails closed unless both verified principal fields are exact", () => {
    expect(readAuthenticatedBootstrap(undefined)).toEqual({ kind: "missing" });
    expect(readAuthenticatedBootstrap({ tenant_id: "tenant", session_cache_id: "session", extra: true })).toEqual({ kind: "invalid" });
    expect(readAuthenticatedBootstrap({ tenant_id: "tenant/unsafe", session_cache_id: "session" })).toEqual({ kind: "invalid" });
    expect(readAuthenticatedBootstrap({ tenant_id: "tenant-a", session_cache_id: "session-1" })).toEqual({
      kind: "verified",
      principal: { tenantId: "tenant-a", sessionCacheId: "session-1" }
    });
  });
});
