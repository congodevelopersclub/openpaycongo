package com.congodeveloperclub.opencongopay.sms

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal enum class CaptureMissReason { overload, expired }

internal fun interface CaptureDispatchHandle {
    fun cancel()
}

internal class BoundedCaptureDispatcher(
    threads: Int = 2,
    queueCapacity: Int = 32,
    private val maxQueueDelayNanos: Long = TimeUnit.SECONDS.toNanos(4),
    private val nowNanos: () -> Long = System::nanoTime,
) {
    private val executor = ThreadPoolExecutor(
        threads,
        threads,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(queueCapacity),
        ThreadPoolExecutor.AbortPolicy(),
    )

    init {
        require(threads in 1..4)
        require(queueCapacity in 1..64)
        require(maxQueueDelayNanos in 1..TimeUnit.SECONDS.toNanos(4))
    }

    fun dispatch(onExpired: () -> Unit, task: () -> Unit): CaptureDispatchHandle? {
        val submittedAt = nowNanos()
        val deadline = if (Long.MAX_VALUE - submittedAt < maxQueueDelayNanos) {
            Long.MAX_VALUE
        } else {
            submittedAt + maxQueueDelayNanos
        }
        return try {
            val future = executor.submit {
                if (nowNanos() > deadline) onExpired() else task()
            }
            CaptureDispatchHandle { future.cancel(true) }
        } catch (_: RejectedExecutionException) {
            null
        }
    }

    internal fun closeForTest() {
        executor.shutdownNow()
        executor.awaitTermination(5, TimeUnit.SECONDS)
    }
}
