package com.example.espflash_flutter

import android.content.Intent
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Bundle
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

    private var usb: UsbSerialManager? = null
    private var jtag: UsbJtagManager? = null

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

        manager.attachEventsChannel(eventsChannel)
        manager.attachDataChannel(dataChannel)

        methodChannel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "listDevices" -> result.success(manager.listDevices())
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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleUsbIntent(intent)
    }

    override fun onDestroy() {
        usb?.dispose()
        usb = null
        jtag?.dispose()
        jtag = null
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

    private fun MethodCall.deviceId(): String =
        argument<String>("deviceId")
            ?: throw UsbException("badArgs", "deviceId argument missing")

    private fun MethodCall.boolArg(name: String): Boolean =
        argument<Boolean>(name)
            ?: throw UsbException("badArgs", "$name argument missing")
}
