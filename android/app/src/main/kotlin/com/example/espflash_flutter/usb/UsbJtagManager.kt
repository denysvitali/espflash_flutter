package com.example.espflash_flutter.usb

import android.content.Context
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Raw access to the ESP32-C3/S3 built-in USB JTAG function.
 *
 * The USB-Serial-JTAG peripheral is a composite device: CDC-ACM serial
 * (handled by [UsbSerialManager]) plus a vendor-specific JTAG interface
 * (class 0xFF, subclass 0xFF, protocol 0x01) with one bulk OUT and one
 * bulk IN endpoint. The wire format is the nibble-packed command stream
 * documented in probe-rs' espusbjtag driver; this class only moves bytes.
 */
class UsbJtagManager(private val context: Context) {

    companion object {
        private const val JTAG_INTERFACE_CLASS = 0xFF
        private const val JTAG_INTERFACE_SUBCLASS = 0xFF
        private const val JTAG_INTERFACE_PROTOCOL = 0x01

        /** Vendor-specific capabilities descriptor (built-in USB JTAG). */
        private const val CAPS_DESCRIPTOR_TYPE = 0x20
        private const val CAPS_DESCRIPTOR_INDEX = 0x00
        private const val USB_TIMEOUT_MS = 500
        private const val IN_EP_BUFFER_SIZE = 64
    }

    private val usbManager: UsbManager =
        context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private val lock = Any()
    private var connection: UsbDeviceConnection? = null
    private var jtagInterface: UsbInterface? = null
    private var epOut: UsbEndpoint? = null
    private var epIn: UsbEndpoint? = null

    /**
     * Claims the JTAG interface and returns its capabilities
     * (baseSpeedKhz, divMin, divMax).
     */
    fun open(deviceId: String): Map<String, Any> {
        val device = usbManager.deviceList.values
            .firstOrNull { it.deviceName == deviceId }
            ?: throw UsbException("notFound", "USB device $deviceId not attached")
        val conn = usbManager.openDevice(device)
            ?: throw UsbException(
                "openFailed", "openDevice failed (permission not granted?)")

        var iface: UsbInterface? = null
        var out: UsbEndpoint? = null
        var inp: UsbEndpoint? = null
        for (i in 0 until device.interfaceCount) {
            val candidate = device.getInterface(i)
            if (candidate.interfaceClass != JTAG_INTERFACE_CLASS ||
                candidate.interfaceSubclass != JTAG_INTERFACE_SUBCLASS ||
                candidate.interfaceProtocol != JTAG_INTERFACE_PROTOCOL
            ) {
                continue
            }
            for (e in 0 until candidate.endpointCount) {
                val ep = candidate.getEndpoint(e)
                if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                if (ep.direction == UsbConstants.USB_DIR_IN) inp = ep else out = ep
            }
            if (out != null && inp != null) {
                iface = candidate
                break
            }
        }
        if (iface == null || out == null || inp == null) {
            runCatching { conn.close() }
            throw UsbException("noJtag", "No JTAG interface on $deviceId")
        }
        if (!conn.claimInterface(iface, true)) {
            runCatching { conn.close() }
            throw UsbException("openFailed", "claimInterface failed")
        }

        synchronized(lock) {
            closeLocked()
            connection = conn
            jtagInterface = iface
            epOut = out
            epIn = inp
        }

        val caps = readCapabilities(conn)
        flushInput()
        return caps
    }

