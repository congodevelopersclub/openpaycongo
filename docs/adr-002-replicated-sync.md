# ADR 002: Replicated immutable sync

## Decision

Use push, pull, and acknowledgement endpoints over canonical immutable events. Idempotency is keyed by tenant and idempotency key, with a payload digest to detect conflicting reuse.

## Consequences

Retries are safe only when they retain the original key and digest. Duplicate delivery returns the original outcome; altered reuse returns `409`. Event projections and provider integrations remain downstream of durable event persistence.
