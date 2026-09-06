package com.example.espflash_flutter.usb

import org.junit.Assert.*
import org.junit.Test
import java.util.PriorityQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

class UsbDiscoveryObserverTest {
    private class Clock {
        var now = 0L
        private var order = 0L
        private data class Task(val due: Long, val order: Long, val run: () -> Unit, var canceled: Boolean = false)
        private val tasks = PriorityQueue<Task>(compareBy<Task> { it.due }.thenBy { it.order })
        fun schedule(delay: Long, block: () -> Unit): UsbScanTimer {
            val task = Task(now + delay, ++order, block)
            tasks += task
            return UsbScanTimer { task.canceled = true }
        }
        fun advanceTo(target: Long) {
            while (tasks.isNotEmpty() && tasks.peek().due <= target) {
                val task = tasks.remove()
                now = task.due
                if (!task.canceled) task.run()
            }
            now = target
        }
    }

    private class QueuedExecutor : Executor {
        val tasks = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { tasks.addLast(command) }
        fun runAll() { while (tasks.isNotEmpty()) tasks.removeFirst().run() }
    }

    private class Fixture(val enrichment: Executor = Executor { it.run() }) {
        val clock = Clock()
        val events = mutableListOf<Map<String, Any?>>()
        val logs = mutableListOf<String>()
        var roster: () -> Map<String, String> = { emptyMap() }
        var enrich: (String, String) -> Map<String, Any?> = { id, _ ->
            mapOf("deviceId" to id, "probeStatus" to "supported")
        }
        val observer = UsbDiscoveryObserver(
            schedule = clock::schedule,
            nowMs = { clock.now },
            enrichmentExecutor = enrichment,
            enumerate = { roster() },
            enrich = { id, device -> enrich(id, device) },
            emit = { events += it }, log = { logs += it },
        )
        fun raw() = events.filter { it["stage"] == "raw" }
        @Suppress("UNCHECKED_CAST")
        fun devices(event: Map<String, Any?>) = event["devices"] as List<Map<String, Any?>>
    }

    @Test fun `watchdog observes appearances at 3 5 10 and 30 seconds with no new hint`() {
        for (seconds in listOf(3, 5, 10, 30)) {
            val f = Fixture()
            f.roster = { if (f.clock.now >= seconds * 1000L) mapOf("board" to "esp") else emptyMap() }
            f.observer.start()
            f.clock.advanceTo(seconds * 1000L - 1)
            assertTrue(f.raw().all { f.devices(it).isEmpty() })
            f.clock.advanceTo(seconds * 1000L)
            assertEquals("board", f.devices(f.raw().last()).single()["deviceId"])
            assertEquals("supported", f.devices(f.events.last()).single()["probeStatus"])
            f.observer.dispose()
        }
    }

    @Test fun `repeated bursts cannot postpone the independent watchdog`() {
        val f = Fixture()
        f.observer.start()
        for (time in 0L..30_000L step 100L) {
            f.observer.requestBurst("repeated-hint")
            f.clock.advanceTo(time)
        }
        val watchdogTicks = f.logs.count {
            (it.contains("stage=scan-started") || it.contains("stage=scan-coalesced")) &&
                it.contains("reason=watchdog")
        }
        assertEquals(30, watchdogTicks)
        assertTrue(f.raw().zipWithNext().all { (a, b) ->
            (a["sequence"] as Long) < (b["sequence"] as Long)
        })
    }

    @Test fun `late Flutter subscription receives current observer health`() {
        val f = Fixture()
        f.observer.start()
        f.clock.advanceTo(3000)
        f.events.clear() // The earlier events had no Flutter subscriber.
        f.observer.subscriberReady()
        val health = f.events.single()
        assertEquals("observerState", health["type"])
        assertEquals(true, health["active"])
        f.clock.advanceTo(4000)
        assertTrue(f.raw().isNotEmpty())
    }

    @Test fun `nonempty roster continues to be scanned and missed detach converges`() {
        val f = Fixture()
        f.roster = { if (f.clock.now < 10_000) mapOf("board" to "esp") else emptyMap() }
        f.observer.start()
        f.clock.advanceTo(9000)
        assertEquals(1, f.devices(f.raw().last()).size)
        f.clock.advanceTo(10_000)
        assertTrue(f.devices(f.raw().last()).isEmpty())
    }

    @Test fun `enumeration exception has no empty roster and watchdog recovers`() {
        val f = Fixture()
        var fail = false
        f.roster = { if (fail) throw SecurityException("host query failed") else mapOf("board" to "esp") }
        f.observer.start()
        f.clock.advanceTo(2000)
        fail = true
        f.clock.advanceTo(3000)
        val error = f.raw().last()
        assertEquals("error", error["status"])
        assertFalse(error.containsKey("devices"))
        assertTrue((error["scanError"] as String).contains("SecurityException"))
        fail = false
        f.clock.advanceTo(4000)
        assertEquals("ok", f.raw().last()["status"])
        assertEquals(1, f.devices(f.raw().last()).size)
    }

