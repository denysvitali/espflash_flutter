/// [EspTransport] implementation over the Android USB platform channels.
library;

import '../esp/transport.dart';
import 'usb_device.dart';
import 'usb_service.dart';

/// ESP transport backed by the Android USB host stack via [UsbService].
///
/// Construct one after [UsbService.open] succeeded; the Kotlin side then
/// pushes incoming serial chunks on the data EventChannel. `write` sends
/// already-SLIP-framed bytes over the method channel, so this layer is
/// deliberately dumb: all protocol logic lives above [EspTransport].
final class AndroidUsbTransport implements EspTransport {
  AndroidUsbTransport({required UsbService service, required UsbDevice device})
    : _service = service,
      _device = device;

  final UsbService _service;
  final UsbDevice _device;

  /// The device this transport is bound to.
  UsbDevice get device => _device;

  @override
  Stream<List<int>> get chunks => _service.data;

  @override
  int get vendorId => _device.vendorId;

  @override
  int get productId => _device.productId;

  @override
  bool get isUsbJtag => _device.isUsbJtag;

  @override
  Future<void> write(List<int> data) => _service.write(data);

  @override
  Future<void> setBaud(int baud) => _service.setBaud(baud);

  @override
  Future<void> setDtr(bool value) => _service.setDtr(value);

  @override
  Future<void> setRts(bool value) => _service.setRts(value);

  @override
  Future<void> close() => _service.close();
}
