# Continuous security gate

The security workflow keeps pull requests fast while making deeper checks mandatory on `main`, the weekly schedule, and published or prereleased releases. A critical or high vulnerability makes its job fail; that failure is a release blocker.

## Repository activation required

This change delivers the `security-fast` workflow job, but it does not alter repository protection. Until governance work in issue #10 configures `security-fast` as a required status check for protected branches, GitHub can still merge a pull request without that check. Repository administrators must activate it after this workflow first runs on `main`; that post-merge setting is outside this pull request and remains required before claiming enforcement on every change.

Run the same controls locally with Docker:

```bash
bash scripts/security/security-fast.sh
bash scripts/security/verify-secret-scanner.sh
bash scripts/security/verify-enforced-controls.sh
bash scripts/security/security-full.sh
bash scripts/security/verify-full-controls.sh
```

The fast gate scans the real `server/composer.lock` (including development dependencies) and `android-client/pubspec.lock`, runs the canonical whole-tree server `test` target (Pint, Larastan, and tests), runs `composer audit --locked`, classifies every runtime route as reviewed anonymous or authorization-protected, and runs Flutter analysis. It uses pinned local Docker images; neither scanner uploads repository content. CI additionally scans complete tracked Git history, while the local command scans only the current worktree and ignores generated security artifacts.

The full gate adds separate CycloneDX SBOMs for the canonical server and Flutter dependency trees, then scans the locally-built server test image. The SBOM is retained only as a GitHub Actions artifact and deliberately excludes controlled security fixtures. There is no production image target yet, so the image scan is intentionally scoped to the canonical server test image.

Every scanner command is fail-closed: a missing advisory database, unavailable registry, Docker failure, or scanner error fails the job rather than being skipped. The job log distinguishes those infrastructure failures from detected findings through the scanner's own nonzero error output; maintainers must resolve either before release. Running the history scan locally requires a normal Git clone; linked worktrees that cannot be read through Docker fail visibly, while CI uses a full checkout.

The verification scripts prove the gate is wired: synthetic secrets, isolated vulnerable Composer and Flutter lockfiles (including Composer's own audit), a malformed PHP file, an unreviewed application route, invalid Dart, and a pinned vulnerable container image must each be rejected. Fixtures are outside the real application lockfiles and are never scanned as part of the ordinary application dependency scan.
