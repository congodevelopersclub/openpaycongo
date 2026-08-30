# OpenPay Congo Android prototype

> **Prototype only.** This Flutter application is not a production payment client. Do not install it for real payment processing, provide real API/HMAC credentials, or grant it access to real SMS data.

## Setup

Install Flutter 3.38+ with Dart 3.12+, Android Studio/SDK, and a physical Android device or emulator. From this directory:

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

The project currently targets Android first. A device may show SMS and biometric permission prompts; use an isolated test profile and synthetic SMS fixtures only. The current Gradle release configuration is debug-signed, so `flutter build apk --release` is **not** a distributable release process.

## What currently exists

The Android slice requests `RECEIVE_SMS` in context, blocks product access until granted, and captures only exact trusted senders through the platform broadcast receiver. Trusted rules and evidence use explicit v3 AES-GCM envelopes, separate Android Keystore keys, and separate tagged ciphertext inventories in `noBackupFilesDir`; ciphertext in one domain does not invalidate first key creation in the other, while a missing key still fails closed for its own ciphertext. Rules are atomically listed, added, revoked, or cleared only through the foreground/unlocked bridge. Decision tombstones are append-only until future server-acknowledged pruning, with bounded cursor export through encrypted index segments. Bridge deadlines are `outcome_unknown`, so mutating UI attempts authoritative native reconciliation and remains explicitly unknown if that reload also fails or times out. Every journal-ciphertext quarantine, including a decision tombstone, is preceded by a written and directory-synced persistent `journal-recovery-required` marker. Status/export/recovery remain typed recovery across calls and restarts; journal, rules, or raw-inbox corruption and key loss always publish null decision count/byte fields rather than fabricated zero/empty status. No in-app marker-clear API exists. Scheduler saturation finishes the broadcast before a best-effort overload report. Capture-miss reason/timestamp state is minimal plaintext metadata and never contains sender/body/digest. Unreleased v2 ciphertext fails closed and requires explicit Clear storage/reinstall recovery. This is implementation evidence, not Play-policy approval or real-device power-loss/Keystore proof.

- A local Flutter UI prototype with parser, configuration, and biometric-gate screens.
- A bounded trusted-SMS receiver, encrypted local inbox, deterministic manual parser and review-only model boundary.
- Local SQLite stores used by the prototype.
- A contract-only sync cursor BLoC seam. `SyncCursorStore` persists an opaque
  checkpoint and `SyncCursorContract` reconciles it; neither accepts records,
  sender identities, SMS bodies, credentials, or a fabricated server protocol.
- A contract-only pairing enrollment BLoC seam. `PairingEnrollmentStore`
  persists only a redacted lifecycle result, while
  `PairingEnrollmentTransport` owns the future ADR-004 authenticated
  completion/status exchange. It must supply Keystore-backed secrets and the
  documented Laravel contract; this prototype does not parse QR material,
  manufacture credentials, or implement pairing HTTP.

## Known limitations

- No canonical `/v1/sync/*` client, replicated ledger, or server-acknowledged decision pruning.
- No verified server authentication/HMAC, production API-credential storage, encrypted canonical ledger database, or proven recovery flow.
- No production Android signing, Play distribution, offline delivery guarantees, or real-app screenshot test.
- The home view is incomplete and the documented backend integration is not wired into the prototype.
- The sync cursor seam has no server transport implementation yet. A future
  authenticated Laravel contract must supply it before it can represent server
  delivery or acknowledgement.
- The pairing enrollment seam has no authenticated Laravel transport or secure
  storage implementation yet. It cannot be used for real enrollment until the
  documented `/v1/pairing/complete` and status contract are implemented.

Read the repository [mobile PRD](../docs/prd-mobile.md), [architecture](../docs/architecture.md), and [reliability plan](../docs/reliability.md) before extending the app.
