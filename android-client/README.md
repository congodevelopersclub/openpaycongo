# OpenPay Congo Android client

> **Prototype only.** This client and its server integration are not approved for real payments, real SMS, production credentials, or customer data. Use a disposable Android profile and synthetic messages.

The implemented product path is **SMS → Android → Laravel → customer wallet → signed outbound HTTP webhook**. Android captures and parses SMS locally, then sends parsed deposit data through the paired encrypted-envelope protocol. The server records a provisional credit; the message does not establish provider settlement. This is not a websocket flow.

## Build and test

Repository verification runs in Docker. From the repository root:

```bash
bash scripts/ci/fast-feedback.sh local flutter
bash scripts/ci/fast-feedback.sh pr flutter
```

The PR tier runs analysis and Flutter tests, Android native unit tests, a native cryptography test, and exports a debug-signed APK to `android-client/build/ci/app-debug.apk`. Install it only on an isolated test emulator or device:

```bash
adb install -r android-client/build/ci/app-debug.apk
adb shell monkey -p com.congodeveloperclub.opencongopay 1
```

The Gradle `release` build is currently debug-signed and is not a distributable release. Review the [English developer guide](../docs/developer-guide.en.md), [French developer guide](../docs/developer-guide.fr.md), and [SMS-to-wallet acceptance path](../docs/sms-to-wallet-acceptance.md) for setup and end-to-end boundaries.

## Delivered composition

- `PairingRuntime` is composed by the app at startup. The existing signed QR/SAS pairing, activation retrieval, native promotion, final encrypted activation acknowledgement, and foreground recovery flow are connected to the inbox experience. Android native code owns pairing secrets, directional envelope keys, the credential, and the pinned HTTPS origin in a Keystore-backed no-backup vault.
- The app requests Android `RECEIVE_SMS` permission before product content. The manifest registers `SmsDeliverReceiver`; native code applies bounded capture, normalized exact trusted-sender rules, duplicate suppression, and encrypted local SMS storage. Flutter exposes the foreground/unlocked rules and review workflow.
- The inbox composes pairing state with the encrypted SMS parser-release store and `SmsDepositCoordinator`. A developer-approved flat schema `"1"` release must match the separately compiled `OPENPAY_OPERATOR_PATTERN_SIGNING_PUBLIC_KEY`, the exact trusted sender, its approval/expiry window, and monotonic version. A missing parser-key pin refuses imports. A bounded literal scanner extracts all five required transfer fields. It does not execute uploaded regular expressions or send raw SMS to the server, analytics, or model services. See [approved pattern integration](../docs/operator-pattern-integration.md).
- Parsed data is staged in the encrypted deposit submission journal. Android's native vault seals the `sms_deposit` command into the v1 `POST /mobile/envelopes` protocol, persists its outbound counter before transmission, and authenticates the encrypted response. Unknown network results remain pending and retry with a fresh durable counter; server idempotency prevents duplicate credit. Dart handles bounded routing and redacted outcomes, not the directional keys.
- The inbox displays whether a message is waiting, needs review, has been queued, or received a server result. A server-recorded SMS deposit is explicitly provisional; the UI does not claim that a mobile-money provider settled funds.

The legacy credential-authenticated `POST /mobile/deposits` route remains separate. It uses a paired mobile bearer token and a compatibility transfer payload; it is not the `sms_deposit` path and does not require signed parser evidence by default. See the [mobile envelope v1 contract](../docs/mobile-envelope-v1.md).

## Capture, storage, and recovery

Trusted rules and SMS evidence use explicit v3 AES-GCM envelopes, separate Android Keystore keys, and separate tagged ciphertext inventories in `noBackupFilesDir`. A missing key or damaged ciphertext fails closed for its own store. Trusted rules are changed only through the foreground/unlocked bridge. Capture is bounded by sender, segment count, age, future skew, and body size. The manifest exports the receiver only for the protected Android SMS broadcast.

Native capture misses retain only minimal reason/timestamp metadata; they do not record sender, body, digest, or message content. Scheduler saturation finishes the broadcast before reporting a best-effort overload. Corrupt journals and invalidated keys surface typed recovery instead of invented empty status. Quarantining journal ciphertext first persists a `journal-recovery-required` marker. No in-app operation clears that marker; recovery requires the explicit documented recovery path or app reinstall, which discards local evidence. Legacy v2 ciphertext fails closed. These are code-level guarantees, not proof of power-loss behavior on every device or Play-policy approval.

The encrypted deposit retry journal is installation-bound. It does not sync raw SMS or place customer/payment payloads in logs, BLoC state, telemetry, screenshots, or Android backups. The platform bridge has bounded deadlines; an `outcome_unknown` mutation reconciles against authoritative native state before the UI reports a final result.

## Remaining limits

- The app supports the delivered point-to-point SMS deposit envelope. It does not implement a general `/v1/sync/*` ledger replication protocol or server-acknowledged pruning of capture decision tombstones.
- A CI APK and automated host tests do not prove delivery on every carrier/device, survival under all power-loss or filesystem behaviors, production signing, Play distribution, provider settlement, or real-world SMS authenticity.
- Pairing trust inherits the documented QR and administrator-session boundaries. This implementation does not provide forward secrecy, multi-device enrollment, or recovery from a compromised administrator session or hosting edge.
- The app can show a provisional credit from SMS evidence. Independent provider settlement and production reconciliation remain outside this prototype's claim.

For the complete backend, wallet, administrator, webhook, and verification flow, see the [developer guides](../docs/developer-guide.en.md) and the [acceptance procedure](../docs/sms-to-wallet-acceptance.md).
