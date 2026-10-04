# SMS-to-wallet acceptance path

This acceptance path documents the implemented prototype flow: Android receives a trusted payment SMS, the phone applies an administrator-signed parser, the paired phone sends encrypted parsed evidence to Laravel, the server posts a provisional wallet credit, an administrator can reconcile it, an explicitly authorized developer application can read the customer wallet, and a configured outbound webhook can deliver its event. It is an integration proof, not a settlement proof or production approval. Use isolated test data and synthetic SMS only.

## Preconditions

- Docker Engine with Compose v2 is available for every repository test.
- A disposable test installation is configured with the existing pairing endpoint and the existing Ed25519 enrollment signing seed. Keep those values in the protected environment or secret manager. The SMS parser publisher reuses the pairing signing authority; it introduces no second trust root.
- The Android app has completed the repository's existing signed QR and SAS-confirmed pairing ceremony with that test installation. Its parser verifier accepts only the public signing key already pinned by that pairing trust store.
- Use a throwaway organization, source installation, customer identifier, and provider reference. Never use a real SMS sender, live customer identifier, payment, access token, signing seed, OAuth secret, or production wallet.
- For automated outbound delivery proof, use the repository-owned `examples/webhook-receiver.php` through `WalletWebhookReceiverIntegrationTest`. That feature test starts a controlled local PHP receiver, uses a temporary SQLite file and a test-only URL override, and checks a real HTTP signature/retry path. The override is testing-only. Never expose PHP's development server or use the override in production.

The mobile path remains gated by Android `RECEIVE_SMS`, the exact locally trusted sender, a valid signed parser release, the app's unlocked state, and successful pairing activation. The raw SMS body remains on-device. The mobile envelope contains parsed deposit fields and bounded parser evidence, not the SMS body.

## Focused and full automated proof

Run from the repository root. The script delegates all checks to `scripts/ci/fast-feedback.sh`; it records the starting commit, UTC timestamps, working-tree cleanliness, named gate exit statuses, and—when the existing PR artifact gate succeeds—the APK digest and size. It stores no build/test output, shell environment, credentials, or secrets. A failed Docker command makes the script exit nonzero after recording the remaining gate statuses.

```bash
bash scripts/demo/sms-to-wallet-evidence.sh
```

The gates are focused Laravel feature classes (`MobileDepositCreditWorkflowTest`, `SmsParserEvidenceTest`, `SmsDepositEnvelopeIntegrationTest`, `CustomerWalletApiTest`, `WalletWebhookDeliveryTest`, and `WalletWebhookReceiverIntegrationTest`), the full Laravel local quality/test tier, the full Flutter local analysis/test tier, and the existing Flutter PR tier that runs the native Android test layer and exports `android-client/build/ci/app-debug.apk`. Both webhook classes must prove delivery policy and the controlled receiver path before calling the complete script an acceptance pass. A missing class or receiver contract is a blocker, never a reason to skip or weaken the gate.

The APK is the debug-signed output of the existing CI artifact target. It is useful for an isolated prototype demonstration only; it is not a release artifact. The evidence script does not build a Laravel deployment image, start a live stack, create credentials, perform an enrollment, configure a receiver, or claim that a device was tested.

## Optional isolated Android emulator/device walk-through

This is a manual integration check, separate from the automated proof. It requires an already paired and activated test installation, an already pinned parser-signing public key, an exact trusted sender rule, and a disposable server environment. Do not invent a mobile enrollment endpoint, add a new key, or accept a new trust pin while following these steps.

1. Build the debug APK and install it on a disposable Android emulator or test device:

   ```bash
   bash scripts/ci/fast-feedback.sh pr flutter
   adb install -r android-client/build/ci/app-debug.apk
   adb shell monkey -p com.congodeveloperclub.opencongopay 1
   ```

2. Grant SMS permission in Android's prompt. Complete the existing verified-administrator QR/SAS ceremony and mobile activation acknowledgement, then unlock the app. Use the existing administrator panel to create only a synthetic test organization/installation and maintain the exact sender allowlist. If those prerequisites are unavailable in the target environment, stop; this repository does not define a separate demo bootstrap or an unprotected trust-pin command.

