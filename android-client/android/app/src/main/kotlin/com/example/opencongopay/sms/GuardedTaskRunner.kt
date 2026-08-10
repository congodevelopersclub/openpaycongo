package com.congodeveloperclub.opencongopay.sms

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

internal enum class GuardedSubmitResult { accepted, busy }
internal class GuardedTaskTimeoutException : Exception("outcome_unknown")
internal class GuardedTaskBusyException : Exception("gateway_busy")

internal class GuardedTaskRunner(
    threads: Int = 1,
    queueCapacity: Int = 16,
    private val operationTimeoutMillis: Long = 3_000,
    private val isCurrent: (Long) -> Boolean,
    private val deliver: (() -> Unit) -> Unit,
) {
    private data class Pending(
        val completed: AtomicBoolean,
        val onDenied: () -> Unit,
        val task: AtomicReference<Future<*>?> = AtomicReference(null),
        val deadline: AtomicReference<ScheduledFuture<*>?> = AtomicReference(null),
    )

    private val nextId = AtomicLong(0)
    private val pending = ConcurrentHashMap<Long, Pending>()
    private val closed = AtomicBoolean(false)
    private val executor = ThreadPoolExecutor(
        threads,
        threads,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(queueCapacity),
        ThreadPoolExecutor.AbortPolicy(),
    )
    private val deadlines = Executors.newSingleThreadScheduledExecutor()

    init {
        require(threads == 1)
        require(queueCapacity in 1..32)
        require(operationTimeoutMillis in 1..5_000)
    }

    @Synchronized
    fun <T> submit(
        generation: Long,
        operation: () -> T,
        onSuccess: (T) -> Unit,
        onFailure: (Throwable) -> Unit,
        onDenied: () -> Unit,
    ): GuardedSubmitResult {
        val id = nextId.incrementAndGet()
        val request = Pending(AtomicBoolean(false), onDenied)
        pending[id] = request
        fun complete(callback: () -> Unit) {
            if (!request.completed.compareAndSet(false, true)) return
            pending.remove(id)
            request.deadline.get()?.cancel(false)
            deliver {
                if (closed.get()) request.onDenied() else callback()
            }
        }
        if (closed.get()) {
            complete(onDenied)
            return GuardedSubmitResult.busy
        }
        try {
            request.deadline.set(
                deadlines.schedule(
                    {
                        complete {
                            if (isCurrent(generation)) {
                                onFailure(GuardedTaskTimeoutException())
                            } else {
                                onDenied()
                            }
                        }
                        request.task.get()?.cancel(true)
                    },
                    operationTimeoutMillis,
                    TimeUnit.MILLISECONDS,
                ),
            )
        } catch (_: RejectedExecutionException) {
            complete { onFailure(GuardedTaskBusyException()) }
            return GuardedSubmitResult.busy
        }
        if (request.completed.get()) return GuardedSubmitResult.accepted
        return try {
            request.task.set(
                executor.submit {
                    if (request.completed.get()) return@submit
                    if (!isCurrent(generation)) {
                        complete(onDenied)
                        return@submit
                    }
                    try {
                        val value = operation()
                        complete {
                            if (isCurrent(generation)) onSuccess(value) else onDenied()
                        }
                    } catch (error: Throwable) {
                        complete {
                            if (isCurrent(generation)) onFailure(error) else onDenied()
                        }
                    }
                },
            )
            GuardedSubmitResult.accepted
        } catch (_: RejectedExecutionException) {
            complete { onFailure(GuardedTaskBusyException()) }
            GuardedSubmitResult.busy
        }
    }

    @Synchronized
    fun close() {
        if (!closed.compareAndSet(false, true)) return
        executor.shutdownNow()
        deadlines.shutdownNow()
        pending.forEach { (id, request) ->
            if (request.completed.compareAndSet(false, true)) {
                pending.remove(id)
                request.deadline.get()?.cancel(false)
                request.task.get()?.cancel(true)
                deliver(request.onDenied)
            }
        }
    }
}
