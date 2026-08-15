# Contributor-governance decision packet

## Status

This packet completes the decision record for the contributor-governance gaps
left intentionally pending by the current public guidance. Maintainer ownership,
escalation, contributor sign-off, licensing, dependency attribution, code of
conduct, triage authority, review authority, and release authority are **not yet approved**.
This document does not select any policy or publish private contact
data.

## Existing public evidence

- `CONTRIBUTING.md` already requires focused evidence, Docker validation,
  compatibility/risk/rollback context, independently reviewable commits, and
  disclosure of pending maintainer decisions.
- `SECURITY.md` prohibits sensitive public reporting and states that a verified
  private route remains unpublished.
- Public issue and pull-request templates require reproduction, evidence,
  scope, risk, rollback, and privacy review without boilerplate provenance
  claims.

## Decisions required from maintainers

Maintainers must approve and publish:

1. maintainer roles, accountable ownership, backup escalation, and a public
   contact method that does not expose private contact data without consent;
2. contributor sign-off and licensing terms, including contribution ownership
   and any dependency-attribution standard;
3. behavioral expectations and a code of conduct, with a fair reporting and
   enforcement route;
4. triage, review, decision, and release authority, including how agent
   contributions are supervised; and
5. the relationship between public contribution guidance and the private
   security-reporting route.

This packet does not select an owner, license, sign-off method, code of conduct,
contact address, enforcement process, or release approver.

## Publication gate

Once maintainers approve these choices, publish a compact public policy that
links from `CONTRIBUTING.md`, preserves the no-sensitive-data rules, records an
effective date and revision, and identifies only consented public contacts. The
policy must distinguish contributor expectations from security incident handling
and must not imply that a private vulnerability channel exists until verified.

## Triage and release-authority gate

Before an issue or pull request can claim governance readiness, it must identify
the approved decision/review authority and give reproducible evidence appropriate
to its risk. Release authority must remain separate from routine contribution
triage and must respect the repository’s protected-change policy once approved.
Emergency authority, if any, needs explicit scope and post-incident review; it
must not become a routine contributor bypass.
