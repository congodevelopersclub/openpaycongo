---
name: fast-feedback-openpaycongo
description: Choose and run the cheapest reliable OpenPayCongo Docker test tier for a repository change. Use for implementation, test, CI, or workflow work in this repository; not for unrelated product planning.
---

# OpenPayCongo fast feedback

Inspect the affected behavior, then choose the least expensive tier that can reliably falsify it. The canonical command catalog is `bash scripts/ci/fast-feedback.sh`; use its help rather than copying commands here.

- During edits, run one `focused` check for the changed behavior whenever the component supports it.
- Before handoff, run one `local` check for each affected component.
- Do not path-skip, suppress, or replace the unconditional pull-request gates. CI invokes `pr` tiers only as orchestration.
- Preserve unique security, database-migration, multi-database concurrency, native Flutter, artifact, and release evidence. A faster check may supplement but cannot erase that evidence.
- Treat `main` as immutable-artifact work, `deploy` as exact-artifact promotion/verification, and `scheduled` as broad compatibility/performance/migration/fuzz/soak depth; do not claim those properties merely because a local test passed.
