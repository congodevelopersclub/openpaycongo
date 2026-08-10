package com.congodeveloperclub.opencongopay.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import java.nio.charset.StandardCharsets
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

class SmsDeliverReceiver : BroadcastReceiver() {
    companion object {
        private val dispatcher = BoundedCaptureDispatcher()
        private val missReporter = DurableCaptureMissReporter()
        private val scheduler = SystemDeliveryDeadlineScheduler()
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val pending = goAsync()
        val applicationContext = context.applicationContext
        CaptureDeliveryCoordinator(
            dispatch = dispatcher::dispatch,
            reportMiss = { reason, attempted ->
                missReporter.report(
                    persist = { SmsVaultProvider.get(applicationContext).recordMissSignal(reason) },
                    attempted = attempted,
                )
            },
            scheduler = scheduler,
        ).start(
            capture = { capture(applicationContext, intent) },
            finish = pending::finish,
        )
    }

    private fun capture(context: Context, intent: Intent) {
        if (Thread.currentThread().isInterrupted) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty() || messages.size > SmsCapturePolicy.MAX_SEGMENTS) return
        val sender = SenderRules.normalize(messages.first().originatingAddress) ?: return
        if (messages.any { SenderRules.normalize(it.originatingAddress) != sender }) return
        if (Thread.currentThread().isInterrupted) return
        val vault = SmsVaultProvider.get(context)
        if (!vault.isTrustedSender(sender) || Thread.currentThread().isInterrupted) return

        val now = System.currentTimeMillis()
        val receivedAt = messages.minOf { it.timestampMillis }
        val body = buildString {
            messages.forEach { message ->
                if (Thread.currentThread().isInterrupted) return
                append(message.messageBody ?: return)
            }
        }
        if (!SmsCapturePolicy.accepts(
                receivedAt,
                now,
                messages.size,
                body.toByteArray(StandardCharsets.UTF_8).size,
            ) || Thread.currentThread().isInterrupted
        ) return
        val provisional = TrustedSmsRecord("", sender, receivedAt, messages.size, body)
        vault.persistIfAbsent(provisional.copy(id = vault.digest(provisional)))
    }
}

internal class DurableCaptureMissReporter {
    private data class Request(val persist: () -> Unit, val attempted: () -> Unit)

    private val requests = ArrayBlockingQueue<Request>(64)
    private var running = false
    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(1),
        ThreadPoolExecutor.AbortPolicy(),
    )

    @Synchronized
    fun report(persist: () -> Unit, attempted: () -> Unit): Boolean {
        val request = Request(persist, attempted)
        if (!requests.offer(request)) return false
        if (running) return true
        running = true
        return try {
            executor.execute(::drain)
            true
        } catch (_: RejectedExecutionException) {
            running = false
            requests.remove(request)
            false
        }
    }

    private fun drain() {
        try {
            while (true) {
                val request = requests.poll() ?: return
                try {
                    request.persist()
                } catch (_: Exception) {
                    // A failed write is still a bounded attempt; process death may erase this signal.
                } finally {
                    request.attempted()
                }
            }
        } finally {
            restartIfNeeded()
        }
    }

    @Synchronized
    private fun restartIfNeeded() {
        running = false
        if (requests.isEmpty()) return
        running = true
        try {
            executor.execute(::drain)
        } catch (_: RejectedExecutionException) {
            running = false
            while (true) requests.poll()?.attempted?.invoke() ?: return
        }
    }

    internal fun closeForTest() {
        executor.shutdownNow()
    }
}
