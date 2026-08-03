/// Fake transports shared by the ESP protocol tests.
///
/// [FakeTransport] records every write and DTR/RTS transition and
/// plays back scripted incoming chunks. [FakeRomTransport] layers a
/// scripted ESP32-C3 ROM on top: it decodes the SLIP frames we send,
/// records them, and replies like the ROM would.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:espflash_flutter/esp/protocol.dart';
import 'package:espflash_flutter/esp/slip.dart';
import 'package:espflash_flutter/esp/transport.dart';

/// A line control event (`dtr`/`rts`) or a sleep recorded by tests.
typedef LineEvent = (String line, bool value);

final class FakeTransport implements EspTransport {
  FakeTransport({this.vendorId = 0x303A, this.productId = 0x1001});

  /// Raw SLIP frames written by the code under test, in order.
  final List<Uint8List> writes = <Uint8List>[];

  /// DTR/RTS transitions in order.
  final List<LineEvent> lineEvents = <LineEvent>[];

  /// Baud rates requested via [setBaud].
  final List<int> baudRates = <int>[];

  bool closed = false;

  /// Called after each recorded write; lets scripted ROMs answer.
  void Function(Uint8List frame)? onWrite;

  @override
  final int? vendorId;

  @override
  final int? productId;

  final StreamController<List<int>> incoming =
      StreamController<List<int>>.broadcast(sync: true);

  @override
  Stream<List<int>> get chunks => incoming.stream;

  /// Simulate the device sending [bytes] (raw, may be partial SLIP).
  void feed(List<int> bytes) {
    incoming.add(bytes);
  }

  @override
  Future<void> write(List<int> data) async {
    final frame = Uint8List.fromList(data);
    writes.add(frame);
    onWrite?.call(frame);
  }

  @override
  Future<void> setBaud(int baud) async {
    baudRates.add(baud);
  }

  @override
  Future<void> setDtr(bool value) async {
    lineEvents.add(('dtr', value));
  }

  @override
  Future<void> setRts(bool value) async {
    lineEvents.add(('rts', value));
  }

  @override
  bool get isUsbJtag => vendorId == 0x303A && productId == 0x1001;

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }
}

/// One decoded request the host sent to the fake ROM.
final class RomRequest {
  RomRequest({
    required this.opcode,
    required this.checksum,
    required this.data,
  });

  final int opcode;
  final int checksum;
  final Uint8List data;

  /// Request payload read as little-endian u32 words.
  List<int> get words {
    return [
      for (var i = 0; i + 4 <= data.length; i += 4) readU32le(data, i),
    ];
  }
}

/// A scripted ESP32-C3 ROM bootloader behind a [FakeTransport].
final class FakeRomTransport extends FakeTransport {
  FakeRomTransport({super.vendorId, super.productId}) {
    onWrite = _handleFrame;
  }

  /// Every decoded request, in order.
  final List<RomRequest> requests = <RomRequest>[];

  final SlipStream _decoder = SlipStream();

  /// Value answered for READ_REG, keyed by register address.
  final Map<int, int> registers = <int, int>{};

  /// Value in the SYNC response header (ROM answers non-zero).
  int syncValue = 0x0BAD0001;

  /// GET_SECURITY_INFO payload fields.
  int securityFlags = 0;
  int securityCryptCnt = 0;
  int securityChipId = 5;
  int securityApiVersion = 0;

  /// Hex string answered by SPI_FLASH_MD5 (32 chars).
  String? md5Hex;

  /// Per-region MD5 answer; takes precedence over [md5Hex].
  String Function(int address, int size)? md5Provider;

  /// The first N FLASH_DATA requests answer with this ROM error
  /// reason byte (status byte set to 1).
  int flashDataFailures = 0;
  int flashDataFailuresSeen = 0;

  /// Opcodes that never get a response (for timeout tests).
  final Set<int> silentOpcodes = <int>{};

  /// Opcodes answered with a ROM error `[1, code, 0, 0]`.
  final Map<int, int> romErrorFor = <int, int>{};

  List<RomRequest> requestsFor(int opcode) =>
      requests.where((request) => request.opcode == opcode).toList();

  void _handleFrame(Uint8List frame) {
    for (final packet in _decoder.addBytes(frame)) {
      _handleRequest(packet);
    }
  }

  void _handleRequest(Uint8List packet) {
    if (packet.length < EspRequest.headerSize || packet[0] != 0x00) {
      return;
    }
    final request = RomRequest(
      opcode: packet[1] & 0xFF,
      checksum: readU32le(packet, 4),
      data: Uint8List.fromList(packet.sublist(EspRequest.headerSize)),
    );
    requests.add(request);
    if (silentOpcodes.contains(request.opcode)) {
      return;
    }
    final error = romErrorFor[request.opcode];
    if (error != null) {
      respond(request.opcode, data: [1, error, 0, 0]);
      return;
    }
    switch (request.opcode) {
      case EspCommand.sync:
        respond(request.opcode, value: syncValue);
      case EspCommand.readReg:
        respond(
          request.opcode,
          value: registers[readU32le(request.data)] ?? 0,
        );
      case EspCommand.spiFlashMd5:
        final provider = md5Provider;
        final hex = provider != null
            ? provider(
                readU32le(request.data),
                readU32le(request.data, 4),
              )
            : (md5Hex ?? '0' * 32);
        respond(request.opcode, data: [
          ...hex.codeUnits,
          0,
          0,
          0,
          0,
        ]);
      case EspCommand.flashData:
        if (flashDataFailuresSeen < flashDataFailures) {
          flashDataFailuresSeen++;
          respond(request.opcode, data: [1, 0x08, 0, 0]);
          return;
        }
        respond(request.opcode);
      case EspCommand.getSecurityInfo:
        respond(request.opcode, data: securityInfoPayload());
      default:
        respond(request.opcode);
    }
  }

  /// Build the GET_SECURITY_INFO payload (plus status bytes):
  /// `[u32 flags][u8 crypt_cnt][7B key purposes][u32 chip_id]
  /// [u32 api][4B status]`.
  List<int> securityInfoPayload() {
    return [
      ...u32le(securityFlags),
      securityCryptCnt & 0xFF,
      0, 0, 0, 0, 0, 0, 0, // key purposes
      ...u32le(securityChipId),
      ...u32le(securityApiVersion),
      0, 0, 0, 0, // ROM status (ok)
    ];
  }

  /// Feed a ROM success response for [opcode].
  void respond(int opcode, {int value = 0, List<int>? data}) {
    final payload = data ?? const [0, 0, 0, 0];
    final packet = (BytesBuilder(copy: false)
          ..addByte(0x01)
          ..addByte(opcode & 0xFF)
          ..add(u16le(payload.length))
          ..add(u32le(value))
          ..add(payload))
        .toBytes();
    feed(SlipCodec.encode(packet));
  }
}
