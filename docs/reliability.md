# Reliability and recovery

Status: design requirements, not implemented behavior.

The inbox/outbox writes locally before attempting network delivery. A retry worker uses bounded exponential backoff with jitter, preserves idempotency keys, and reports pending/failed/acknowledged states without silently dropping events. Pull and acknowledgement use opaque cursors so a device can resume after app restart, network loss, or duplicated responses.

| Loss scenario | Recovery source | Required outcome |
| --- | --- | --- |
| Network unavailable | Local durable outbox | Retry without generating a new event identity or idempotency key |
| App/process loss | Local inbox/outbox | Resume pending work after local integrity check |
| Device loss, server retained | Replicated backend ledger | Re-enrol device, pull authorized history, then rebuild local projection |
| Server loss, device retained | Device inbox/outbox plus independently retained backups | Rebuild backend only after verified restore and replay policy |
| Both device and server lost | A third authority (merchant/provider export, escrowed backup, or another independently retained ledger) | No truthful automatic reconstruction is possible without that authority |

Operational endpoints are separate from business sync: `/healthz` proves process liveness, `/readyz` proves dependencies and migration/readiness, and `/version` identifies the deployed build and contract version. CI/release evidence must include schema validation, API contract tests, migration/recovery rehearsal, signed mobile/container artifacts, SBOM/provenance, vulnerability review, and a post-deploy readiness check.

Acknowledgements bind to the authenticated tenant and replica plus `ledger:ack` scope. They are monotonic and idempotent: an older cursor is a no-op success, an invalid cursor is a problem response, and a future/unissued cursor is rejected. `/readyz` returns non-secret structured component status for datastore reachability, migration revision, topology/capability, projection health, and write admission; unsupported Mongo topology is not ready. `/version` reports build, implementation, adapter, migration revision, and contract version.

Recovery exports are versioned NDJSON: a manifest identifies contract/export version, tenant, ordering definition, count, per-record and aggregate digests, migration checksums, and projection revision. Restore verifies all checksums/digests, rebuilds projections from immutable events, and invalidates or reissues cursors before serving traffic. Problems, logs, and traces must never echo request bodies, raw SMS, credentials, secrets, or digests that reveal them.
