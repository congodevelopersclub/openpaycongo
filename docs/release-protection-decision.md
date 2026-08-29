# Release protection and immutable-release evidence packet

## Status

This packet prepares issue #10 without changing repository settings. Branch
protection, tag protection, CODEOWNERS, bypass identities, merge policy, release
environments, production secrets, emergency authority, and release ownership are
**not yet approved** by a repository administrator. This document does not change
any GitHub configuration or select those values.

## Repository evidence

- The current CI workflow grants `contents: read`, uses a single concurrency
  group, and pins the checkout action to an immutable commit.
- Current named CI jobs are `contract`, `laravel`, and `flutter`.
  They run Docker-based checks; the Android artifact is explicitly debug-signed
  evidence, not a distributable release.
- Repository documentation says signing, SBOM, provenance, scans, rollback
  evidence, deployable production images, and a release process are planned,
  not present.
- This repository does not contain a public proof of effective branch or tag
  protection. Source workflow files and screenshots cannot establish that proof.

## Administrator decisions required

An administrator must approve and configure the required checks as they land,
independent approval and stale-approval dismissal, review-conversation
resolution, administrator coverage, force-push and deletion restrictions,
CODEOWNERS coverage, merge strategy, protected tags, release environments,
least-privilege workflow boundaries, and any emergency path.

The decision must name accountable release and compromise-response owners. It
must also define whether a break-glass identity exists, its scope, audit trail,
and mandatory post-incident review. This packet does not select an approved
bypass identity or routine bypass.

## Read-only audit gate

Before claiming protection is effective, an authorized administrator must retain
a read-only API response or documented command output showing the effective main
branch rules, tag rules, required checks, review settings, force-push/deletion
status, and bypass actors. The audit record must identify the repository and
time observed without exposing credentials or private contact data.

The same audit should record which expected jobs do not exist yet (for example,
database compatibility or supply-chain jobs) rather than implying they
are required today. Screenshots alone are not evidence.

## Immutable-release gate

Before any production release claim, maintainers must approve artifact identity,
tag creation and protection rules, signing/provenance/SBOM requirements,
vulnerability review, deployment authorization, rollback evidence, retention,
and publication boundaries. A release record should bind the immutable source
revision, artifact digest, contract version, migration state, review outcome,
and post-deploy readiness evidence.

No current debug APK, Docker test image, or CI artifact is represented as an
immutable production release by this document.

## Emergency and compromise gate

The approved emergency procedure must be exceptional, auditable, time-bounded,
and followed by post-incident review. It must cover rollback, compromised
repository or credential containment, protected-key recovery, notification, and
the evidence needed to restore normal protections. It must not make routine
merges or release-tag changes bypassable.
