package com.example.espflash_flutter.usb

import org.junit.Assert.*
import org.junit.Test

class UsbDeviceEnricherTest {
    @Test fun `probe exceptions are distinct from unsupported devices`() {
        val enricher = UsbDeviceEnricher<String>(emptyMap()) { device ->
            if (device == "broken") throw IllegalArgumentException("bad descriptor")
            device == "supported"
        }
        assertEquals("unsupported", enricher.enrich("a", "unknown")["probeStatus"])
        val broken = enricher.enrich("b", "broken")
        assertEquals("b", broken["deviceId"])
        assertEquals("error", broken["probeStatus"])
        assertNull(broken["hasSerialDriver"])
        assertTrue((broken["probeError"] as String).contains("bad descriptor"))
        assertEquals("supported", enricher.enrich("c", "supported")["probeStatus"])
    }

    @Test fun `optional metadata failures preserve device and other fields`() {
        val enricher = UsbDeviceEnricher<String>(mapOf(
            "label" to { _: String -> throw SecurityException("permission required") },
            "hasPermission" to { _: String -> throw IllegalStateException("binder") },
            "vendorId" to { _: String -> 0x303a },
        )) { true }
        val device = enricher.enrich("board", "esp")
        assertEquals("board", device["deviceId"])
        assertEquals(0x303a, device["vendorId"])
        assertNull(device["label"])
        assertNull(device["hasPermission"])
        assertEquals("supported", device["probeStatus"])
        val errors = device["fieldErrors"] as Map<*, *>
        assertEquals(setOf("label", "hasPermission"), errors.keys)
    }
}
