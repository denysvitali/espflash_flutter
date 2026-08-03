package com.example.espflash_flutter.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Platform-channel names. Must match lib/usb/channels.dart byte for byte.
 */
object UsbChannels {
    const val METHODS = "espflash_flutter/usb"
    const val EVENTS = "espflash_flutter/usb/events"
    const val DATA = "espflash_flutter/usb/data"
}

/**
 * Error carrying a stable code that the Dart side maps to typed errors.
 *
 * Codes: notFound, noDriver, openFailed, notOpen, writeFailed, badArgs.
 */
class UsbException(val code: String, message: String) : RuntimeException(message)

/**
 * Extracts EXTRA_DEVICE from a USB broadcast, API-level safe.
 */
@Suppress("DEPRECATION")
fun Intent.usbDeviceExtra(): UsbDevice? {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        return getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
    }
    return getParcelableExtra(UsbManager.EXTRA_DEVICE)
}

/**
 * Wraps mik3y/usb-serial-for-android behind the espflash_flutter platform
 * channels. Owns device enumeration, the permission dialog flow, the open
 * serial port and the attach/detach/permission broadcast receivers.
 */
class UsbSerialManager(private val context: Context) {

    companion object {
        const val ACTION_USB_PERMISSION =
            "com.example.espflash_flutter.USB_PERMISSION"
        private const val DEFAULT_BAUD_RATE = 115200
        private const val WRITE_TIMEOUT_MS = 2000
    }

    private val usbManager: UsbManager =
        context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val prober: UsbSerialProber = UsbSerialProber.getDefaultProber()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val writeExecutor: ExecutorService =
        Executors.newSingleThreadExecutor()

    private val portLock = Any()
    private var port: UsbSerialPort? = null
    private var ioManager: SerialInputOutputManager? = null
    private var openDeviceName: String? = null

