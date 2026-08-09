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

The manifest declares SMS receipt, but the parser initializer is unwired: this prototype does not currently request SMS permission or listen for messages. Its biometric flow is an authentication prompt, not a runtime permission. Future SMS work must assess API/distribution/default-handler eligibility, request in context, handle deny/permanent-deny/settings/unsupported states, and preserve a fully tested manual/merchant fallback.

- A local Flutter UI prototype with parser, configuration, and biometric-gate screens.
- One narrow Orange Money SMS parsing test.
- Local SQLite stores used by the prototype.

## Known limitations

- No canonical `/v1/sync/*` client, inbox/outbox state machine, or replicated ledger.
- No verified server authentication, HMAC verification, secure credential storage, encrypted local database, or recovery flow.
- No production Android signing, Play distribution, offline delivery guarantees, or real-app screenshot test.
- The home view is incomplete and the documented backend integration is not wired into the prototype.

Read the repository [mobile PRD](../docs/prd-mobile.md), [architecture](../docs/architecture.md), and [reliability plan](../docs/reliability.md) before extending the app.
