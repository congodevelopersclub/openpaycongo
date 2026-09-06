package com.congodeveloperclub.opencongopay.sms

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.SamplerConfig
import java.io.File
import java.nio.charset.StandardCharsets

/** On-device-only Gemma 4 adapter. A release process provisions the model. */
internal class Gemma4PaymentRuntime(private val context: Context) : AutoCloseable {
    private val modelFile = File(context.filesDir, "models/gemma4-payment.litertlm")
    private var engine: Engine? = null

    @Synchronized
    fun propose(sender: String, body: String): String {
        require(SenderRules.normalize(sender) == sender)
        require(body.toByteArray(StandardCharsets.UTF_8).size <= 4096)
        require(modelFile.isFile && modelFile.extension == "litertlm") { "gemma_model_missing" }
        val response = engine().createConversation(
            ConversationConfig(
                systemInstruction = Contents.of(Gemma4PaymentPrompt.systemInstruction),
                samplerConfig = SamplerConfig(topK = 1, topP = 1.0, temperature = 0.0),
                maxOutputToken = 160,
            ),
        ).use { conversation ->
            conversation.sendMessage(Gemma4PaymentPrompt.forSms(sender, body)).text
        }
        require(response.toByteArray(StandardCharsets.UTF_8).size <= 2048) { "gemma_response_oversized" }
        return response
    }

    @Synchronized
    private fun engine(): Engine = engine ?: Engine(
        EngineConfig(
            modelPath = modelFile.absolutePath,
            backend = Backend.CPU(),
            cacheDir = context.cacheDir.absolutePath,
        ),
    ).also {
        it.initialize()
        engine = it
    }

    @Synchronized
    override fun close() {
        engine?.close()
        engine = null
    }
}

/** Prompt construction is testable without a model and never contains a URL. */
internal object Gemma4PaymentPrompt {
    const val systemInstruction = """
        Extract a payment notification into exactly one compact JSON object. Return JSON only,
        with exactly these keys: amount_minor, currency, reference, provider, confidence.
        amount_minor must be a positive integer in minor units. currency is CDF or USD.
        reference is uppercase letters, digits, and hyphens. provider must equal the supplied
        sender. confidence is a number from 0 through 1. If anything is uncertain, still emit
        the object with low confidence; never invent a reference or amount.
    """

    fun forSms(sender: String, body: String): String =
        "sender=$sender\npayment_sms=\"\"\"$body\"\"\""
}
