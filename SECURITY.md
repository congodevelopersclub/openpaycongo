# Security policy

Do not publish vulnerabilities, raw SMS, credentials, tokens, private keys,
usable enrollment artifacts, personal payment data, exploit payloads, or
operational topology details in public issues, pull requests, logs,
screenshots, CI output, or release notes.

## Private reporting

GitHub private vulnerability reporting is currently disabled for this
repository. It must be enabled by a repository administrator before any
supported release can claim a private reporting channel. Once it is enabled,
use the repository's **Security** tab and **Report a vulnerability** form.

Until then, do not publish a sensitive report here and do not open a public
issue or advisory as a substitute. Share only the minimum contact information
through an already verified private maintainer channel. A maintainer who
receives a report must move it into the GitHub private-report workflow as soon
as that workflow is available. This policy does not create a mailbox, request
real findings in fixtures, or authorize a public disclosure.

Safe public reports may describe an affected released version, high-level
impact, and a synthetic reproduction without exploit payloads or sensitive
details.

## Supported versions

No production-supported release currently exists. The checked-in Laravel and
Flutter code, main branch, pull-request artifacts, and debug APKs are prototype
or test evidence, not a supported security-release channel.

| Version or artifact | Security support status | Notes |
| --- | --- | --- |
| Production release | Not available | No version has completed the repository's production release, private-reporting, and maintainer-authority prerequisites. |
| Main branch and pull-request artifacts | Not supported | They may receive fixes, but they are not an assurance of a supported release or a public upgrade path. |

Before declaring a supported version, maintainers must publish its immutable
release identity, support window, private reporting route, release authority,
and user upgrade path. Until then, this policy does not promise a security fix
or patch timeline for prototype artifacts.

## Severity and release decisions

The security triage owner classifies a confirmed report using impact,
exploitability, affected supported artifacts, and known exploitation:

| Severity | Meaning | Release decision |
| --- | --- | --- |
| Critical | Credible compromise, exposure, or loss affecting confidentiality, integrity, availability, or release trust at broad or high-value scope | Critical findings are release blockers. Stop affected candidate promotion until the finding is remediated and release evidence is recorded. |
| High | Credible significant impact requiring a realistic attacker capability or condition | High findings are release blockers. Stop affected candidate promotion until the finding is remediated and release evidence is recorded. |
| Medium | Bounded impact, meaningful preconditions, or effective compensating controls | Track a remediation release decision before the next supported release. |
| Low | Limited impact or impractical exploitation | Track and address in normal maintenance. |

“Not reproducible” is not a severity. It is an investigation state. A scanner,
advisory-feed, registry, or Docker failure is also not a clean result; it blocks
the security evidence that depends on it.

On receipt, a credible report that could be Critical or High receives a
**provisional severe** classification. The release owner pauses promotion of an
affected candidate until triage confirms the severity, rules it out, or records
evidence that the candidate is not affected. The seven-calendar-day assessment
target never authorizes promotion while that provisional pause remains active.

## Ownership and response targets

The current maintainer rotation must assign these roles before accepting a
private report: a **security triage owner**, a backup triage owner, a **release
owner**, and an **incident coordinator**. The roster stays in the maintainers'
private operating record; public documentation names responsibilities rather
than personal contact details.

These are sustainable response targets, not a 24/7 availability promise:

- acknowledge a private report within two business days;
- record an initial severity and reproduction decision within seven calendar
  days of acknowledgement;
- for Critical reports, convene the triage and release owners within one
  calendar day of confirmation and record the containment/release decision;
- for High reports, record the remediation or containment plan within seven
  calendar days of confirmation; and
- send the reporter a material-status update at least every seven calendar
  days until coordinated disclosure or closure.

If a target cannot be met, the incident coordinator records the reason,
current risk, next update date, and escalation to the backup owner in the
private report. No target permits publication of sensitive details.

## Coordinated disclosure

Keep the report, reproducer, affected versions, and advisory draft private
until the triage owner and reporter agree on a disclosure plan, or maintainers
document why immediate disclosure is necessary to protect users. Obtain credit
preferences before naming a reporter. The advisory must identify affected and
patched versions, user action, mitigations, and the release evidence without
reproducing a harmful payload. Do not publish customer data, credentials,
tokens, raw SMS, keys, or internal topology.

For a confirmed issue, maintainers create a private advisory draft, link the
fix and minimal regression evidence, decide the patched-release date with the
release owner, notify affected users through approved channels, then publish
only the reviewed advisory. A synthetic tabletop is documented in
[`docs/security-report-tabletop.fixture.md`](docs/security-report-tabletop.fixture.md);
it is not an advisory and must never be submitted to GitHub.

## Emergency release procedure

For a confirmed Critical or High issue affecting a release candidate or
supported artifact:

1. The incident coordinator opens a private record, assigns the triage and
   release owners, and freezes promotion of affected candidate artifacts.
2. The triage owner confirms scope with the minimum safe reproduction and
   records containment. Do not paste sensitive material into the record.
3. The release owner prepares the smallest remediation, with a regression test
   where safe, and reviews affected trust boundaries and dependencies.
4. Build, test, scan, and identify the patched artifacts using the normal
   Docker-backed release evidence; unavailable scanners or evidence fail the
   release decision visibly.
5. The release owner authorizes the patched release or rollback under the
   repository's approved release authority, then the coordinator records user
   communication and the advisory decision.
6. After containment, conduct a blameless review and update this policy, the
   threat model, tests, or release controls when evidence shows a gap.

This procedure does not bypass branch protection, create real advisories,
modify repository settings, or turn a prototype into a production claim.

## Regression and threat-model rules

Every confirmed issue receives a minimal regression test before closure when
safe. If a regression test would itself create unsafe exploit material, the
triage owner records a safer repeatable substitute, its evidence, and why the
test is unsafe in the private record. Closure requires evidence that the fix,
mitigation, or accepted product decision addresses the reported behavior.

Review [`docs/threat-model.md`](docs/threat-model.md) after any significant
architecture, identity, authorization, cryptographic, privacy, dependency,
deployment, telemetry, recovery, or other trust-boundary change. The review
must state the affected asset or boundary, abuse case, control, residual risk,
and whether a regression test or release gate changed.
