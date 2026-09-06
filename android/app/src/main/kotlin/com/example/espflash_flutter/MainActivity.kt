package com.example.espflash_flutter

import android.content.Intent
import android.database.Cursor
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import com.example.espflash_flutter.usb.UsbChannels
import com.example.espflash_flutter.usb.UsbException
import com.example.espflash_flutter.usb.UsbJtagManager
import com.example.espflash_flutter.usb.UsbSerialManager
import com.example.espflash_flutter.usb.usbDeviceExtra
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private companion object {
        const val FIRMWARE_SOURCES_CHANNEL =
            "com.example.espflash_flutter/firmware_sources"
    }

    private var usb: UsbSerialManager? = null
    private var jtag: UsbJtagManager? = null
    private var firmwareSourcesChannel: MethodChannel? = null
    private var pendingFirmware: PendingFirmware? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val manager = UsbSerialManager(applicationContext)
        usb = manager
        val jtagManager = UsbJtagManager(applicationContext)
        jtag = jtagManager

        val methodChannel = MethodChannel(
            flutterEngine.dartExecutor, UsbChannels.METHODS)
        val eventsChannel = EventChannel(
            flutterEngine.dartExecutor, UsbChannels.EVENTS)
        val dataChannel = EventChannel(
            flutterEngine.dartExecutor, UsbChannels.DATA)
        val sourceChannel = MethodChannel(
            flutterEngine.dartExecutor, FIRMWARE_SOURCES_CHANNEL)
        firmwareSourcesChannel = sourceChannel

        manager.attachEventsChannel(eventsChannel)
        manager.attachDataChannel(dataChannel)

        sourceChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingFile" -> takePendingFirmware(result)
                else -> result.notImplemented()
            }
        }

        methodChannel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "listDevices" -> result.success(manager.listDevices())
                    "listRawDevices" -> result.success(manager.listRawDevices())
                    "reconcileUsb" -> {
                        manager.reconcileUsb("manual-refresh")
                        result.success(null)
                    }
                    "hasPermission" -> result.success(
                        manager.hasPermission(call.deviceId()),
                    )
                    "requestPermission" -> {
                        manager.requestPermission(call.deviceId())
                        result.success(null)
                    }
                    "open" -> {
                        manager.open(call.deviceId())
                        result.success(null)
                    }
                    "close" -> {
                        manager.close()
                        result.success(null)
                    }
                    "write" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                            ?: throw UsbException(
                                "badArgs", "write needs a bytes argument")
                        // Result is answered by the manager once the write
                        // thread is done; do not answer it here.
                        manager.write(bytes, result)
                    }
                    "setBaud" -> {
                        val baud = call.argument<Number>("baud")?.toInt()
                            ?: throw UsbException(
                                "badArgs", "setBaud needs a baud argument")
                        manager.setBaud(baud)
                        result.success(null)
                    }
                    "setDtr" -> {
                        manager.setDtr(call.boolArg("value"))
                        result.success(null)
                    }
                    "setRts" -> {
                        manager.setRts(call.boolArg("value"))
                        result.success(null)
                    }
                    "jtagOpen" -> result.success(
                        jtagManager.open(call.deviceId()),
                    )
                    "jtagWrite" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                            ?: throw UsbException(
                                "badArgs", "jtagWrite needs a bytes argument")
                        // Answered asynchronously by the JTAG executor.
                        jtagManager.write(bytes, result)
                    }
                    "jtagRead" -> {
                        val maxLen = call.argument<Number>("maxLen")?.toInt()
                            ?: throw UsbException(
                                "badArgs", "jtagRead needs a maxLen argument")
                        val timeoutMs =
                            call.argument<Number>("timeoutMs")?.toInt() ?: 500
                        jtagManager.read(maxLen, timeoutMs, result)
                    }
                    "jtagClose" -> {
                        jtagManager.close()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: UsbException) {
                result.error(e.code, e.message, null)
            } catch (e: Exception) {
                result.error("usbError", e.message ?: e.toString(), null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleUsbIntent(intent)
        queueFirmwareIntent(intent, notifyFlutter = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleUsbIntent(intent)
        queueFirmwareIntent(intent, notifyFlutter = true)
    }

    override fun onResume() {
        super.onResume()
        usb?.reconcileUsb("activity-resume")
    }

    override fun onDestroy() {
        usb?.dispose()
        usb = null
        jtag?.dispose()
        jtag = null
        firmwareSourcesChannel?.setMethodCallHandler(null)
        firmwareSourcesChannel = null
        super.onDestroy()
    }

    /**
     * The activity is relaunched (singleTop) for USB_DEVICE_ATTACHED when
     * the device matches res/xml/device_filter; mirror that as an event so
     * Dart sees cold-start attaches even before its EventChannel listener
     * raced the broadcast receiver.
     */
    private fun handleUsbIntent(launchIntent: Intent?) {
        if (launchIntent?.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) {
            return
        }
        val device: UsbDevice = launchIntent.usbDeviceExtra() ?: return
        usb?.notifyAttached(device)
    }

    /**
     * Keep the URI rather than eagerly reading it. A firmware bundle can be
     * tens of megabytes, and Flutter may not be listening yet on a cold
     * start. Dart calls [takePendingFirmware] once its controller is ready.
     */
    private fun queueFirmwareIntent(
        launchIntent: Intent?,
        notifyFlutter: Boolean,
    ) {
        val uri = when (launchIntent?.action) {
            Intent.ACTION_VIEW -> launchIntent.data
            Intent.ACTION_SEND -> launchIntent.sharedStream()
            else -> null
        } ?: return

        pendingFirmware = PendingFirmware(
            uri = uri,
            name = displayName(uri),
        )
        if (notifyFlutter) {
            firmwareSourcesChannel?.invokeMethod("fileAvailable", null)
        }
    }

    private fun takePendingFirmware(result: MethodChannel.Result) {
        val pending = pendingFirmware
        if (pending == null) {
            result.success(null)
            return
        }
        try {
            val bytes = contentResolver.openInputStream(pending.uri)?.use {
                it.readBytes()
            } ?: throw IllegalArgumentException(
                "The selected firmware file could not be opened",
            )
            // Clear only after a successful read, so a transient provider
            // error does not silently discard the user's selection.
            pendingFirmware = null
            result.success(
                mapOf(
                    "name" to pending.name,
                    "bytes" to bytes,
                ),
            )
        } catch (error: Exception) {
            result.error(
                "firmwareReadFailed",
                error.message ?: "The selected firmware file could not be read",
                null,
            )
        }
    }

    private fun displayName(uri: Uri): String {
        if (uri.scheme == "content") {
            var cursor: Cursor? = null
            try {
                cursor = contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME),
                    null,
                    null,
                    null,
                )
                if (cursor != null && cursor.moveToFirst()) {
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0) {
                        cursor.getString(column)?.takeIf { it.isNotBlank() }
                            ?.let { return it }
                    }
                }
            } catch (_: Exception) {
                // Fall back to the URI path below.
            } finally {
                cursor?.close()
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')
            ?.takeIf { it.isNotBlank() }
            ?: "firmware.bin"
    }

    private data class PendingFirmware(
        val uri: Uri,
        val name: String,
    )

    @Suppress("DEPRECATION")
    private fun Intent.sharedStream(): Uri? =
        getParcelableExtra(Intent.EXTRA_STREAM)

    private fun MethodCall.deviceId(): String =
        argument<String>("deviceId")
            ?: throw UsbException("badArgs", "deviceId argument missing")

    private fun MethodCall.boolArg(name: String): Boolean =
        argument<Boolean>(name)
            ?: throw UsbException("badArgs", "$name argument missing")
}
