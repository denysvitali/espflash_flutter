/// Command layer on top of an [EspTransport]: sync handshake,
/// request/response matching, and register access.
///
/// Mirrors esptool `_connect_attempt` / `command` and esptool-js
/// `connection`: 5 sync tries per connect attempt, 7 attempts,
/// 100 ms read timeout during sync, mismatched-opcode responses are
/// skipped, and the ROM's up-to-8 duplicate SYNC replies are
/// drained.
library;

import 'dart:async';
import 'dart:typed_data';

import 'errors.dart';
import 'protocol.dart';
import 'reset.dart';
import 'slip.dart';
import 'transport.dart';

/// Default number of SYNC tries inside one connect attempt.
const int defaultSyncTries = 5;

/// Default number of connect attempts (reset + sync tries each).
const int defaultConnectAttempts = 7;

/// SYNC payload: `07 07 12 20` followed by 32 x `0x55`.
final Uint8List syncPayload = Uint8List.fromList(
  [0x07, 0x07, 0x12, 0x20, ...List<int>.filled(32, 0x55)],
);

final class EspConnection {
  EspConnection(
    this.transport, {
    this.syncTries = defaultSyncTries,
    this.connectAttempts = defaultConnectAttempts,
    this.syncTimeout = const Duration(milliseconds: 100),
    this.defaultTimeout = const Duration(seconds: 3),
  }) {
    _subscription = transport.chunks.listen(
      _onChunk,
      onError: (Object _) => _markLost(),
      onDone: _markLost,
    );
  }

  final EspTransport transport;

  /// SYNC tries per connect attempt (esptool: 5).
  final int syncTries;

  /// Connect attempts, each preceded by the reset strategy
  /// (esptool: 7).
  final int connectAttempts;

  /// Read timeout used during the sync handshake.
  final Duration syncTimeout;

  /// Read timeout for ordinary commands.
  final Duration defaultTimeout;

  /// True when the sync handshake was answered with value 0, which
  /// means a flasher stub (not the ROM) is already running.
  bool syncStubDetected = false;

  final SlipStream _slip = SlipStream();
  final List<Uint8List> _packets = <Uint8List>[];
  Completer<void>? _waiter;
  StreamSubscription<List<int>>? _subscription;
  bool _lost = false;

  /// Run the reset strategy + sync loop until the ROM answers.
  ///
  /// [resetStrategy] runs before the sync tries of every attempt.
  /// Throws [EspSyncError] when all attempts fail.
  Future<void> connect({ResetStrategy? resetStrategy}) async {
    Object? lastError;
    for (var attempt = 0; attempt < connectAttempts; attempt++) {
      if (resetStrategy != null) {
        await resetStrategy.reset(transport);
      }
      for (var index = 0; index < syncTries; index++) {
        _slip.reset();
        _packets.clear();
        try {
          await sync();
          return;
        } on EspError catch (error) {
          lastError = error;
        }
      }
    }
    throw EspSyncError(
      'Failed to sync with the ROM bootloader after '
      '${connectAttempts * syncTries} tries'
      '${lastError == null ? '' : ': $lastError'}',
    );
  }

  /// Send one SYNC packet and drain the ROM's responses.
  ///
  /// The ROM answers a SYNC packet with up to 8 responses; the first
  /// one completes the handshake, the remaining 7 are drained so they
  /// do not confuse later commands.
  Future<EspResponse> sync() async {
    final response = await command(
      EspCommand.sync,
      data: syncPayload,
      timeout: syncTimeout,
      checkRomStatus: false,
      description: 'sync with the bootloader',
    );
    // ROM bootloaders answer with a non-zero value; the flasher stub
    // answers 0.
    syncStubDetected = response.value == 0;
    for (var index = 0; index < 7; index++) {
      final extra = await readResponse(
        EspCommand.sync,
        timeout: syncTimeout,
      );
      syncStubDetected = syncStubDetected && extra.value == 0;
    }
    return response;
  }

  /// Send a command frame and wait for the matching response.
  ///
  /// Responses for other opcodes are skipped (the ROM replays stale
  /// duplicates after some commands). When [checkRomStatus] is set,
  /// a failing ROM status word raises [EspRomError].
  Future<EspResponse> command(
    int opcode, {
    List<int> data = const <int>[],
    int checksum = 0,
    Duration? timeout,
    bool checkRomStatus = true,
    String? description,
  }) async {
    final frame = EspRequest(opcode, data, checksum).toFrame();
    await transport.write(frame);
    final response = await readResponse(
      opcode,
      timeout: timeout ?? defaultTimeout,
    );
    if (checkRomStatus) {
      response.throwIfRomError(
        description ??
            'run command 0x${opcode.toRadixString(16).padLeft(2, '0')}',
      );
    }
    return response;
  }

  /// Wait up to [timeout] for a response with [opcode], skipping
  /// packets for other opcodes. Throws [EspTimeoutError] when no
  /// matching response arrives.
  Future<EspResponse> readResponse(
    int opcode, {
    required Duration timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      while (_packets.isNotEmpty) {
        final packet = _packets.removeAt(0);
        final response = EspResponse.tryParse(packet);
        if (response == null) {
          continue;
        }
        if (response.opcode == opcode) {
          return response;
        }
        // Otherwise skip: stale duplicate or unrelated reply.
      }
      if (_lost) {
        throw EspDeviceLostError(
          'USB device went away while waiting for a response',
        );
      }
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw EspTimeoutError(
          'Timed out after ${timeout.inMilliseconds} ms waiting for '
          'response to command '
          '0x${opcode.toRadixString(16).padLeft(2, '0')}',
        );
      }
      final waiter = Completer<void>();
      _waiter = waiter;
      try {
        await waiter.future.timeout(remaining);
      } on TimeoutException {
        // Re-check the buffer and deadline.
      } finally {
        _waiter = null;
      }
    }
  }

  /// Read a memory-mapped register; the value arrives in the
  /// response header.
  Future<int> readReg(int address, {Duration? timeout}) async {
    final response = await command(
      EspCommand.readReg,
      data: u32le(address),
      timeout: timeout,
      description: 'read register '
          '0x${address.toRadixString(16).padLeft(8, '0')}',
    );
    return response.value;
  }

  /// Write [value] to a memory-mapped register, optionally masked
  /// and with a delay known to the ROM.
  Future<void> writeReg(
    int address,
    int value, {
    int mask = 0xFFFFFFFF,
    int delayUs = 0,
    Duration? timeout,
  }) async {
    final data = (BytesBuilder(copy: false)
          ..add(u32le(address))
          ..add(u32le(value))
          ..add(u32le(mask))
          ..add(u32le(delayUs)))
        .toBytes();
    await command(
      EspCommand.writeReg,
      data: data,
      timeout: timeout,
      description: 'write register '
          '0x${address.toRadixString(16).padLeft(8, '0')}',
    );
  }

  /// Stop listening to the transport. The transport itself is owned
  /// by the caller.
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  void _onChunk(List<int> chunk) {
    final List<Uint8List> decoded;
    try {
      decoded = _slip.addBytes(chunk);
    } on FormatException {
      // Serial noise (e.g. the ROM boot log) broke the framing;
      // drop the partial state and resynchronize on the next END.
      _slip.reset();
      return;
    }
    if (decoded.isEmpty) {
      return;
    }
    _packets.addAll(decoded);
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  void _markLost() {
    _lost = true;
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }
}
