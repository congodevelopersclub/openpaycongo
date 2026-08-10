import { useCallback, useEffect, useMemo, useRef, useState } from "preact/hooks";
import type { WorkspaceState, ConnectionWorkspace } from "../application/connection-workspace";
import type { AuthenticatedBootstrapPort, VerifiedAnalyticsPrincipal } from "../application/authenticated-bootstrap";
import { SalesDashboard, type AnalyticsPort } from "../application/sales-dashboard";
import { App } from "./app";

export const authenticatedPrincipalChangedEvent = "openpay:authenticated-principal-changed";

export interface AuthenticatedRootProps {
  readonly workspace: ConnectionWorkspace;
  readonly initialState: WorkspaceState;
  readonly analyticsPort: AnalyticsPort;
  readonly bootstrapPort: AuthenticatedBootstrapPort;
}

type BootstrapState =
  | { readonly kind: "loading" }
  | { readonly kind: "verified"; readonly principal: VerifiedAnalyticsPrincipal }
  | { readonly kind: "failed" };

interface VerifiedRootProps {
  readonly workspace: ConnectionWorkspace;
  readonly initialState: WorkspaceState;
  readonly analyticsPort: AnalyticsPort;
  readonly principal: VerifiedAnalyticsPrincipal;
}

const VerifiedRoot = ({ workspace, initialState, analyticsPort, principal }: VerifiedRootProps) => {
  const dashboard = useMemo(() => new SalesDashboard(analyticsPort, principal), [analyticsPort, principal.sessionCacheId, principal.tenantId]);
  useEffect(() => {
    return () => dashboard.dispose();
  }, [dashboard]);
  const identity = `${principal.tenantId}:${principal.sessionCacheId}`;
  return <App key={identity} workspace={workspace} initialState={initialState} salesDashboard={dashboard} />;
};

export const AuthenticatedRoot = ({ workspace, initialState, analyticsPort, bootstrapPort }: AuthenticatedRootProps) => {
  const [bootstrap, setBootstrap] = useState<BootstrapState>({ kind: "loading" });
  const generation = useRef(0);
  const active = useRef<AbortController | undefined>(undefined);

  const refreshBootstrap = useCallback(async (): Promise<void> => {
    generation.current += 1;
    const requestGeneration = generation.current;
    active.current?.abort("superseded bootstrap request");
    const controller = new AbortController();
    active.current = controller;
    setBootstrap({ kind: "loading" });
    try {
      const principal = await bootstrapPort.fetch(controller.signal);
      if (requestGeneration === generation.current) {
        setBootstrap({ kind: "verified", principal });
      }
    } catch {
      if (requestGeneration === generation.current) {
        setBootstrap({ kind: "failed" });
      }
    } finally {
      if (active.current === controller) {
        active.current = undefined;
      }
    }
  }, [bootstrapPort]);

  useEffect(() => {
    const refreshWhenVisible = (): void => {
      if (document.visibilityState === "visible") {
        void refreshBootstrap();
      }
    };
    const refresh = (): void => {
      void refreshBootstrap();
    };
    void refreshBootstrap();
    const poll = window.setInterval(refresh, 30_000);
    window.addEventListener("focus", refresh);
    window.addEventListener(authenticatedPrincipalChangedEvent, refresh);
    document.addEventListener("visibilitychange", refreshWhenVisible);
    return () => {
      generation.current += 1;
      active.current?.abort("authenticated root unmounted");
      window.clearInterval(poll);
      window.removeEventListener("focus", refresh);
      window.removeEventListener(authenticatedPrincipalChangedEvent, refresh);
      document.removeEventListener("visibilitychange", refreshWhenVisible);
    };
  }, [refreshBootstrap]);

  if (bootstrap.kind !== "verified") {
    return (
      <main class="shell auth-failure" role="alert">
        <p class="eyebrow">{bootstrap.kind === "loading" ? "Checking authentication" : "Authentication required"}</p>
        <h1>{bootstrap.kind === "loading" ? "Checking your secure session" : "Sign in before viewing payment data"}</h1>
        <p>{bootstrap.kind === "loading" ? "Sales totals remain hidden during verification." : "Authenticated tenant configuration is missing or invalid. Sales totals are hidden."}</p>
      </main>
    );
  }

  return <VerifiedRoot workspace={workspace} initialState={initialState} analyticsPort={analyticsPort} principal={bootstrap.principal} />;
};
