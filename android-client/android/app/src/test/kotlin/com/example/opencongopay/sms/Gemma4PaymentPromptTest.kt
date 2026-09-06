package com.congodeveloperclub.opencongopay.sms

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class Gemma4PaymentPromptTest {
    @Test
    fun `prompt binds the trusted sender and exact SMS without server instructions`() {
        val prompt = Gemma4PaymentPrompt.forSms("ORANGE", "Payment received ref REF-1234")
        assertTrue(prompt.contains("sender=ORANGE"))
        assertTrue(prompt.contains("Payment received ref REF-1234"))
        assertTrue(Gemma4PaymentPrompt.systemInstruction.contains("JSON only"))
        assertFalse(Gemma4PaymentPrompt.systemInstruction.contains("http"))
    }
}