    @Test fun `raw-only API never probes or reads optional metadata`() {
        val f = Fixture()
        f.roster = { mapOf("board" to "esp") }
        f.enrich = { _, _ -> error("Must not enrich an explicit raw request") }
        var reply: Map<String, Any?>? = null
        f.observer.scanOnce { reply = it }
        f.clock.advanceTo(0)
        assertEquals("pending", f.devices(reply!!).single()["probeStatus"])
        assertFalse(f.devices(reply!!).single().containsKey("vendorId"))
        assertTrue(f.events.none { it["stage"] == "enriched" })
    }

    @Test fun `a broken enricher preserves that device and its neighbors`() {
        val f = Fixture()
        f.roster = { linkedMapOf("broken" to "bad", "good" to "esp") }
        f.enrich = { id, _ ->
            if (id == "broken") throw IllegalStateException("bad descriptor")
            mapOf("probeStatus" to "supported")
        }
        f.observer.start()
        f.clock.advanceTo(0)
        assertEquals(2, f.devices(f.raw().single()).size)
        val enriched = f.devices(f.events.last())
        assertEquals("error", enriched[0]["probeStatus"])
        assertEquals("supported", enriched[1]["probeStatus"])
    }

    @Test fun `delayed enrichment cannot block raw scans or overwrite newer attachments`() {
        val worker = QueuedExecutor()
        val f = Fixture(worker)
        f.roster = { if (f.clock.now < 3000) mapOf("old" to "esp") else mapOf("new" to "esp") }
        f.observer.start()
        f.clock.advanceTo(5000)
        assertEquals("new", f.devices(f.raw().last()).single()["deviceId"])
        assertEquals(1, worker.tasks.size) // One worker, one replaceable pending snapshot.
        worker.runAll()
        val enriched = f.events.filter { it["stage"] == "enriched" }
        assertEquals(1, enriched.size)
        assertEquals(f.raw().last()["sequence"], enriched.single()["sequence"])
        assertEquals("new", f.devices(enriched.single()).single()["deviceId"])
    }

    @Test fun `running enrichment from an old sequence is discarded`() {
        val f = Fixture()
        var first = true
        f.roster = { if (f.clock.now == 0L) mapOf("old" to "esp") else mapOf("new" to "esp") }
        f.enrich = { _, _ ->
            if (first) {
                first = false
                // Simulate raw worker advancing while enrichment is slow.
                f.clock.advanceTo(1000)
            }
            mapOf("probeStatus" to "supported")
        }
        f.observer.start()
        f.clock.advanceTo(0)
        assertTrue(f.logs.any { it.contains("stage=enrichment-discarded") })
        assertTrue(f.events.filter { it["stage"] == "enriched" }.all {
            f.devices(it).single()["deviceId"] == "new"
        })
    }

    @Test fun `background cancels scans and resume invalidates old enrichment`() {
        val worker = QueuedExecutor()
        val f = Fixture(worker)
        f.roster = { mapOf("board" to "esp") }
        f.observer.start()
        f.clock.advanceTo(0)
        val oldEpoch = f.raw().last()["epoch"]
        f.observer.stop()
        f.clock.advanceTo(30_000)
        worker.runAll()
        assertEquals(1, f.raw().size)
        assertTrue(f.events.none { it["stage"] == "enriched" })
        f.observer.start()
        f.clock.advanceTo(30_000)
        assertNotEquals(oldEpoch, f.raw().last()["epoch"])
        worker.runAll()
        assertEquals(f.raw().last()["epoch"], f.events.last()["epoch"])
        f.observer.dispose()
        val count = f.events.size
        f.clock.advanceTo(60_000)
        assertEquals(count, f.events.size)
    }

    @Test fun `a blocked USB operation does not block raw discovery or enrichment`() {
        val workers = UsbObserverWorkers()
        val enteredOpen = CountDownLatch(1)
        val releaseOpen = CountDownLatch(1)
        val observed = CountDownLatch(1)
        val enriched = CountDownLatch(1)
        val observer = UsbDiscoveryObserver(
            schedule = workers::schedule,
            nowMs = { System.nanoTime() / 1_000_000 },
            enrichmentExecutor = workers.enrichment,
            enumerate = { mapOf("board" to "esp") },
            enrich = { _, _: String -> mapOf("probeStatus" to "supported") },
            emit = {
                if (it["stage"] == "raw") observed.countDown()
                if (it["stage"] == "enriched") enriched.countDown()
            }, log = {},
        )
        try {
            workers.operations.execute {
                enteredOpen.countDown()
                releaseOpen.await(5, TimeUnit.SECONDS)
            }
            assertTrue(enteredOpen.await(2, TimeUnit.SECONDS))
            observer.start()
            assertTrue(observed.await(2, TimeUnit.SECONDS))
            assertTrue(enriched.await(2, TimeUnit.SECONDS))
            assertEquals(1L, releaseOpen.count)
        } finally {
            observer.dispose()
            releaseOpen.countDown()
            workers.discovery.shutdownNow()
            workers.enrichment.shutdownNow()
            workers.operations.shutdownNow()
        }
    }
}
