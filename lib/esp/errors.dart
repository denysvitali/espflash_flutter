/// Typed errors thrown by the ESP flashing stack.
library;

/// Base class for all espflash_flutter errors.
sealed class EspError implements Exception {
  const EspError(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The ROM bootloader did not answer SYNC after all attempts.
final class EspSyncError extends EspError {
  const EspSyncError(super.message);
}

/// A command timed out waiting for the ROM response.
final class EspTimeoutError extends EspError {
  const EspTimeoutError(super.message);
}

/// The ROM reported a command failure (status bytes in the response).
final class EspRomError extends EspError {
  const EspRomError(this.code, String message) : super(message);

  /// Raw ROM error code (first of the two trailing status words).
  final int code;
}

/// Connected chip is not an ESP32-C3 (or not an ESP at all).
final class EspUnsupportedChipError extends EspError {
  const EspUnsupportedChipError(super.message);
}

/// The USB device went away mid-operation (unplugged / re-enumeration).
final class EspDeviceLostError extends EspError {
  const EspDeviceLostError(super.message);
}

/// Flash verification (MD5) mismatch.
final class EspVerifyError extends EspError {
  const EspVerifyError(super.message);
}

/// The user cancelled the operation.
final class EspCancelledError extends EspError {
  const EspCancelledError() : super('Operation cancelled');
}
