package com.congodeveloperclub.opencongopay.sms

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

internal fun interface DeadlineHandle {
    fun cancel()
}

internal fun interface DeliveryDeadlineScheduler {
    fun schedule(delayMillis: Long, task: () -> Unit): DeadlineHandle?
}

internal class SystemDeliveryDeadlineScheduler(
    private val maxOutstanding: Int = 64,
) : DeliveryDeadlineScheduler {
    private val executor = Executors.newSingleThreadScheduledExecutor()
    private val outstanding = AtomicInteger(0)

    init {
        require(maxOutstanding in 1..64)
    }

    override fun schedule(delayMillis: Long, task: () -> Unit): DeadlineHandle? {
        if (outstanding.incrementAndGet() > maxOutstanding) {
            outstanding.decrementAndGet()
            return null
        }
        val released = AtomicBoolean(false)
        val release = { if (released.compareAndSet(false, true)) outstanding.decrementAndGet() }
        val future: ScheduledFuture<*> = executor.schedule(
            {
                try {
                    task()
                } finally {
                    release()
                }
            },
            delayMillis,
            TimeUnit.MILLISECONDS,
        )
        return DeadlineHandle {
            future.cancel(false)
            release()
        }
    }

    internal fun closeForTest() {
        executor.shutdownNow()
    }
}

internal class CaptureDeliveryCoordinator(
    private val dispatch: (onExpired: () -> Unit, task: () -> Unit) -> CaptureDispatchHandle?,
    private val reportMiss: (CaptureMissReason, attempted: () -> Unit) -> Boolean,
    private val scheduler: DeliveryDeadlineScheduler,
    private val timeoutMillis: Long = 4_500,
) {
    init {
        require(timeoutMillis in 1..4_500)
    }

    fun start(capture: () -> Unit, finish: () -> Unit) {
        val finished = AtomicBoolean(false)
        val dispatchHandle = AtomicReference<CaptureDispatchHandle?>()
        val deadlineHandle = AtomicReference<DeadlineHandle?>()
        val finishOnce = {
            if (finished.compareAndSet(false, true)) {
                deadlineHandle.get()?.cancel()
                finish()
            }
        }
        val reportThenFinish = { reason: CaptureMissReason ->
            if (!reportMiss(reason) { finishOnce() }) finishOnce()
        }

        val scheduled = scheduler.schedule(timeoutMillis) {
            dispatchHandle.get()?.cancel()
            reportMiss(CaptureMissReason.expired) {}
            finishOnce()
        }
        if (scheduled == null) {
            // PendingResult must not depend on a saturated or blocked reporter.
            finishOnce()
            reportMiss(CaptureMissReason.overload) {}
            return
        }
        deadlineHandle.set(scheduled)
        if (finished.get()) {
            scheduled.cancel()
            return
        }
        val handle = dispatch(
            { reportThenFinish(CaptureMissReason.expired) },
            {
                if (!finished.get()) {
                    try {
                        capture()
                    } finally {
                        finishOnce()
                    }
                }
            },
        )
        dispatchHandle.set(handle)
        if (handle == null) reportThenFinish(CaptureMissReason.overload)
    }
}
