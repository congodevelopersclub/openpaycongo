package com.congodeveloperclub.opencongopay.sms

import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GuardedTaskRunnerTest {
    @Test
    fun staleGenerationCannotDeliverCompletedStorageResult() {
        val current = AtomicBoolean(true)
        val deliveries = CopyOnWriteArrayList<() -> Unit>()
        val operationDone = CountDownLatch(1)
        val denied = CountDownLatch(1)
        var delivered: String? = null
        val runner = GuardedTaskRunner(
            threads = 1,
            queueCapacity = 1,
            isCurrent = { current.get() },
            deliver = { callback -> deliveries.add(callback) },
        )
        assertEquals(
            GuardedSubmitResult.accepted,
            runner.submit(
                generation = 1,
                operation = { "secret".also { operationDone.countDown() } },
                onSuccess = { delivered = it },
                onFailure = { throw AssertionError(it) },
                onDenied = { denied.countDown() },
            ),
        )
        assertTrue(operationDone.await(5, TimeUnit.SECONDS))
        while (deliveries.isEmpty()) Thread.yield()
        current.set(false)
        deliveries.single().invoke()
        assertTrue(denied.await(5, TimeUnit.SECONDS))
        assertEquals(null, delivered)
        runner.close()
    }

    @Test
    fun bridgeExecutorHasBoundedQueueAndExplicitBusyResult() {
        val release = CountDownLatch(1)
        val started = CountDownLatch(1)
        val runner = GuardedTaskRunner(
            threads = 1,
            queueCapacity = 1,
            isCurrent = { true },
            deliver = { it() },
        )
        assertEquals(GuardedSubmitResult.accepted, runner.submit(1, {
            started.countDown()
            release.await(5, TimeUnit.SECONDS)
        }, {}, {}, {}))
        assertTrue(started.await(5, TimeUnit.SECONDS))
        assertEquals(GuardedSubmitResult.accepted, runner.submit(1, {}, {}, {}, {}))
        assertEquals(GuardedSubmitResult.busy, runner.submit(1, {}, {}, {}, {}))
        release.countDown()
        runner.close()
    }

    @Test
    fun closeCompletesPendingBridgeCallbackExactlyOnce() {
        val started = CountDownLatch(1)
        val denied = AtomicInteger(0)
        val failures = AtomicInteger(0)
        val runner = GuardedTaskRunner(
            threads = 1,
            queueCapacity = 1,
            isCurrent = { true },
            deliver = { it() },
        )
        assertEquals(GuardedSubmitResult.accepted, runner.submit(1, {
            started.countDown()
            CountDownLatch(1).await()
        }, {}, { failures.incrementAndGet() }, { denied.incrementAndGet() }))
        assertTrue(started.await(5, TimeUnit.SECONDS))
        val closeStarted = System.nanoTime()
        runner.close()
        val closeMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - closeStarted)
        assertTrue("close blocked for ${closeMillis}ms", closeMillis < 500)
        assertEquals(1, denied.get())
        assertEquals(0, failures.get())
    }

    @Test
    fun operationDeadlineCancelsWorkAndCompletesCallbackExactlyOnce() {
        val started = CountDownLatch(1)
        val interrupted = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val successes = AtomicInteger(0)
        val failures = AtomicInteger(0)
        val outcome = java.util.concurrent.atomic.AtomicReference<String?>()
        val denied = AtomicInteger(0)
        val runner = GuardedTaskRunner(
            threads = 1,
            queueCapacity = 1,
            operationTimeoutMillis = 50,
            isCurrent = { true },
            deliver = { it() },
        )

        assertEquals(GuardedSubmitResult.accepted, runner.submit(1, {
            started.countDown()
            try {
                CountDownLatch(1).await()
            } catch (_: InterruptedException) {
                interrupted.countDown()
            }
            "late"
        }, {
            successes.incrementAndGet()
            completed.countDown()
        }, { error ->
            if (error is GuardedTaskTimeoutException) {
                failures.incrementAndGet()
                outcome.set(error.message)
            }
            completed.countDown()
        }, {
            denied.incrementAndGet()
            completed.countDown()
        }))

        assertTrue(started.await(5, TimeUnit.SECONDS))
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertTrue(interrupted.await(5, TimeUnit.SECONDS))
        Thread.sleep(25)
        assertEquals(0, successes.get())
        assertEquals(1, failures.get())
        assertEquals("outcome_unknown", outcome.get())
        assertEquals(0, denied.get())
        runner.close()
    }

    @Test
    fun `submission deadline starts before enqueue and queued mutation never runs late`() {
        val release = CountDownLatch(1)
        val firstStarted = CountDownLatch(1)
        val completed = CountDownLatch(2)
        val outcomesUnknown = AtomicInteger(0)
        val secondRan = AtomicBoolean(false)
        val runner = GuardedTaskRunner(
            queueCapacity = 1,
            operationTimeoutMillis = 50,
            isCurrent = { true },
            deliver = { it() },
        )
        runner.submit(1, {
            firstStarted.countDown()
            while (release.count > 0) {
                try { release.await(10, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) {}
            }
        }, {}, { error ->
            if (error is GuardedTaskTimeoutException) outcomesUnknown.incrementAndGet()
            completed.countDown()
        }, { completed.countDown() })
        assertTrue(firstStarted.await(1, TimeUnit.SECONDS))
        runner.submit(1, { secondRan.set(true) }, {}, { error ->
            if (error is GuardedTaskTimeoutException) outcomesUnknown.incrementAndGet()
            completed.countDown()
        }, { completed.countDown() })

        assertTrue(completed.await(1, TimeUnit.SECONDS))
        assertEquals(2, outcomesUnknown.get())
        assertFalse(secondRan.get())
        release.countDown()
        runner.close()
    }

    @Test
    fun `close and submit share barrier and callback completes once internally`() {
        val denied = AtomicInteger(0)
        val ran = AtomicBoolean(false)
        val runner = GuardedTaskRunner(
            queueCapacity = 1,
            isCurrent = { true },
            deliver = { it() },
        )
        runner.close()
        runner.submit(1, { ran.set(true) }, {}, { throw AssertionError(it) }, {
            denied.incrementAndGet()
        })
        assertFalse(ran.get())
        assertEquals(1, denied.get())
    }
}
