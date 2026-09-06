package com.example.espflash_flutter.usb

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Distinct queues are a liveness requirement, not just an optimization. */
class UsbObserverWorkers {
    val discovery = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "EspFlashUsb-discovery")
    }
    val enrichment = Executors.newSingleThreadExecutor { task ->
        Thread(task, "EspFlashUsb-enrichment")
    }
    val operations = Executors.newSingleThreadExecutor { task ->
        Thread(task, "EspFlashUsb-operations")
    }

    fun schedule(delay: Long, task: () -> Unit): UsbScanTimer {
        val future = discovery.schedule({ task() }, delay, TimeUnit.MILLISECONDS)
        return UsbScanTimer { future.cancel(false) }
    }
}
