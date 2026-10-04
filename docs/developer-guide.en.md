# Developer guide

This guide describes the current OpenPay Congo prototype as implemented in this repository. The featured product path is SMS → Android → Laravel → organization-scoped reconciliation → customer wallet → signed outbound HTTP webhook. It is not a websocket flow. The repository remains explicitly not production-ready: use disposable organizations, test credentials, and synthetic SMS; never route real funds or real customer data through it.

## Clean checkout and repeatable build

The supported verification environment is Docker. From the repository root, first run the affected component's full local gate:

```bash
bash scripts/ci/fast-feedback.sh local laravel
bash scripts/ci/fast-feedback.sh local flutter
```

For a debug APK, use the existing CI artifact gate. It runs Flutter analysis and tests, Android native unit tests, the native crypto test, and exports the debug-signed APK:

```bash
bash scripts/ci/fast-feedback.sh pr flutter
test -s android-client/build/ci/app-debug.apk
```

An isolated emulator or test device can install that artifact with:

```bash
adb install -r android-client/build/ci/app-debug.apk
adb shell monkey -p com.congodeveloperclub.opencongopay 1
```

This artifact is for a controlled prototype walkthrough, not for Play distribution or a production release. Android `release` Gradle configuration is debug-signed. The application requests Android's `RECEIVE_SMS` permission in context and protects SMS-enabled product surfaces until permission is granted. Use a separate emulator/device profile with disposable test data.

To run Laravel outside CI, follow [operations.md](operations.md) for the Docker Compose services, database migration, keys, TLS, and protected environment configuration. Do not copy production values into `.env`, shell history, command examples, build output, or this repository. Pairing issuance needs the installation's existing canonical HTTPS completion endpoint, enrollment-signing seed, and declared trust mode. These are operator-provisioned configuration; this guide does not generate replacements or add a second parser trust root.

## Product path and trust boundaries

1. **Pair and activate.** A verified administrator starts the existing QR/SAS ceremony for their organization. The mobile app verifies the signed pairing material, confirms the short authentication string, retrieves the opaque activation envelope, and completes the encrypted acknowledgement before normal mobile operations become active. QR material is one-time bootstrap data. Follow [ADR 004](adr-004-secure-device-enrollment.md); do not screenshot, log, or reuse it.
2. **Capture locally.** Android requires `RECEIVE_SMS`; its exported `SmsDeliverReceiver` accepts the system `SMS_RECEIVED` broadcast and the native rules only retain messages whose normalized sender exactly matches an administrator-approved trusted sender. Bounded capture is persisted in the encrypted native SMS vault. Raw SMS body, sender, and customer content do not go to analytics or the backend.
3. **Verify a parser release.** The administrator publishes a short-lived signed parser release with `sms-parser:publish`. Its v2 bundle binds the provider identifier, exact sender, literal template, positive parser version, approval time, and expiry. The signature is Ed25519 over a length-prefixed transcript in the `openpaycongo/operator-payment-pattern` domain. The app accepts the signing public key only when its fingerprint matches a pin in the existing pairing trust store. Import is not a trust-on-first-use operation.
4. **Parse and stage.** While the app is unlocked, paired, and SMS-authorized, a bounded literal scanner matches the installed template. It requires exactly one each of `{amount}`, `{currency}`, `{reference}`, `{customer}`, and `{occurred_at}`. It accepts CDF amounts in major units and converts them to integer minor units. Provider identifiers and timestamps are validated before staging. Unknown, expired, lower-version, malformed, or pin-mismatched releases are refused; messages without a usable release remain for review.
5. **Send parsed evidence.** The app creates the `sms_deposit` operation for the existing `POST /mobile/envelopes` protocol v1. Android seals it with the paired directional key and a durable counter; the request carries installation ID, counter, nonce, and ciphertext and has no bearer token. The inner parsed payload contains deposit fields plus bounded evidence (`provider`, `sms_sender`, `parser_version`, `sms_received_at`, `evidence_digest`, and `parser_release_id`). Raw SMS text is not part of that request. Transport retries use a new durable envelope counter and server idempotency prevents duplicate credit.

   `POST /mobile/deposits` is a separate compatibility route authenticated by the paired installation's mobile bearer token. It accepts the legacy transfer payload and does not itself prove signed SMS parsing. Do not use it as a shortcut around `sms_deposit` for the SMS acceptance path. The outer envelope contract and compatibility boundary are in [mobile-envelope-v1.md](mobile-envelope-v1.md).

6. **Validate and credit.** Laravel authenticates/decrypts the envelope before reading its inner command. For `sms_deposit`, the backend additionally requires a registered parser-release ID whose provider, sender, and version match, and whose signed validity interval covers the receipt time; receipt cannot be more than five minutes in the future. Tenant and source-installation identity come from the paired installation, never from payload fields. A repeated identical transfer is an idempotent replay; changed data for the same scoped provider reference is a conflict. A successful record appends balanced immutable ledger entries and a customer credit posting. Parser evidence is encrypted at rest on the deposit model and excluded from serialization.

