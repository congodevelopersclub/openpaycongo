package com.congodeveloperclub.opencongopay.sms

internal object SenderRules {
    private val phone = Regex("^\\+[1-9][0-9]{7,14}$")
    private val alpha = Regex("^[A-Z0-9]{3,11}$")

    fun normalize(value: String?): String? {
        val candidate = value?.trim() ?: return null
        return candidate.takeIf { phone.matches(it) || alpha.matches(it) }
    }
}