    private var eventsSink: EventChannel.EventSink? = null
    private var dataSink: EventChannel.EventSink? = null

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            val device = intent.usbDeviceExtra() ?: return
            val granted = intent.getBooleanExtra(
                UsbManager.EXTRA_PERMISSION_GRANTED, false)
            val type = if (granted) "permissionGranted" else "permissionDenied"
            emitEvent(type, device)
        }
    }

    private val attachReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            val device = intent.usbDeviceExtra() ?: return
            notifyAttached(device)
        }
    }

    private val detachReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            val device = intent.usbDeviceExtra() ?: return
            emitEvent("detached", device)
            if (device.deviceName == openDeviceName) {
                close()
            }
        }
    }

    private val ioListener = object : SerialInputOutputManager.Listener {
        override fun onNewData(data: ByteArray) {
            // onNewData runs on the reader thread; EventChannel sinks may
            // only be touched on the platform (main) thread.
            mainHandler.post { dataSink?.success(data) }
        }

        override fun onRunError(e: Exception) {
            // The port died under us (unplug, USB reset). Clean up; the
            // detach receiver tells Dart what happened.
            mainHandler.post { synchronized(portLock) { closeLocked() } }
        }
    }

    init {
        registerReceiver(permissionReceiver, ACTION_USB_PERMISSION)
        registerReceiver(attachReceiver, UsbManager.ACTION_USB_DEVICE_ATTACHED)
        registerReceiver(detachReceiver, UsbManager.ACTION_USB_DEVICE_DETACHED)
    }

    fun attachEventsChannel(channel: EventChannel) {
        channel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(
                arguments: Any?,
                events: EventChannel.EventSink?,
            ) {
                eventsSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventsSink = null
            }
        })
    }

    fun attachDataChannel(channel: EventChannel) {
        channel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(
                arguments: Any?,
                events: EventChannel.EventSink?,
            ) {
                dataSink = events
            }

            override fun onCancel(arguments: Any?) {
                dataSink = null
            }
        })
    }

    /** All attached devices with a known serial driver. */
    fun listDevices(): List<Map<String, Any>> =
        prober.findAllDrivers(usbManager).map { deviceToMap(it.device) }

    fun hasPermission(deviceId: String): Boolean {
        val device = findDevice(deviceId) ?: return false
        return usbManager.hasPermission(device)
    }

    /**
     * Shows the system permission dialog. The outcome arrives later as a
     * permissionGranted/permissionDenied event on the events channel.
     */
    fun requestPermission(deviceId: String) {
        val device = findDevice(deviceId)
            ?: throw UsbException("notFound", "USB device $deviceId not attached")
        if (usbManager.hasPermission(device)) {
            emitEvent("permissionGranted", device)
            return
        }
        // FLAG_MUTABLE is required: UsbService fills EXTRA_PERMISSION_GRANTED
        // into the PendingIntent's intent, which immutable intents drop.
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        usbManager.requestPermission(device, pendingIntent)
    }

    /**
     * Opens the port at 115200 8N1 and raises DTR/RTS immediately.
     *
     * mik3y opens the control lines low; the ESP32-C3 USB-Serial-JTAG
     * peripheral ignores its OUT endpoint while DTR is low, so every write
     * would time out without this.
     */
    fun open(deviceId: String) {
        val device = findDevice(deviceId)
            ?: throw UsbException("notFound", "USB device $deviceId not attached")
        val driver = prober.probeDevice(device)
            ?: throw UsbException(
                "noDriver",
                "No serial driver for ${device.vendorId}:${device.productId}",
            )
        val connection: UsbDeviceConnection = usbManager.openDevice(device)
            ?: throw UsbException(
                "openFailed",
                "openDevice failed (permission not granted?)",
            )
        synchronized(portLock) {
            closeLocked()
            try {
                val serialPort = driver.ports.first()
                serialPort.open(connection)
                serialPort.setParameters(
                    DEFAULT_BAUD_RATE,
                    UsbSerialPort.DATABITS_8,
                    UsbSerialPort.STOPBITS_1,
                    UsbSerialPort.PARITY_NONE,
                )
                serialPort.setDTR(true)
                serialPort.setRTS(true)
                val manager = SerialInputOutputManager(serialPort, ioListener)
                manager.start()
                port = serialPort
                ioManager = manager
                openDeviceName = device.deviceName
            } catch (e: UsbException) {
                runCatching { connection.close() }
                throw e
            } catch (e: Exception) {
                runCatching { connection.close() }
                throw UsbException("openFailed", e.message ?: "open failed")
            }
        }
    }

    /** Writes one SLIP frame. The result is answered asynchronously. */
    fun write(data: ByteArray, result: MethodChannel.Result) {
        val serialPort = port
        if (serialPort == null || !serialPort.isOpen) {
            throw UsbException("notOpen", "No serial port is open")
        }
        writeExecutor.execute {
            try {
                serialPort.write(data, WRITE_TIMEOUT_MS)
                mainHandler.post { result.success(null) }
            } catch (e: IOException) {
                mainHandler.post {
                    result.error("writeFailed", e.message, null)
                }
            }
        }
    }

    fun setBaud(baud: Int) {
        requirePort().setParameters(
            baud,
            UsbSerialPort.DATABITS_8,
            UsbSerialPort.STOPBITS_1,
            UsbSerialPort.PARITY_NONE,
        )
    }

    fun setDtr(value: Boolean) {
        requirePort().setDTR(value)
    }

    fun setRts(value: Boolean) {
        requirePort().setRTS(value)
    }

    fun close() {
        synchronized(portLock) { closeLocked() }
    }

    /** Unregisters receivers and stops the write executor. */
    fun dispose() {
        close()
        writeExecutor.shutdownNow()
        context.unregisterReceiver(permissionReceiver)
        context.unregisterReceiver(attachReceiver)
        context.unregisterReceiver(detachReceiver)
    }

    /** Emits an attached event; used for USB_DEVICE_ATTACHED intents. */
    fun notifyAttached(device: UsbDevice) {
        emitEvent("attached", device)
    }

    private fun requirePort(): UsbSerialPort =
        port?.takeIf { it.isOpen }
            ?: throw UsbException("notOpen", "No serial port is open")

    private fun closeLocked() {
        ioManager?.stop()
        ioManager = null
        try {
            port?.close()
        } catch (_: Exception) {
            // Closing a half-dead port must never throw into callers.
        }
        port = null
        openDeviceName = null
    }

    private fun findDevice(deviceId: String): UsbDevice? =
        usbManager.deviceList.values.firstOrNull { it.deviceName == deviceId }

    private fun deviceToMap(device: UsbDevice): Map<String, Any> = mapOf(
        "deviceId" to device.deviceName,
        "vendorId" to device.vendorId,
        "productId" to device.productId,
        "label" to deviceLabel(device),
    )

    private fun deviceLabel(device: UsbDevice): String = try {
        device.productName ?: String.format(
            "USB serial %04x:%04x", device.vendorId, device.productId)
    } catch (_: Exception) {
        "USB serial device"
    }

    private fun emitEvent(type: String, device: UsbDevice) {
        val event = mapOf(
            "type" to type,
            "deviceId" to device.deviceName,
            "vendorId" to device.vendorId,
            "productId" to device.productId,
        )
        mainHandler.post { eventsSink?.success(event) }
    }

    private fun registerReceiver(receiver: BroadcastReceiver, action: String) {
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Both the permission broadcast (sent via our own PendingIntent)
            // and the protected attach/detach broadcasts reach a
            // not-exported receiver.
            context.registerReceiver(
                receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
    }
}
