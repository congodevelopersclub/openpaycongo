import { render } from "preact";
import { ConnectionWorkspace, type Clock, type Random } from "./application/connection-workspace";
import { HttpConnectionPort, type DeadlineScheduler } from "./infrastructure/http-connection-port";
import { HttpAnalyticsPort } from "./infrastructure/http-analytics-port";
import { AuthenticatedRoot } from "./ui/authenticated-root";
import { HttpAuthenticatedBootstrapPort } from "./infrastructure/http-authenticated-bootstrap-port";
import "./ui/style.css";
const clock: Clock = { now: () => Date.now() };
const random: Random = { next: () => Math.random() };
const scheduler: DeadlineScheduler = {
  schedule: (operation, delayMs) => setTimeout(operation, delayMs),
  cancel: (handle) => clearTimeout(handle)
};
const port = new HttpConnectionPort({ fetch: window.fetch.bind(window) }, { value: "/backend" }, clock.now, scheduler);
const workspace = new ConnectionWorkspace(port, clock, random);
const analyticsPort = new HttpAnalyticsPort({ fetch: window.fetch.bind(window) }, scheduler);
const bootstrapPort = new HttpAuthenticatedBootstrapPort({ fetch: window.fetch.bind(window) }, scheduler);
const mount = document.getElementById("app");
if (mount === null) {
  throw new Error("Admin UI mount element is missing.");
}
render(<AuthenticatedRoot workspace={workspace} initialState={{ kind: "loading", circuit: "closed" }} analyticsPort={analyticsPort} bootstrapPort={bootstrapPort} />, mount);