    /** GET_DESCRIPTOR (type 0x20, index 0): protocol version + speed caps. */
    private fun readCapabilities(conn: UsbDeviceConnection): Map<String, Any> {
        val buffer = ByteArray(255)
        val received = conn.controlTransfer(
            UsbConstants.USB_DIR_IN, // standard, device, device-to-host
            6, // GET_DESCRIPTOR
            CAPS_DESCRIPTOR_TYPE shl 8 or CAPS_DESCRIPTOR_INDEX,
            0,
            buffer,
            buffer.size,
            USB_TIMEOUT_MS,
        )
        if (received < 2) {
            throw UsbException("noJtag", "capabilities descriptor unreadable")
        }
        val version = buffer[0].toInt() and 0xFF
        if (version != 1) {
            throw UsbException(
                "noJtag", "unknown JTAG capabilities version $version")
        }
        var baseSpeedKhz = 1000
        var divMin = 1
        var divMax = 1
        val length = buffer[1].toInt() and 0xFF
        var p = 2
        while (p + 1 < length && p + 1 < received) {
            val capType = buffer[p].toInt() and 0xFF
            val capLength = buffer[p + 1].toInt() and 0xFF
            if (capType == 1 && capLength >= 8 && p + capLength <= received) {
                val rawSpeed = u16le(buffer, p + 2)
                baseSpeedKhz = rawSpeed * 10 / 2
                divMin = u16le(buffer, p + 4)
                divMax = u16le(buffer, p + 6)
            }
            if (capLength <= 0) break
            p += capLength
        }
        return mapOf(
            "baseSpeedKhz" to baseSpeedKhz,
            "divMin" to divMin,
            "divMax" to divMax,
        )
    }

    /** Drain stale capture data after attach (mirrors probe-rs init). */
    private fun flushInput() {
        val ep = epIn ?: return
        val conn = connection ?: return
        val scratch = ByteArray(IN_EP_BUFFER_SIZE)
        val deadline = System.currentTimeMillis() + 500
        while (System.currentTimeMillis() < deadline) {
            val n = conn.bulkTransfer(ep, scratch, scratch.size, 100)
            if (n <= 0) break
        }
    }

    /** bulk OUT; answers with the number of bytes accepted. */
    fun write(data: ByteArray, result: MethodChannel.Result) {
        executor.execute {
            try {
                val conn = connection
                    ?: throw UsbException("notOpen", "JTAG not open")
                val ep = epOut ?: throw UsbException("notOpen", "JTAG not open")
                val sent = conn.bulkTransfer(ep, data, data.size, USB_TIMEOUT_MS)
                if (sent != data.size) {
                    mainHandler.post {
                        result.error(
                            "writeFailed", "accepted $sent of ${data.size}", null)
                    }
                } else {
                    mainHandler.post { result.success(sent) }
                }
            } catch (e: UsbException) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("usbError", e.message ?: e.toString(), null)
                }
            }
        }
    }

    /** bulk IN; answers with the bytes read (empty on timeout). */
    fun read(maxLen: Int, timeoutMs: Int, result: MethodChannel.Result) {
        executor.execute {
            try {
                val conn = connection
                    ?: throw UsbException("notOpen", "JTAG not open")
                val ep = epIn ?: throw UsbException("notOpen", "JTAG not open")
                val buffer = ByteArray(minOf(maxLen, IN_EP_BUFFER_SIZE))
                val n = conn.bulkTransfer(ep, buffer, buffer.size, timeoutMs)
                val bytes = if (n > 0) buffer.copyOf(n) else ByteArray(0)
                mainHandler.post { result.success(bytes) }
            } catch (e: UsbException) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("usbError", e.message ?: e.toString(), null)
                }
            }
        }
    }

    fun close() {
        synchronized(lock) { closeLocked() }
    }

    fun dispose() {
        close()
        executor.shutdownNow()
    }

    private fun closeLocked() {
        val conn = connection
        val iface = jtagInterface
        if (conn != null && iface != null) {
            runCatching { conn.releaseInterface(iface) }
        }
        runCatching { conn?.close() }
        connection = null
        jtagInterface = null
        epOut = null
        epIn = null
    }

    private fun u16le(buffer: ByteArray, offset: Int): Int =
        (buffer[offset].toInt() and 0xFF) or
            ((buffer[offset + 1].toInt() and 0xFF) shl 8)
}
