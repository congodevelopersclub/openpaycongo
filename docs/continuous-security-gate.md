# Continuous security gate

The security workflow keeps pull requests fast while making deeper checks mandatory on `main`, the weekly schedule, and `v*` candidate-tag pushes. Candidate tags must be scanned before a release is published. A critical or high vulnerability makes its job fail; that failure is a release blocker.

GitHub Actions alone cannot prevent someone with release authority from publishing a tag before its candidate run finishes. Repository governance issue #10 must require the stable `security-fast` check on protected branches and define the candidate-tag/release publication boundary; until then, this workflow supplies evidence rather than an enforceable publication control.

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

The fast gate scans the real `server/composer.lock` (including development dependencies) and `android-client/pubspec.lock`, runs the canonical whole-tree server `test` target (Pint, Larastan, and tests), runs `composer audit --locked`, classifies every runtime route as reviewed anonymous or authorization-protected, and runs Flutter analysis. It uses pinned local Docker images; neither scanner uploads repository content. CI additionally scans complete tracked Git history, while the local command scans the entire current worktree, including any generated security artifacts present under it. The disposable PHP test and authorization-proof stages create a blank in-image `.env` so PHPUnit's testing configuration remains authoritative; the Docker build context excludes `server/.env`, so a host or future production build cannot receive it.

The full gate adds separate CycloneDX SBOMs for the canonical server and Flutter dependency trees and for each deployable production image. It builds the exact PHP-FPM and nginx `production` targets used by Compose as `congo-openpay-fpm:security` and `congo-openpay-nginx:security`, then scans both with pinned Trivy at HIGH/CRITICAL with exit code 1. It additionally scans the disposable PHP 8.3 test image, including its PostgreSQL and MySQL PDO extensions; that image is supplementary and never stands in for production coverage. The SBOMs are retained only as GitHub Actions artifacts and deliberately exclude controlled security fixtures.

Every scanner command is fail-closed: a missing advisory database, unavailable registry, Docker failure, or scanner error fails the job rather than being skipped. The job log distinguishes those infrastructure failures from detected findings through the scanner's own nonzero error output; maintainers must resolve either before release. Running the history scan locally requires a normal Git clone; linked worktrees that cannot be read through Docker fail visibly, while CI uses a full checkout.

The verification scripts prove the gate is wired: synthetic secrets, isolated vulnerable Composer and Flutter lockfiles (including Composer's own audit), a Pint-valid PHP return-type violation rejected by Larastan, an `auth.optional` lookalike route rejected by the authorization inventory, invalid Dart, and a pinned vulnerable container image must each be rejected. Fixtures are outside the real application lockfiles and are never scanned as part of the ordinary application dependency scan.
