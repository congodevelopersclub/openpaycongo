# Foundation closure audit and maintainer decision matrix

## Evidence rule

Do not close a native child, deliverable, or milestone until its issue acceptance
criteria have reproducible public evidence and every required native child is
complete. A merged documentation or harness slice is evidence for only the
criteria it actually proves; it is not approval of a maintainer-owned policy.

## Maintainer decision matrix

| Area | Native issue | Maintainer choice still required | Evidence needed before closure |
| --- | --- | --- | --- |
| Production identity | #9 | Issuer/discovery, token validation, claim matrix, audiences, client types, rotation, revocation, outage, recovery, retention | Approved ADR, versioned fixtures, adapter conformance and redaction evidence |
| Vulnerability treatment | #38 | Advisory sources, exception authority/duration, and candidate-artifact review records | Published `SECURITY.md` policy plus candidate-artifact review records; private-reporting enablement and exception authority remain pending |
| Privacy and threat lifecycle | #67 | Retention, deletion/recovery, logging/telemetry redaction, disclosure authority | Approved lifecycle policy and implementation evidence |
| Release protection | #10 | Branch/tag rules, review ownership, CODEOWNERS, bypass/emergency authority, release environment | Administrator-approved settings and read-only effective-settings audit |
| Contributor governance | #69 | Public owner/escalation route, sign-off, licensing/attribution, code of conduct, triage/release authority | Approved public policies using consented contact data |
| Contract compatibility | #68 | Support windows, deprecation notice, owner and approval authority | Approved policy plus backward/intentional-break fixtures |

Except for the operating severity, response, disclosure, and emergency rules
published in `SECURITY.md`, all listed authority values are not yet approved.
This matrix does not select them.

## Native child closure audit

| Deliverable | Child | Merged/public evidence | Closure state |
| --- | --- | --- | --- |
| #48 identity/privacy/security | #9 | Held production-identity decision packet; no approved identity model | Do not close |
| #48 identity/privacy/security | #38 | Published `SECURITY.md` response policy; private reporting is disabled and no exception policy exists | Do not close |
| #48 identity/privacy/security | #67 | Threat-model slice merged; lifecycle authority remains pending | Do not close |
| #49 executable contract | #11 | Docker black-box analytics/operational harness foundation and fixture divergence evidence | Do not close: pairing, sync, recovery, full auth and runtime matrix remain |
| #49 executable contract | #21 | Existing public invariants and held conformance boundary | Do not close: #9/#11 prerequisites and canonical mapping/migrations remain |
| #49 executable contract | #68 | Versioning-policy foundation merged; compatibility authority remains pending | Do not close |
| #50 contributor/release governance | #10 | Held release-protection decision packet; no administrator audit/settings | Do not close |
| #50 contributor/release governance | #69 | Governance foundation merged and held decision packet; public policy choices remain pending | Do not close |

Therefore #48, #49, #50, and milestone #42 must remain open. The next
autonomous work is fixture/harness and conformance implementation; the matrix
identifies the only remaining maintainer-owned decisions without inventing them.
