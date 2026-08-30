# SYNTHETIC TABLETOP ONLY: private-report lifecycle

This fixture exercises the process without creating a real report, advisory,
or release. No real user, customer, credential, token, key, raw SMS, exploit
payload, or topology detail appears here. Do not submit this fixture to GitHub
or copy it into a report.

## Input

- Private report identifier: `SYNTHETIC-REPORT-001`
- Affected component: `example.invalid/synthetic-component`
- Reporter contact: withheld in this public fixture
- Claim: a synthetic authorization boundary needs review
- Evidence: a non-executable, synthetic reproduction summary only

## Tabletop path

1. A triage owner acknowledges the private report within two business days and
   records a provisional severity without publishing the report.
2. The triage and release owners reproduce the synthetic claim with safe
   evidence, decide the affected artifact is a release blocker for this
   tabletop, and freeze only the synthetic candidate.
3. A maintainer prepares the smallest synthetic fix and a regression test that
   proves the boundary. The regression test contains no exploit payload.
4. The release owner records a patched-release decision after Docker-backed
   tests and scans identify the synthetic artifact.
5. The coordinator prepares a private advisory draft with affected and patched
   synthetic versions, mitigation, and reporter credit preference.
6. The group agrees a coordinated disclosure date, then records the
   post-incident learning: update the threat model if the boundary or residual
   risk changed.

## Expected result

The exercise proves the sequence **private report → fix → regression test →
advisory draft → patched-release decision**. It creates no real advisory,
release, customer record, secret, or security finding.
