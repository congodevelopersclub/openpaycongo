package com.congodeveloperclub.opencongopay.sms

internal object SmsCapturePolicy {
    const val MAX_BYTES = 4096
    const val MAX_SEGMENTS = 8
    private const val MAX_AGE_MILLIS = 31L * 24L * 60L * 60L * 1000L
    private const val MAX_FUTURE_SKEW_MILLIS = 5L * 60L * 1000L

    fun accepts(receivedAtMillis: Long, nowMillis: Long, segments: Int, bodyBytes: Int): Boolean {
        val age = nowMillis - receivedAtMillis
        return segments in 1..MAX_SEGMENTS &&
            bodyBytes in 0..MAX_BYTES &&
            age <= MAX_AGE_MILLIS &&
            age >= -MAX_FUTURE_SKEW_MILLIS
    }
}