3. On the test Laravel host, publish a short-lived parser bundle with the existing server signing seed and current `sms-parser:publish` command. Choose an uppercase provider identifier accepted by the app, the exact numeric emulator sender `12345`, a unique test customer/reference, and a future UTC expiry. The literal template must contain each placeholder exactly once:

   ```text
   Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}
   ```

   The amount is expressed in CDF major units (`125.00` becomes `12500` minor units); the parser accepts `CDF`. Keep the signing seed out of the terminal command and output. Transfer only the public signed JSON bundle to the paired app's **Import signed parser** control. Confirm that the bundle is accepted. A new public key, mismatched pin, expired release, lower parser version, unknown field, or malformed signature must be refused.

4. Before sending the target SMS, open **Developer credentials** in the verified administrator panel. Issue a disposable OAuth application with `wallets:read`. In **Customer access**, provision the exact synthetic lookup identifier `demo-customer-001` and grant access to that application; this does not create a deposit or balance. Use **Configure webhook** on the same application, with an HTTPS receiver on an exact allowlisted test host and a signing secret of at least 32 bytes held in the existing protected secret store. Keep the Compose queue worker running so the after-commit allocation and delivery jobs can run. This setup is required before the first message: the outbox is created for an enabled endpoint only when the deposit's customer has explicit application access.

5. While the app is running and unlocked, inject a synthetic message whose sender and body exactly match the installed rule and template. Set the occurrence timestamp to the current UTC time:

   ```bash
   adb emu sms send 12345 "Received 125.00 CDF; ref demo-reference-001; customer demo-customer-001; at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
   ```

   Check that the inbox/reconciliation surface reports a recorded provisional deposit, with settlement still unverified. Repeat the exact message and confirm replay does not create a second credit. A changed amount under the same provider reference may remain in the encrypted client journal for review; confirm it does not create a second local/server credit. The backend feature test separately proves that a changed payload reaching the server returns a conflict without a second credit.

6. Exercise deferred delivery with only synthetic data. Disable emulator networking before injecting a separate unique test SMS, and confirm that no server acknowledgement is shown while offline. An Android emulator can launch the exported `SmsDeliverReceiver` after its app process is killed (use `adb shell am kill com.congodeveloperclub.opencongopay` rather than force-stopping the package); confirm on relaunch that retained evidence becomes pending until the app is unlocked and paired, then that sync retries after networking returns. Where the emulator does not deliver a telephony broadcast under those conditions, record the limitation and use a physical test SIM/profile with synthetic provider text. Do not use `adb force-stop` as evidence of background delivery.

7. In **Deposit reconciliation**, verify the deposit is scoped to its organization, parser evidence stays masked, and settlement is unverified. Do not invoke reverse or repair actions as part of a successful-credit proof. Use the disposable `wallets:read` application to obtain an OAuth client-credentials token and query `/services/customers/{customer}/wallet`. Verify CDF `available_minor` equals `12500`, `settlement_status` is `unverified`, and the response omits the customer lookup value and provider reference. Then confirm the enabled endpoint has a `wallet.credit_posted` delivery. Wait for the queue worker; delivery is asynchronous and may be pending/retry before it succeeds. Revoke customer access and the test application after recording the non-secret result.

8. For the local controlled receiver round-trip, run `WalletWebhookReceiverIntegrationTest`; the test starts `examples/webhook-receiver.php` on loopback with a temporary SQLite database and test-only `webhooks.test_receiver_url`. Verify the authenticated event ID, duplicate acknowledgement, exact payload, HMAC, and final delivery state. The receiver accepts an identical duplicate idempotently and rejects an invalid signature, stale timestamp, or same-ID/different-body conflict. The endpoint receives `Webhook-Id`, `Webhook-Timestamp`, and `Webhook-Signature: v1=<hex>`; the signature is HMAC-SHA256 over the timestamp, a period, and the exact stored body. Never expose PHP's development server or configure an unlisted/private production destination.

## What this proof establishes

Automated feature tests can establish parser-release signature/expiry checks, encrypted parser evidence, deposit idempotency, ledger credit, organization/customer access checks, and controlled webhook delivery behavior at their owning Laravel interfaces. Flutter tests and the native Android target establish code-level behavior for parsing, capture, encrypted queueing, transport, and recovery seams. The optional walk-through can add observed emulator/device and deployment evidence for the specific run.

None of these results alone establish mobile-carrier settlement, a real provider integration, tamper-proof Android hardware, universal process-death delivery, power-loss durability on every device, production-scale webhook delivery, or safety for real funds or customer data. A provisional credit records the reported SMS transaction; it is not independently settled.
