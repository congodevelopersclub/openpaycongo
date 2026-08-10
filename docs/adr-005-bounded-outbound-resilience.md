# ADR 005: Bounded outbound retries and circuit breaking

Status: accepted contract; not implemented because the pairing core has no outbound port.

Every future outbound adapter receives a `RetryPolicy` value; no adapter owns an infinite retry loop.
The policy includes maximum attempts (1-5), overall deadline (at most 30 seconds), base delay, maximum
delay, retry classifier, and a randomness port. Full-jitter delay is uniformly selected from
`[0, min(max_delay, base_delay * 2^attempt)]`; overflow is checked before multiplication. The overall
deadline wins over attempt count. `Retry-After` may shorten attempt availability but may not extend the
deadline.

Only transport timeouts/resets and HTTP 408, 429, 502, 503, and 504 are retryable. Authentication,
authorization, validation, cryptographic verification, replay conflict, and every other 4xx result are
terminal. Retried requests retain their original idempotency key and bytes.

The circuit has explicit `closed`, `open`, and `half_open` states. Each policy fixes a bounded observation
window, failure threshold, open duration, and half-open probe maximum. An open circuit rejects without
network I/O. After the open duration, no more than the probe maximum may run; one success closes the
circuit and a classified failure reopens it. State transition time comes from a clock port.

Required deterministic vectors for the implementation slice:

| Attempt | Base | Maximum | RNG fraction | Expected full-jitter delay |
| --- | ---: | ---: | ---: | ---: |
| 0 | 100 ms | 2 s | 0 | 0 ms |
| 1 | 100 ms | 2 s | 0.5 | 100 ms |
| 4 | 100 ms | 2 s | 1.0 | 1.6 s |
| 8 | 100 ms | 2 s | 1.0 | 2 s |

Tests must also prove deadline exhaustion, terminal classification, one half-open probe under concurrency,
and that a circuit transition never changes the idempotency key.
