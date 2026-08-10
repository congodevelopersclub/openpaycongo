import { createServer } from "node:http";
const identity = { build: "test", contract_version: "1", implementation: "go", adapter: "sqlite", migration_revision: "0001" };
const readiness = { datastore: "ok", migration: "current", topology: "supported", projection: "healthy", write_admission: "open", contract_version: "1", implementation: "go", adapter: "sqlite", migration_revision: "0001" };
let mode = "ready";
const pendingReadiness = new Set();
const writeDegradedReadiness = (response) => {
  response.writeHead(503, { "content-type": "application/json" });
  response.end(JSON.stringify({ ...readiness, datastore: "failed", write_admission: "closed" }));
};
createServer((request, response) => {
  if (request.method === "POST" && request.url?.startsWith("/__mode/")) {
    const requestedMode = request.url.slice("/__mode/".length);
    if (requestedMode !== "ready" && requestedMode !== "degraded" && requestedMode !== "hang") {
      response.writeHead(422);
      response.end();
      return;
    }
    mode = requestedMode;
    if (mode === "degraded") {
      for (const pendingResponse of pendingReadiness) {
        writeDegradedReadiness(pendingResponse);
      }
      pendingReadiness.clear();
    }
    response.writeHead(204);
    response.end();
    return;
  }
  if (request.url === "/healthz") { response.writeHead(200, { "content-type": "text/plain" }); response.end("backend-ok"); return; }
  if (request.url === "/version") { response.writeHead(200, { "content-type": "application/json" }); response.end(JSON.stringify(identity)); return; }
  if (request.url === "/readyz" && mode === "hang") {
    pendingReadiness.add(response);
    request.once("close", () => pendingReadiness.delete(response));
    return;
  }
  if (request.url === "/readyz" && mode === "degraded") {
    writeDegradedReadiness(response);
    return;
  }
  if (request.url === "/readyz") { response.writeHead(200, { "content-type": "application/json" }); response.end(JSON.stringify(readiness)); return; }
  response.writeHead(404); response.end();
}).listen(9090, "0.0.0.0");
