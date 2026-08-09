# ADR 003: Parser proposals are untrusted evidence

## Decision

Parser updates are proposals, never automatic authority. A parser proposal records sender identity/trust evidence, sample provenance, version, review decision, and rollout scope. Sender trust is explicit: a parsed text does not prove that its sender is a payment provider.

## Consequences

The mobile UI must show parser identity, version, trust state, and why an event was accepted, pending, or rejected. An optional on-device Gemma 4-assisted proposal may help suggest a parser or explain a mismatch only with explicit consent, redacted inputs, deterministic validation, and human approval; it cannot create ledger events or upgrade sender trust.

Before any event creation, normalize `SmsMessage.address` and require both an exact approved sender match and an active versioned parser. Capability discovery happens before Gemma UI; model/resource/runtime failure retains manual fallback, records model/runtime version plus input fingerprint when used, sends no background SMS to a model, and changes no parser/ledger state on failure.
