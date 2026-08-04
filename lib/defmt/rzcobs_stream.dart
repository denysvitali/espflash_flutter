/// Stream decoder for bare rzcobs-framed defmt, as emitted by defmt-rtt:
/// frames are 0x00-delimited, no esp-println `FF 00` prefix. Mirrors
/// defmt-decoder's `stream/rzcobs.rs`: leading zeros are trimmed, a
/// decode failure drops the frame and keeps going.
library;

import 'dart:typed_data';

import 'decoder.dart';
import 'log_decoder.dart';
import 'rzcobs.dart';
import 'table.dart';

/// Feeds RTT byte chunks → decoded defmt lines.
final class DefmtStreamDecoder {
  DefmtStreamDecoder(DefmtTable table) : _decoder = DefmtFrameDecoder(table);

  final DefmtFrameDecoder _decoder;
  final List<int> _buffer = <int>[];

  /// Cap the buffer so a lost 0x00 delimiter can't wedge us forever.
  static const int maxFrameBytes = 8192;

  int droppedFrames = 0;
  String? lastError;

  List<LogLine> feed(List<int> bytes) {
    _buffer.addAll(bytes);
    final out = <LogLine>[];
    while (true) {
      // Trim leading zeros (frame separators).
      var firstNonZero = 0;
      while (firstNonZero < _buffer.length && _buffer[firstNonZero] == 0) {
        firstNonZero++;
      }
      if (firstNonZero > 0) {
        _buffer.removeRange(0, firstNonZero);
      }
      final end = _buffer.indexOf(0);
      if (end == -1) {
        if (_buffer.length > maxFrameBytes) {
          _buffer.clear();
          droppedFrames++;
        }
        break;
      }
      final frame = Uint8List.fromList(_buffer.sublist(0, end));
      _buffer.removeRange(0, end + 1);
      try {
        out.add(DefmtLine(_decoder.decode(rzcobsDecode(frame))));
      } on Object catch (error) {
        droppedFrames++;
        lastError = '$error';
      }
    }
    return out;
  }
}
