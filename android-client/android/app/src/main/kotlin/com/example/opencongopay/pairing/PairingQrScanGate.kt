package com.congodeveloperclub.opencongopay.pairing

/**
 * Holds one user-initiated scanner result until it is handed back to Flutter.
 * It neither logs nor persists QR material.
 */
internal sealed interface PairingQrScanOutcome {
    data class Raw(val value: String) : PairingQrScanOutcome
    data object Cancelled : PairingQrScanOutcome
    data object Unavailable : PairingQrScanOutcome
}

internal class PairingQrScanGate {
    private var deliver: ((PairingQrScanOutcome) -> Unit)? = null

    fun begin(callback: (PairingQrScanOutcome) -> Unit): Boolean {
        if (deliver != null) return false
        deliver = callback
        return true
    }

    fun succeed(value: String?) {
        if (value == null || value.isEmpty() || value.length > MAX_QR_LENGTH) {
            finish(PairingQrScanOutcome.Unavailable)
            return
        }
        finish(PairingQrScanOutcome.Raw(value))
    }

    fun cancel() = finish(PairingQrScanOutcome.Cancelled)

    fun fail() = finish(PairingQrScanOutcome.Unavailable)

    private fun finish(outcome: PairingQrScanOutcome) {
        val callback = deliver ?: return
        deliver = null
        callback(outcome)
    }

    private companion object {
        const val MAX_QR_LENGTH = 4096
    }
}
