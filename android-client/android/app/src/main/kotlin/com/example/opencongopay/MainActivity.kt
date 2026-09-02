package com.congodeveloperclub.opencongopay

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import com.congodeveloperclub.opencongopay.sms.CaptureDecision
import com.congodeveloperclub.opencongopay.sms.DecisionConflictException
import com.congodeveloperclub.opencongopay.sms.GuardedTaskBusyException
import com.congodeveloperclub.opencongopay.sms.GuardedTaskRunner
import com.congodeveloperclub.opencongopay.sms.GuardedTaskTimeoutException
import com.congodeveloperclub.opencongopay.sms.InvalidDecisionCursorException
import com.congodeveloperclub.opencongopay.sms.LegacySmsMigrationRequiredException
import com.congodeveloperclub.opencongopay.sms.OutboxRecoveryRequiredException
import com.congodeveloperclub.opencongopay.sms.OutboxStorageException
import com.congodeveloperclub.opencongopay.sms.PaymentOutboxVaultProvider
import com.congodeveloperclub.opencongopay.sms.RecoveryRequiredException
import com.congodeveloperclub.opencongopay.sms.SmsAccessDenial
import com.congodeveloperclub.opencongopay.sms.SmsAccessGuard
import com.congodeveloperclub.opencongopay.sms.SmsVaultProvider
import com.congodeveloperclub.opencongopay.lock.AppLockRecoveryRequiredException
import com.congodeveloperclub.opencongopay.lock.AppLockVault
import com.congodeveloperclub.opencongopay.pairing.PairingQrTrustStorageException
import com.congodeveloperclub.opencongopay.pairing.PairingQrTrustVault
import com.congodeveloperclub.opencongopay.pairing.PairingQrScanGate
import com.congodeveloperclub.opencongopay.pairing.PairingQrScanOutcome
import com.congodeveloperclub.opencongopay.pairing.PairingActivationException
import com.congodeveloperclub.opencongopay.pairing.MobileEnvelopeVault
import com.congodeveloperclub.opencongopay.pairing.PairingV2NativeCompletion
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "openpaycongo/sms_gateway"
    private val outboxChannelName = "openpaycongo/payment_outbox"
    private val appLockChannelName = "openpaycongo/app_lock"
    private val pairingQrTrustChannelName = "openpaycongo/pairing_qr_trust"
    private val pairingQrScannerChannelName = "openpaycongo/pairing_qr_scanner"
    private val pairingCompletionChannelName = "openpaycongo/pairing_completion"
    private val pairingActivationChannelName = "openpaycongo/pairing_activation"
    private val mobileEnvelopeChannelName = "openpaycongo/mobile_envelope"
    private val permissionRequestCode = 4201
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val accessGuard = SmsAccessGuard()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val appLockTasks = Executors.newSingleThreadExecutor()
    private val pairingQrTrustTasks = Executors.newSingleThreadExecutor()
    private val pairingDirectionalKeyTasks = Executors.newSingleThreadExecutor()
    private val pairingV2Completion by lazy { PairingV2NativeCompletion(applicationContext) }
    private val pairingQrScanGate = PairingQrScanGate()
    private val smsTasks = GuardedTaskRunner(
        isCurrent = { generation -> smsAccessDenial(generation) == null },
        deliver = { callback -> mainHandler.post(callback) },
    )

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Prevent Android screenshots and recents thumbnails from retaining
        // payment content while the Activity exists.
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler(::handleGatewayCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, outboxChannelName)
            .setMethodCallHandler(::handleOutboxCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appLockChannelName)
            .setMethodCallHandler(::handleAppLockCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pairingQrTrustChannelName)
            .setMethodCallHandler(::handlePairingQrTrustCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pairingQrScannerChannelName)
            .setMethodCallHandler(::handlePairingQrScannerCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pairingCompletionChannelName)
            .setMethodCallHandler(::handlePairingCompletionCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pairingActivationChannelName)
            .setMethodCallHandler(::handlePairingActivationCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mobileEnvelopeChannelName)
            .setMethodCallHandler(::handleMobileEnvelopeCall)
    }

    override fun onResume() {
        super.onResume()
        accessGuard.onResume()
    }

    override fun onPause() {
        accessGuard.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        pairingQrScanGate.fail()
        pairingV2Completion.cancel()
        appLockTasks.shutdownNow()
        pairingQrTrustTasks.shutdownNow()
        pairingDirectionalKeyTasks.shutdownNow()
        smsTasks.close()
        super.onDestroy()
    }

    private fun handleGatewayCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permissionState" -> result.success(permissionState())
            "accessGeneration" -> result.success(accessGuard.currentGeneration())
            "requestPermission" -> requestSmsPermission(result)
            "openSettings" -> {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                })
                result.success(null)
            }
            "setUnlocked" -> {
                updateUnlock(call, result)
            }
            "addTrustedSender" -> addTrustedSender(call, result)
            "listTrustedSenders" -> listTrustedSenders(result)
            "clearTrustedSenders" -> clearTrustedSenders(result)
            "revokeTrustedSender" -> revokeTrustedSender(call, result)
            "drainInbox" -> drainInbox(result)
            "captureHealth" -> captureHealth(result)
            "probeStorage" -> probeStorage(result)
            "exportDecisions" -> exportDecisions(call, result)
            "commitInboxDecision" -> commitInboxDecision(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleOutboxCall(call: MethodCall, result: MethodChannel.Result) {
        val vault = PaymentOutboxVaultProvider.get(applicationContext)
        try {
            when (call.method) {
                "storageDirectory" -> result.success(vault.storageDirectory())
                "encrypt" -> result.success(vault.encrypt(outboxIdentity(call), outboxValue(call)))
                "decrypt" -> result.success(vault.decrypt(outboxIdentity(call), outboxValue(call)))
                else -> result.notImplemented()
            }
        } catch (_: OutboxRecoveryRequiredException) {
            result.error("outbox_recovery_required", "Encrypted outbox recovery is required", null)
        } catch (_: OutboxStorageException) {
            result.error("outbox_storage_failure", "Encrypted outbox storage failed", null)
        } catch (_: IllegalArgumentException) {
            result.error("outbox_storage_failure", "Encrypted outbox storage failed", null)
        }
    }

    private fun handleAppLockCall(call: MethodCall, result: MethodChannel.Result) {
        val pin = call.arguments as? String
        if ((call.method == "enroll" || call.method == "verifyPin") && pin == null) {
            result.error("recovery_required", "App lock recovery is required", null)
            return
        }
        appLockTasks.execute {
            try {
                val vault = AppLockVault(applicationContext)
                val value: Any = when (call.method) {
                    "status" -> vault.status()
                    "enroll" -> vault.enroll(pin!!)
                    "verifyPin" -> vault.verify(pin!!, System.currentTimeMillis()).let { outcome ->
                        if (outcome.getString("status") == "cooldown") {
                            mapOf(
                                "status" to "cooldown",
                                "next_attempt_ms" to outcome.getLong("next_attempt_ms"),
                            )
                        } else {
                            mapOf("status" to outcome.getString("status"))
                        }
                    }
                    else -> {
                        mainHandler.post { result.notImplemented() }
                        return@execute
                    }
                }
                mainHandler.post { result.success(value) }
            } catch (_: AppLockRecoveryRequiredException) {
                mainHandler.post {
                    result.error("recovery_required", "App lock recovery is required", null)
                }
            } catch (_: Exception) {
                mainHandler.post {
                    result.error("recovery_required", "App lock recovery is required", null)
                }
            }
        }
    }

    private fun handlePairingQrTrustCall(call: MethodCall, result: MethodChannel.Result) {
        val fingerprint = call.arguments as? String
        if (fingerprint == null) {
            result.error("secure_storage_failure", "Pairing trust storage is unavailable", null)
            return
        }
        pairingQrTrustTasks.execute {
            try {
                val vault = PairingQrTrustVault(applicationContext)
                val value = when (call.method) {
                    "lookup" -> vault.lookup(fingerprint)
                    "persistVerifiedFingerprint" -> vault.persistVerifiedFingerprint(fingerprint)
                    else -> {
                        mainHandler.post { result.notImplemented() }
                        return@execute
                    }
                }
                mainHandler.post { result.success(value) }
            } catch (_: PairingQrTrustStorageException) {
                mainHandler.post {
                    result.error("secure_storage_failure", "Pairing trust storage is unavailable", null)
                }
            } catch (_: Exception) {
                mainHandler.post {
                    result.error("secure_storage_failure", "Pairing trust storage is unavailable", null)
                }
            }
        }
    }

    private fun handlePairingQrScannerCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "scan") {
            result.notImplemented()
            return
        }
        if (!pairingQrScanGate.begin { outcome ->
                mainHandler.post {
                    when (outcome) {
                        is PairingQrScanOutcome.Raw -> result.success(outcome.value)
                        PairingQrScanOutcome.Cancelled -> result.success(null)
                        PairingQrScanOutcome.Unavailable -> result.error(
                            "scanner_unavailable",
                            "QR scanner is unavailable",
                            null,
                        )
                    }
                }
            }
        ) {
            result.error("scan_in_progress", "QR scan is already active", null)
            return
        }
        try {
            val options = GmsBarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .enableAutoZoom()
                .build()
            GmsBarcodeScanning.getClient(this, options)
                .startScan()
                .addOnSuccessListener { barcode -> pairingQrScanGate.succeed(barcode.rawValue) }
                .addOnCanceledListener { pairingQrScanGate.cancel() }
                .addOnFailureListener { pairingQrScanGate.fail() }
        } catch (_: Exception) {
            pairingQrScanGate.fail()
        }
    }

    private fun handlePairingCompletionCall(call: MethodCall, result: MethodChannel.Result) {
        pairingDirectionalKeyTasks.execute {
            try {
                when (call.method) {
                    "begin" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val intentId = arguments?.get("intent_id") as? String
                        val serverPublicKey = arguments?.get("server_public_key") as? String
                        val canonicalServerBaseUrl = arguments?.get("canonical_server_base_url") as? String
                        val pairingSecret = arguments?.get("pairing_secret") as? ByteArray
                        if (arguments == null || arguments.keys != setOf("intent_id", "server_public_key", "canonical_server_base_url", "pairing_secret") ||
                            intentId == null || serverPublicKey == null || canonicalServerBaseUrl == null || pairingSecret == null
                        ) {
                            pairingSecret?.fill(0)
                            throw PairingActivationException()
                        }
                        try {
                            val request = pairingV2Completion.begin(intentId, serverPublicKey, canonicalServerBaseUrl, pairingSecret)
                            mainHandler.post { result.success(request) }
                        } finally {
                            pairingSecret.fill(0)
                        }
                    }
                    "accept" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val intentId = arguments?.get("intent_id") as? String
                        val nonce = arguments?.get("nonce") as? String
                        val ciphertext = arguments?.get("ciphertext") as? String
                        if (arguments == null || arguments.keys != setOf("intent_id", "nonce", "ciphertext") ||
                            intentId == null || nonce == null || ciphertext == null
                        ) throw PairingActivationException()
                        val sas = pairingV2Completion.accept(intentId, nonce, ciphertext)
                        mainHandler.post { result.success(sas) }
                    }
                    "cancel" -> {
                        if (call.arguments != null) throw PairingActivationException()
                        pairingV2Completion.cancel()
                        mainHandler.post { result.success(null) }
                    }
                    else -> mainHandler.post { result.notImplemented() }
                }
            } catch (_: PairingActivationException) {
                mainHandler.post {
                    result.error("pairing_unavailable", "Pairing completion is unavailable", null)
                }
            } catch (_: Exception) {
                mainHandler.post {
                    result.error("pairing_unavailable", "Pairing completion is unavailable", null)
                }
            }
        }
    }

    private fun handlePairingActivationCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "consume") {
            result.notImplemented()
            return
        }
        val arguments = call.arguments as? Map<*, *>
        val intent = arguments?.get("intent_id") as? ByteArray
        val nonce = arguments?.get("nonce") as? ByteArray
        val ciphertext = arguments?.get("ciphertext") as? ByteArray
        if (arguments == null || arguments.keys != setOf("intent_id", "nonce", "ciphertext") ||
            intent == null || nonce == null || ciphertext == null
        ) {
            intent?.fill(0)
            nonce?.fill(0)
            ciphertext?.fill(0)
            result.error("recovery_required", "Pairing activation recovery is required", null)
            return
        }
        pairingDirectionalKeyTasks.execute {
            try {
                pairingV2Completion.consumeActivation(intent, nonce, ciphertext)
                mainHandler.post { result.success("activated") }
            } catch (_: PairingActivationException) {
                mainHandler.post { result.error("recovery_required", "Pairing activation recovery is required", null) }
            } catch (_: Exception) {
                mainHandler.post { result.error("recovery_required", "Pairing activation recovery is required", null) }
            } finally {
                intent.fill(0)
                nonce.fill(0)
                ciphertext.fill(0)
            }
        }
    }

    private fun handleMobileEnvelopeCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "open") {
            openMobileEnvelope(call, result)
            return
        }
        if (call.method != "seal") {
            result.notImplemented()
            return
        }
        val arguments = call.arguments as? Map<*, *>
        val operation = arguments?.get("operation") as? String
        val payload = arguments?.get("payload") as? ByteArray
        if (arguments == null || arguments.keys != setOf("operation", "payload") || operation != "deposit" || payload == null) {
            payload?.fill(0)
            result.error("envelope_unavailable", "Mobile envelope is unavailable", null)
            return
        }
        val generation = requireSmsGatewayAccess(result)
        if (generation == null) {
            payload.fill(0)
            return
        }
        smsTasks.submit(
            generation = generation,
            operation = {
                try {
                    MobileEnvelopeVault(
                        context = applicationContext,
                        accessLease = accessGuard.lease(
                            permissionGranted = {
                                checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED
                            },
                            expectedGeneration = generation,
                        ),
                    ).seal(operation, payload)
                } finally {
                    payload.fill(0)
                }
            },
            onSuccess = result::success,
            onFailure = { result.error("envelope_unavailable", "Mobile envelope is unavailable", null) },
            onDenied = { deliverAccessDenied(result) },
        )
    }

    private fun openMobileEnvelope(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val installationId = arguments?.get("installation_id") as? String
        val counter = arguments?.get("counter") as? String
        val status = arguments?.get("status") as? Int
        val nonce = arguments?.get("nonce") as? String
        val ciphertext = arguments?.get("ciphertext") as? String
        if (arguments == null || arguments.keys != setOf("installation_id", "counter", "status", "nonce", "ciphertext") ||
            installationId == null || counter == null || status == null || nonce == null || ciphertext == null
        ) {
            result.error("envelope_unavailable", "Mobile envelope is unavailable", null)
            return
        }
        val generation = requireSmsGatewayAccess(result) ?: return
        smsTasks.submit(
            generation = generation,
            operation = {
                MobileEnvelopeVault(
                    context = applicationContext,
                    accessLease = accessGuard.lease(
                        permissionGranted = {
                            checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED
                        },
                        expectedGeneration = generation,
                    ),
                ).open(installationId, counter, status, nonce, ciphertext)
            },
            onSuccess = result::success,
            onFailure = { result.error("envelope_unavailable", "Mobile envelope is unavailable", null) },
            onDenied = { deliverAccessDenied(result) },
        )
    }

    private fun outboxIdentity(call: MethodCall): String =
        (call.arguments as? Map<*, *>)?.get("identity") as? String
            ?: throw IllegalArgumentException()

    private fun outboxValue(call: MethodCall): String =
        (call.arguments as? Map<*, *>)?.get("value") as? String
            ?: throw IllegalArgumentException()

    private fun updateUnlock(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val unlocked = arguments?.get("unlocked") as? Boolean
        if (unlocked == false) {
            accessGuard.lock()
            result.success(null)
            return
        }
        val generation = arguments?.get("generation") as? Number
        if (unlocked != true || generation == null) {
            result.error("invalid_unlock", "Authentication generation is required", null)
            return
        }
        val denial = accessGuard.unlock(generation.toLong())
        if (denial == null) {
            result.success(null)
        } else {
            result.error("stale_unlock", "Authentication result is no longer current", null)
        }
    }

    private fun requestSmsPermission(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        if (pendingPermissionResult != null) {
            result.error("request_in_progress", "SMS permission request already active", null)
            return
        }
        getPreferences(MODE_PRIVATE).edit().putBoolean("sms_permission_asked", true).apply()
        pendingPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.RECEIVE_SMS), permissionRequestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) {
            return
        }
        pendingPermissionResult?.success(permissionState())
        pendingPermissionResult = null
    }

    private fun permissionState(): String {
        if (checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED) {
            return "granted"
        }
        val asked = getPreferences(MODE_PRIVATE).getBoolean("sms_permission_asked", false)
        return if (asked && !shouldShowRequestPermissionRationale(Manifest.permission.RECEIVE_SMS)) {
            "permanently_denied"
        } else {
            "denied"
        }
    }

    private fun addTrustedSender(call: MethodCall, result: MethodChannel.Result) {
        val sender = call.arguments as? String
        if (sender == null) {
            result.error("invalid_rule", "Trusted sender is invalid", null)
            return
        }
        runSmsTask(
            result,
            operation = { SmsVaultProvider.get(applicationContext).addTrustedSender(sender) },
            onSuccess = result::success,
            onFailure = { result.error("secure_storage_failure", "Trusted sender rule outcome is unknown; reload", null) },
        )
    }

    private fun listTrustedSenders(result: MethodChannel.Result) {
        runSmsTask(
            result,
            operation = { SmsVaultProvider.get(applicationContext).trustedSenders() },
            onSuccess = result::success,
            onFailure = { result.error("secure_storage_failure", "Trusted sender rules could not be read", null) },
        )
    }

    private fun clearTrustedSenders(result: MethodChannel.Result) {
        runSmsTask(
            result,
            operation = { SmsVaultProvider.get(applicationContext).clearTrustedSenders() },
            onSuccess = result::success,
            onFailure = { result.error("secure_storage_failure", "Trusted sender clear outcome is unknown; reload", null) },
        )
    }

    private fun revokeTrustedSender(call: MethodCall, result: MethodChannel.Result) {
        val sender = call.arguments as? String
        if (sender == null) {
            result.error("invalid_rule", "Trusted sender is invalid", null)
            return
        }
        runSmsTask(
            result,
            operation = { SmsVaultProvider.get(applicationContext).revokeTrustedSender(sender) },
            onSuccess = result::success,
            onFailure = { result.error("secure_storage_failure", "Trusted sender revoke outcome is unknown; reload", null) },
        )
    }

    private fun drainInbox(result: MethodChannel.Result) {
        runSmsTask(
            result,
            operation = { SmsVaultProvider.get(applicationContext).recordsForFlutter() },
            onSuccess = result::success,
            onFailure = { result.error("secure_storage_failure", "Encrypted inbox could not be opened", null) },
        )
    }

    private fun captureHealth(result: MethodChannel.Result) {
        runSmsTask(
            result,
            operation = { SmsVaultProvider.get(applicationContext).healthForFlutter() },
            onSuccess = result::success,
            onFailure = { result.error("secure_storage_failure", "Capture health could not be read", null) },
        )
    }

    private fun probeStorage(result: MethodChannel.Result) {
        runSmsTask(
            result,
            operation = { SmsVaultProvider.get(applicationContext).probeStorage() },
            onSuccess = result::success,
            onFailure = { result.error("secure_storage_failure", "Storage probe failed", null) },
        )
    }

    private fun exportDecisions(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val limit = (arguments?.get("limit") as? Number)?.toInt()
        val cursor = arguments?.get("cursor") as? String
        if (arguments == null || limit == null || limit !in 1..100 ||
            (arguments.containsKey("cursor") && arguments["cursor"] != null && cursor == null)
        ) {
            result.error("invalid_export_limit", "Decision export limit is invalid", null)
            return
        }
        runSmsTask(
            result,
            operation = { SmsVaultProvider.get(applicationContext).decisionsForFlutter(limit, cursor) },
            onSuccess = result::success,
            onFailure = { error ->
                if (error is InvalidDecisionCursorException) {
                    result.error("invalid_cursor", "Decision cursor is invalid", null)
                } else if (error is RecoveryRequiredException) {
                    result.error("recovery_required", "Decision journal requires explicit recovery", null)
                } else {
                    result.error("secure_storage_failure", "Decision journal could not be read", null)
                }
            },
        )
    }

    private fun commitInboxDecision(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val id = arguments?.get("id") as? String
        val decision = when (arguments?.get("decision") as? String) {
            "reviewed" -> CaptureDecision.reviewed
            "rejected" -> CaptureDecision.rejected
            "processed" -> CaptureDecision.processed
            else -> null
        }
        if (id == null || decision == null) {
            result.error("invalid_decision", "Inbox decision is invalid", null)
            return
        }
        runSmsTask(
            result,
            operation = { SmsVaultProvider.get(applicationContext).commitDecision(id, decision) },
            onSuccess = { result.success(null) },
            onFailure = { error ->
                if (error is DecisionConflictException) {
                    result.error(
                        "decision_conflict",
                        "Decision conflicts with the durable local outcome",
                        mapOf("existing" to error.existing.name, "requested" to error.requested.name),
                    )
                } else {
                    result.error(
                        "outcome_unknown",
                        "Decision outcome is unknown; reload the authoritative encrypted inbox",
                        null,
                    )
                }
            },
        )
    }

    private fun smsAccessDenial(generation: Long? = null): SmsAccessDenial? =
        accessGuard.check(
            checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED,
            generation,
        )

    private fun requireSmsGatewayAccess(result: MethodChannel.Result): Long? {
        val denial = smsAccessDenial()
        if (denial != null) {
            deliverAccessDenied(result, denial)
            return null
        }
        return accessGuard.currentGeneration()
    }

    private fun deliverAccessDenied(
        result: MethodChannel.Result,
        denial: SmsAccessDenial? = smsAccessDenial(),
    ) {
        val code = when (denial) {
            SmsAccessDenial.permissionRevoked -> "permission_revoked"
            SmsAccessDenial.background -> "not_foreground"
            SmsAccessDenial.locked, SmsAccessDenial.staleUnlock, null -> "locked"
        }
        result.error(code, "SMS gateway access denied", null)
    }

    private fun <T> runSmsTask(
        result: MethodChannel.Result,
        operation: () -> T,
        onSuccess: (T) -> Unit,
        onFailure: (Throwable) -> Unit,
    ) {
        val generation = requireSmsGatewayAccess(result) ?: return
        smsTasks.submit(
            generation = generation,
            operation = operation,
            onSuccess = onSuccess,
            onFailure = { error ->
                if (error is GuardedTaskTimeoutException) {
                    result.error(
                        "outcome_unknown",
                        "Operation timed out and may have completed; reload authoritative state",
                        null,
                    )
                } else if (error is GuardedTaskBusyException) {
                    result.error("gateway_busy", "SMS gateway is busy; retry", null)
                } else if (error is LegacySmsMigrationRequiredException) {
                    result.error(
                        "legacy_migration_required",
                        "Legacy development SMS data requires clear-storage recovery",
                        null,
                    )
                } else {
                    onFailure(error)
                }
            },
            onDenied = { deliverAccessDenied(result) },
        )
    }
}
