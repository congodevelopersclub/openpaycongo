package com.congodeveloperclub.opencongopay

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.congodeveloperclub.opencongopay.sms.CaptureDecision
import com.congodeveloperclub.opencongopay.sms.DecisionConflictException
import com.congodeveloperclub.opencongopay.sms.GuardedTaskBusyException
import com.congodeveloperclub.opencongopay.sms.GuardedTaskRunner
import com.congodeveloperclub.opencongopay.sms.GuardedTaskTimeoutException
import com.congodeveloperclub.opencongopay.sms.InvalidDecisionCursorException
import com.congodeveloperclub.opencongopay.sms.LegacySmsMigrationRequiredException
import com.congodeveloperclub.opencongopay.sms.RecoveryRequiredException
import com.congodeveloperclub.opencongopay.sms.SmsAccessDenial
import com.congodeveloperclub.opencongopay.sms.SmsAccessGuard
import com.congodeveloperclub.opencongopay.sms.SmsVaultProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "openpaycongo/sms_gateway"
    private val permissionRequestCode = 4201
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val accessGuard = SmsAccessGuard()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val smsTasks = GuardedTaskRunner(
        isCurrent = { generation -> smsAccessDenial(generation) == null },
        deliver = { callback -> mainHandler.post(callback) },
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler(::handleGatewayCall)
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
