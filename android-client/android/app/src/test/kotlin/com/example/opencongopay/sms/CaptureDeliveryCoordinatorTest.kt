package com.congodeveloperclub.opencongopay.sms

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureDeliveryCoordinatorTest {
    @Test
    fun rejectionKeepsPendingUntilDurableSignalAttemptCompletes() {
        val scheduler = FakeDeadlineScheduler()
        var signalCompletion: (() -> Unit)? = null
        var finishes = 0
        val coordinator = CaptureDeliveryCoordinator(
            dispatch = { _, _ -> null },
            reportMiss = { reason, attempted ->
                assertEquals(CaptureMissReason.overload, reason)
                signalCompletion = attempted
                true
            },
            scheduler = scheduler,
            timeoutMillis = 4_500,
        )

        coordinator.start(capture = {}, finish = { finishes += 1 })
        assertEquals(0, finishes)
        signalCompletion!!.invoke()
        assertEquals(1, finishes)
        scheduler.fire()
        assertEquals(1, finishes)
    }

    @Test
    fun watchdogCancelsWorkAndFinishesExactlyOnceBeforeFiveSeconds() {
        val scheduler = FakeDeadlineScheduler()
        val handle = FakeDispatchHandle()
        val reasons = mutableListOf<CaptureMissReason>()
        var finishes = 0
        val coordinator = CaptureDeliveryCoordinator(
            dispatch = { _, _ -> handle },
            reportMiss = { reason, _ -> reasons.add(reason).let { true } },
            scheduler = scheduler,
            timeoutMillis = 4_500,
        )

        coordinator.start(capture = {}, finish = { finishes += 1 })
        assertEquals(4_500, scheduler.delayMillis)
        scheduler.fire()
        scheduler.fire()
        assertTrue(handle.cancelled)
        assertEquals(listOf(CaptureMissReason.expired), reasons)
        assertEquals(1, finishes)
    }

    @Test
    fun saturatedDeadlineSchedulerFinishesWithoutStartingCapture() {
        var dispatches = 0
        var finishes = 0
        val reasons = mutableListOf<CaptureMissReason>()
        val coordinator = CaptureDeliveryCoordinator(
            dispatch = { _, _ ->
                dispatches += 1
                FakeDispatchHandle()
            },
            reportMiss = { reason, attempted ->
                reasons.add(reason)
                // Reporter may be blocked; scheduler saturation cannot retain PendingResult.
                true
            },
            scheduler = DeliveryDeadlineScheduler { _, _ -> null },
            timeoutMillis = 4_500,
        )
        coordinator.start(capture = {}, finish = { finishes += 1 })
        assertEquals(0, dispatches)
        assertEquals(1, finishes)
        assertEquals(listOf(CaptureMissReason.overload), reasons)
    }

    @Test
    fun `scheduler saturation finishes before blocked reporter returns`() {
        val reporterEntered = CountDownLatch(1)
        val releaseReporter = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val returned = CountDownLatch(1)
        Thread {
            CaptureDeliveryCoordinator(
                dispatch = { _, _ -> throw AssertionError("capture must not dispatch") },
                reportMiss = { _, _ ->
                    reporterEntered.countDown()
                    releaseReporter.await(5, TimeUnit.SECONDS)
                    true
                },
                scheduler = DeliveryDeadlineScheduler { _, _ -> null },
            ).start(capture = {}, finish = finished::countDown)
            returned.countDown()
        }.start()

        assertTrue(reporterEntered.await(1, TimeUnit.SECONDS))
        assertTrue(finished.await(250, TimeUnit.MILLISECONDS))
        assertFalse(returned.await(50, TimeUnit.MILLISECONDS))
        releaseReporter.countDown()
        assertTrue(returned.await(1, TimeUnit.SECONDS))
    }

    @Test
    fun `real scheduler saturation reports overload best effort and finishes immediately`() {
        val scheduler = SystemDeliveryDeadlineScheduler(maxOutstanding = 1)
        val occupied = scheduler.schedule(TimeUnit.SECONDS.toMillis(30)) {}
        val finished = CountDownLatch(1)
        val reasons = mutableListOf<CaptureMissReason>()
        CaptureDeliveryCoordinator(
            dispatch = { _, _ -> throw AssertionError("capture must not dispatch") },
            reportMiss = { reason, _ -> reasons.add(reason).let { true } },
            scheduler = scheduler,
        ).start(capture = {}, finish = finished::countDown)

        assertTrue(finished.await(250, TimeUnit.MILLISECONDS))
        assertEquals(listOf(CaptureMissReason.overload), reasons)
        occupied!!.cancel()
        scheduler.closeForTest()
    }

    @Test
    fun systemSchedulerRejectsBoundedSaturationWithoutRunningDeadlineTask() {
        val scheduler = SystemDeliveryDeadlineScheduler(maxOutstanding = 1)
        val first = scheduler.schedule(TimeUnit.SECONDS.toMillis(30)) {}
        var ran = false
        val second = scheduler.schedule(TimeUnit.SECONDS.toMillis(30)) { ran = true }
        assertTrue(first != null)
        assertEquals(null, second)
        assertFalse(ran)
        first!!.cancel()
        scheduler.closeForTest()
    }

    @Test
    fun durableReporterAttemptsPersistenceThenCompletesExactlyOnce() {
        val reporter = DurableCaptureMissReporter()
        val attempted = CountDownLatch(1)
        var writes = 0
        var completions = 0
        assertTrue(reporter.report(
            persist = { writes += 1 },
            attempted = {
                completions += 1
                attempted.countDown()
            },
        ))
        assertTrue(attempted.await(5, TimeUnit.SECONDS))
        assertEquals(1, writes)
        assertEquals(1, completions)
        reporter.closeForTest()
    }
}

private class FakeDispatchHandle : CaptureDispatchHandle {
    var cancelled = false
    override fun cancel() {
        cancelled = true
    }
}

private class FakeDeadlineScheduler(
    private val fireImmediately: Boolean = false,
) : DeliveryDeadlineScheduler {
    var delayMillis = 0L
    private var task: (() -> Unit)? = null
    private var cancelled = false
    override fun schedule(delayMillis: Long, task: () -> Unit): DeadlineHandle {
        this.delayMillis = delayMillis
        this.task = task
        cancelled = false
        if (fireImmediately) task()
        return object : DeadlineHandle {
            override fun cancel() {
                cancelled = true
            }
        }
    }

    fun fire() {
        if (!cancelled) task?.invoke()
    }
}
