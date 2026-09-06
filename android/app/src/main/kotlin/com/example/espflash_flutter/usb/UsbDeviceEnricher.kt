package com.example.espflash_flutter.usb

/** Optional fields and driver errors never remove a raw attachment. */
class UsbDeviceEnricher<T>(
    private val fields: Map<String, (T) -> Any?>,
    private val probe: (T) -> Boolean,
) {
    fun enrich(id: String, device: T): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>("deviceId" to id)
        val errors = mutableMapOf<String, String>()
        for ((name, read) in fields) {
            try {
                result[name] = read(device)
            } catch (e: Exception) {
                result[name] = null
                errors[name] = "${e.javaClass.simpleName}: ${e.message}"
            }
        }
        result["fieldErrors"] = errors
        try {
            val supported = probe(device)
            result["hasSerialDriver"] = supported
            result["probeStatus"] = if (supported) "supported" else "unsupported"
        } catch (e: Exception) {
            result["hasSerialDriver"] = null
            result["probeStatus"] = "error"
            result["probeError"] = "${e.javaClass.simpleName}: ${e.message}"
        }
        return result
    }
}
