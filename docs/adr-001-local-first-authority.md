# ADR 001: Local-first authority

## Decision

The mobile device is authoritative for locally durably recorded inbox/outbox intent; the backend is authoritative for replicated, acknowledged ledger history. Balance is derived, not independently editable.

## Consequences

Offline capture works without pretending network delivery succeeded. Recovery needs durable local state, server replication, and a third authority for simultaneous device/server loss. The current prototypes do not yet meet this decision.
