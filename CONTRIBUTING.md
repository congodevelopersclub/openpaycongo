# Contributing to OpenPay Congo

OpenPay Congo is an early prototype. Do not use real payment, SMS, credential, or enrollment data in issues, tests, screenshots, commits, or pull requests.

## Before opening a pull request

- State the problem, affected public contract or user behavior, and intentionally out-of-scope work.
- Add a focused regression test or explain the strongest repeatable substitute.
- Run the relevant Docker command documented in the README and include the exact result.
- Describe compatibility, operational risk, and rollback.
- Keep commits independently reviewable; do not mix cleanup with a behavior or security change.

## Authority and security reporting

Contribution sign-off, licensing, and production release authority remain
maintainer decisions. Security-reporting roles, response targets, coordinated
disclosure, and emergency-release procedure are governed by
[`SECURITY.md`](SECURITY.md). Do not represent a private reporting channel as
available while repository settings show it is disabled.

## Review expectations

Reviewers should request reproducible evidence, preserve tenant and event authority boundaries, and reject changes that weaken tests, privacy, authorization, or recovery behavior. Proposed exceptions must identify their approving authority and expiry after that policy is published.
