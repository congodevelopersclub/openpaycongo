# ADR 006: Fast Feedback Engineering Standard

Status: accepted for repository test and CI architecture on 2026-08-30.

This decision adapts (rather than copies) the [Fast Feedback Engineering Standard v1.0, 30 Aug 2026](https://fabrice-fast-feedback-standard.fabricekabongo.chatgpt.site/) to OpenPayCongo's Docker-only, security, migration, native-client, and release boundaries.

## Decision

OpenPayCongo uses the cheapest test capable of reliably falsifying the behavior being changed. Repository-owned Docker-only commands live in `scripts/ci/fast-feedback.sh`; CI orchestrates those commands and does not duplicate their test logic.

The tiers are:

| Tier | Purpose | Current OpenPayCongo mapping |
| --- | --- | --- |
| T0 focused seconds | One changed behavior during editing | Filtered contracts, Laravel, or Flutter Docker target. |
| T1 local under two minutes | Affected module plus format/lint/static checks | Per-component Docker `local` command. The two-minute budget is measured per warm component and remains a budget to enforce, not a claim for cold Flutter setup. |
| T2 PR under ten minutes | Unconditional required pull-request suite | Five CI jobs plus the three-database concurrency matrix and `security-fast`; baseline main run `33308396370` completed in 8m07s. |
| T3 main | Build one immutable deployable artifact | Not implemented: current main builds are not registry-published, revision-provenance-bearing immutable artifacts. The `main` command fails clearly until that foundation exists. |
| T4 deployment | Promote and verify that exact artifact in production-like deployment | Not implemented; the `deploy` command fails clearly and no deployment promotion evidence is claimed. |
| T5 scheduled | Compatibility, performance, migration, fuzz, soak, broad browser/device depth | Scheduled `security-full` preserves full security/SBOM depth. Broader compatibility, performance, migration rehearsal, fuzz, soak, and device/browser depth remain planned. |

T0 is for active edits. Run T1 once before handoff. T2 always runs for every pull request and must never be path-skipped. Small critical browser/device journeys belong in T2 when introduced; broad depth belongs in T5. Speed work uses caching, isolation, parallelism/sharding, stable fixtures, and removal of redundant reruns only after unique evidence is preserved.

## Consequences

The first migration slice centralizes existing Docker checks without reducing them. It preserves contract fixtures, Laravel formatting/static/tests, production image contracts and scans, PostgreSQL migration constraints, PostgreSQL/MySQL/MariaDB concurrency races, and Flutter analysis/tests/APK build. `security-fast` currently repeats some Docker work independently; retain it until branch-protection requirements and its independent negative-control value are proven, then measure any cache or workflow redesign before changing it.

The initial baseline meets T2 but not every maturity requirement. Next phases are immutable artifact digest publication and deployment verification (T3/T4), then scheduled compatibility/performance/migration/fuzz/soak and broad browser/device coverage (T5). Protected `main` currently requires all eight PR-applicable contexts with strict freshness: contract, laravel, postgres-migration, the three named database-concurrency jobs, flutter, and security-fast. Any job rename requires a coordinated required-status update; no path filtering is permitted.