7. **Reconcile as an administrator.** An organization-scoped financial operator with verified MFA can inspect the masked reconciliation report. Deposit listing, view, and correction require the operator's organization to match the deposit organization. The page exposes a reasoned, audited correction flow; a successful SMS-credit walkthrough does not need reversal or repair. Reconciliation establishes internal ledger consistency, not provider settlement.

8. **Read the customer wallet.** A financial operator issues an OAuth client-credentials application with the `wallets:read` scope and grants that application explicit access to a customer in the same organization. The integration obtains a bearer token from `/oauth/token` and reads `/services/customers/{customer}/wallet`. The response includes CDF `available_minor` and `settlement_status: unverified`; it excludes lookup identifiers and provider references. Revoking the grant removes wallet access; revoking the application credentials invalidates its token access. The scope and explicit customer grant are separate controls.

9. **Deliver an outbound webhook.** In **Developer credentials**, an MFA-verified organization operator selects **Configure webhook**, enters an HTTPS callback URL on an allowed exact host, provides a signing secret of at least 32 bytes, and enables the endpoint. An explicitly granted customer's final wallet-credit update creates an outbox delivery. The HTTP event is `wallet.credit_posted` and reports the stable event ID, customer/deposit IDs, amount, currency, post-allocation available balance, and `settlement_status: unverified`. It contains no raw SMS, customer lookup token, provider reference, or signing secret. Delivery signs the exact stored request body with HMAC-SHA256 over `timestamp + "." + body`; the receiver gets `Webhook-Id`, `Webhook-Timestamp`, and `Webhook-Signature: v1=<hex>`. The delivery ID and body remain stable across retries; receivers deduplicate by event ID. Eight bounded attempts use 30, 60, 120, 240, 480, 960, and 1,920-second delays, then the delivery moves to `dead_letter`. The `wallet-webhooks:recover-deliveries` command recovers due work. Outbound HTTPS targets must pass the exact-host allowlist and public-address/DNS checks; redirects and proxies are denied. **Pause webhook** stops sending; an MFA-verified operator can replay an eligible dead-letter item while the endpoint is enabled.

## Parser release publishing

The existing Laravel command accepts bounded literal inputs and prints the signed JSON bundle while registering the corresponding server release:

```bash
docker compose exec -T php php artisan sms-parser:publish \
  OPERATOR_A PAYOUT \
  'Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}' \
  1 2027-01-01T00:00:00Z
```

The expiry must be a future UTC timestamp at whole-second precision. The provider identifier should match the app's accepted uppercase format; the sender must match the device's exact trusted sender rule after normalization. Each required placeholder occurs once in the literal template. The example expiry is illustrative and must be replaced with a valid future value at execution time. The CLI reads its signing seed from the already configured `OPENPAY_PAIRING_ENROLLMENT_SIGNING_SECRET`; never add the seed to command arguments or paste it into the app. Treat the JSON output as a public signed bundle, but transfer it only through the existing controlled administrator workflow. A signing seed lost or rotated without a coordinated pin update will make the phone reject releases.

## Wallet and webhook receiver contract

Configure outbound host policy with `OPENPAY_WEBHOOK_ALLOWED_HOSTS` as a JSON allowlist of exact hostnames. The endpoint settings and signing secret are organization-scoped, and the secret is stored encrypted. Generate and hold a disposable receiver secret in the caller's existing secret manager; do not place it in this guide or in source control. The receiver validates the timestamped HMAC against the exact raw request bytes, checks its five-minute timestamp window, and persists the event ID once before acknowledging. A receiver must be idempotent because a timeout can occur after it has committed the event. The repository's `examples/webhook-receiver.php` demonstrates a minimal idempotent PHP/SQLite consumer for controlled testing; `WalletWebhookReceiverIntegrationTest` starts it on loopback with a temporary SQLite file and a test-only URL override, and checks delivery, duplicate handling, and authentication failures. The override is for tests only. Do not expose PHP's development server to the network.

The response balance is the customer's final currently available balance after any pending payment-request allocations applied by that deposit. The webhook means the wallet ledger changed; `settlement_status` is deliberately `unverified`. It must not be presented as confirmation that a mobile-money provider settled funds.

## Verification record

For a repeatable, no-log evidence run, see [sms-to-wallet-acceptance.md](sms-to-wallet-acceptance.md) and execute:

```bash
bash scripts/demo/sms-to-wallet-evidence.sh
```

The script records commit, UTC start/end, working-tree state, individual exit codes, and successful CI APK hash/size in a summary file. It does not store console output or environment values. The focused feature classes and full Docker gates are explicit in the script. It fails if a gate fails or the APK artifact is absent. Do not report success until it has been run against the intended commit and the emitted statuses are all zero.

Automated tests do not prove carrier settlement, real-provider message authenticity, hardware-backed power-loss durability on all Android devices, production traffic capacity, or readiness for real payment/customer data. A device run supplements code-level tests; it does not replace them.
