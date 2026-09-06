package com.example.espflash_flutter.usb

import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicLong

/** A cancellable timer. Production uses one dedicated scheduled executor. */
fun interface UsbScanTimer {
    fun cancel()
}

/**
 * Raw discovery never calls a driver or reads optional metadata. The scheduler
 * serializes raw scans on its own worker, independently of USB port operations.
 * Enrichment has another worker and a single replaceable pending snapshot.
 *
 * No Android/Flutter dependencies: timing and failure behavior are JVM-testable.
 */
class UsbDiscoveryObserver<T>(
    private val schedule: (Long, () -> Unit) -> UsbScanTimer,
    private val nowMs: () -> Long,
    private val enrichmentExecutor: Executor,
    private val enumerate: () -> Map<String, T>,
    private val enrich: (String, T) -> Map<String, Any?>,
    private val emit: (Map<String, Any?>) -> Unit,
    private val log: (String) -> Unit,
) {
    companion object {
        private val epochs = AtomicLong(System.currentTimeMillis())
        private val burstDelays = longArrayOf(0, 100, 250, 500, 1000, 2000)
    }

    private val lock = Any()
    private var active = false
    private var disposed = false
    private var epoch = epochs.incrementAndGet()
    private var sequence = 0L
    private var requestId = 0L
    private var watchdog: UsbScanTimer? = null
    private val burst = mutableListOf<UsbScanTimer>()
    private var pendingEnrichment: Enrichment<T>? = null
    private var enrichmentRunning = false
    private var lastRaw: Map<String, Any?>? = null

    private data class Enrichment<T>(
        val epoch: Long,
        val sequence: Long,
        val raw: Map<String, T>,
        val snapshot: Map<String, Any?>,
    )

    fun start() = synchronized(lock) {
        if (disposed || active) return@synchronized
        active = true
        epoch = epochs.incrementAndGet()
        sequence = 0
        lastRaw = null
        emitState()
        requestBurst("foreground-start")
        scheduleWatchdog(epoch)
    }

    fun stop() = synchronized(lock) {
        if (!active) return@synchronized
        active = false
        epoch = epochs.incrementAndGet()
        sequence = 0
        watchdog?.cancel()
        watchdog = null
        burst.forEach { it.cancel() }
        burst.clear()
        pendingEnrichment = null
        lastRaw = null
        emitState()
    }

    fun dispose() = synchronized(lock) {
        stop()
        disposed = true
        pendingEnrichment = null
    }

    private fun emitState() {
        log("epoch=$epoch stage=observer-state active=$active nowMs=${nowMs()}")
        emit(mapOf("type" to "observerState", "epoch" to epoch,
            "active" to active, "nativeTimeMs" to nowMs()))
    }

    /** Cold-start subscribers must receive observer health even if start()
     * happened before Flutter installed its EventChannel listener. */
    fun subscriberReady() = synchronized(lock) {
        if (disposed) return@synchronized
        emitState()
        requestBurst("events-listen")
    }

    /** These hints never cancel or postpone the watchdog. */
    fun requestBurst(reason: String) = synchronized(lock) {
        if (disposed || !active) return@synchronized
        burst.forEach { it.cancel() }
        burst.clear()
        val currentEpoch = epoch
        for (delay in burstDelays) {
            val requestedAt = nowMs()
            val due = requestedAt + delay
            val request = ++requestId
            log("epoch=$currentEpoch request=$request stage=scan-scheduled reason=$reason nowMs=$requestedAt dueMs=$due")
            burst += schedule(delay) { scan(currentEpoch, reason, request, requestedAt, due) }
        }
    }

    private fun scheduleWatchdog(currentEpoch: Long) {
        val requestedAt = nowMs()
        val due = requestedAt + 1000
        val request = ++requestId
        log("epoch=$currentEpoch request=$request stage=scan-scheduled reason=watchdog nowMs=$requestedAt dueMs=$due")
        watchdog = schedule(1000) {
            scan(currentEpoch, "watchdog", request, requestedAt, due)
            synchronized(lock) {
                if (active && !disposed && epoch == currentEpoch) {
                    scheduleWatchdog(currentEpoch)
                }
            }
        }
    }

    /** Explicit raw-only diagnostic request, also allowed while backgrounded. */
    fun scanOnce(reply: (Map<String, Any?>) -> Unit) = synchronized(lock) {
        if (disposed) {
            reply(mapOf("type" to "snapshot", "epoch" to epoch,
                "sequence" to sequence, "stage" to "raw", "status" to "error",
                "scanError" to "Observer disposed"))
            return@synchronized
        }
        val currentEpoch = epoch
        val due = nowMs()
        val request = ++requestId
        log("epoch=$currentEpoch request=$request stage=scan-scheduled reason=explicit-raw nowMs=$due dueMs=$due")
        schedule(0) { scan(currentEpoch, "explicit-raw", request, due, due, reply) }
    }

    private fun scan(
        currentEpoch: Long,
        reason: String,
        request: Long,
        scheduledAt: Long,
        dueAt: Long,
        reply: ((Map<String, Any?>) -> Unit)? = null,
    ) {
        val startedAt = nowMs()
        val scanSequence = synchronized(lock) {
            if (disposed || epoch != currentEpoch || (!active && reply == null)) {
                reply?.invoke(mapOf("type" to "snapshot", "epoch" to currentEpoch,
                    "sequence" to sequence, "stage" to "raw", "status" to "error",
                    "scanError" to "Observation canceled by lifecycle change"))
                return
            }
            // A burst and watchdog due on the same tick need only one read.
            val previous = lastRaw
            if (previous != null && previous["startedAtMs"] == startedAt) {
                log("epoch=$epoch seq=$sequence request=$request stage=scan-coalesced reason=$reason nowMs=$startedAt")
                reply?.invoke(previous)
                return
            }
            ++sequence
        }
        log("epoch=$currentEpoch seq=$scanSequence request=$request stage=scan-started reason=$reason nowMs=$startedAt")
        val snapshot = mutableMapOf<String, Any?>(
            "type" to "snapshot", "epoch" to currentEpoch,
            "sequence" to scanSequence, "stage" to "raw",
            "request" to request, "scheduledAtMs" to scheduledAt,
            "dueAtMs" to dueAt, "startedAtMs" to startedAt,
        )
        val raw = try {
            enumerate().toMap()
        } catch (e: Exception) {
            // A failed observation has NO device roster. It is not an empty bus.
            snapshot["status"] = "error"
            snapshot["scanError"] = "${e.javaClass.simpleName}: ${e.message}"
            snapshot["rawCompletedAtMs"] = nowMs()
            log("epoch=$currentEpoch seq=$scanSequence stage=raw-completed status=error nowMs=${nowMs()} error=${snapshot["scanError"]}")
            publishRaw(currentEpoch, snapshot, reply)
            return
        }
        // First evidence, before ANY access to a device object or driver.
        snapshot["status"] = "ok"
        snapshot["rawCompletedAtMs"] = nowMs()
        log("epoch=$currentEpoch seq=$scanSequence stage=raw-completed status=ok count=${raw.size} roster=${raw.keys} nowMs=${nowMs()}")
        snapshot["devices"] = raw.keys.map {
            mapOf("deviceId" to it, "probeStatus" to "pending")
        }
        if (!publishRaw(currentEpoch, snapshot, reply)) return
        // Explicit raw API requests never call the prober. Foreground scans
        // enrich separately, after the raw event has already been delivered.
        if (reply == null && raw.isNotEmpty()) {
            enqueueEnrichment(Enrichment(currentEpoch, scanSequence, raw, snapshot.toMap()))
        }
    }

    private fun publishRaw(
        currentEpoch: Long,
        snapshot: Map<String, Any?>,
        reply: ((Map<String, Any?>) -> Unit)?,
    ): Boolean = synchronized(lock) {
        reply?.invoke(snapshot)
        if (disposed || epoch != currentEpoch) {
            log("epoch=$currentEpoch stage=raw-discarded reason=old-epoch nowMs=${nowMs()}")
            return@synchronized false
        }
        lastRaw = snapshot.toMap()
        emit(snapshot.toMap())
        true
    }

    private fun enqueueEnrichment(work: Enrichment<T>) = synchronized(lock) {
        if (disposed || work.epoch != epoch) return@synchronized
        pendingEnrichment = work
        if (!enrichmentRunning) {
            enrichmentRunning = true
            enrichmentExecutor.execute { drainEnrichment() }
        }
    }

    private fun drainEnrichment() {
        while (true) {
            val work = synchronized(lock) {
                val next = pendingEnrichment
                pendingEnrichment = null
                if (next == null) enrichmentRunning = false
                next
            } ?: return
            val devices = work.raw.map { (id, device) ->
                try {
                    enrich(id, device) + mapOf("deviceId" to id)
                } catch (e: Exception) {
                    // Last-resort containment: even a broken enricher must not
                    // drop this device or the rest of the roster.
                    mapOf("deviceId" to id, "probeStatus" to "error",
                        "probeError" to "${e.javaClass.simpleName}: ${e.message}")
                }
            }
            log("epoch=${work.epoch} seq=${work.sequence} stage=enrichment-completed nowMs=${nowMs()} devices=$devices")
            synchronized(lock) {
                if (!disposed && work.epoch == epoch && work.sequence == sequence) {
                    emit(work.snapshot + mapOf("stage" to "enriched",
                        "enrichedAtMs" to nowMs(), "devices" to devices))
                } else {
                    log("epoch=${work.epoch} seq=${work.sequence} stage=enrichment-discarded reason=newer-observation nowMs=${nowMs()}")
                }
            }
        }
    }
}
