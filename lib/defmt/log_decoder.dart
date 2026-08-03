/// High-level pipeline: serial bytes in → decoded log lines out.
///
/// Chains [FrameDelimiter] (esp-println `FF 00`/`00` framing) → rzcobs
/// decode → [DefmtFrameDecoder]. Non-defmt bytes surface as raw chunks.
library;

import 'dart:typed_data';

import 'decoder.dart';
import 'framing.dart';
import 'rzcobs.dart';
import 'table.dart';

/// One output line of the monitor pipeline.
sealed class LogLine {
  const LogLine();
}

/// A decoded defmt frame.
final class DefmtLine extends LogLine {
  const DefmtLine(this.frame);

  final DecodedFrame frame;
}

/// Raw serial bytes (ordinary `println!`-style output).
final class RawLine extends LogLine {
  const RawLine(this.bytes);

  final Uint8List bytes;
}

/// Feeds serial chunks through the whole defmt decode chain.
final class DefmtLogDecoder {
  DefmtLogDecoder(DefmtTable table)
    : _decoder = DefmtFrameDecoder(table);

  final DefmtFrameDecoder _decoder;
  final FrameDelimiter _delimiter = FrameDelimiter();

  /// Frames that failed rzcobs/defmt decoding (loss, noise, version skew).
  int droppedFrames = 0;

  /// Most recent decode error message, for diagnostics.
  String? lastError;

  List<LogLine> feed(List<int> bytes) {
    final out = <LogLine>[];
    for (final chunk in _delimiter.feed(bytes)) {
      switch (chunk) {
        case RawChunk(:final bytes):
          if (bytes.isNotEmpty) {
            out.add(RawLine(bytes));
          }
        case DefmtFrameChunk(:final bytes):
          final frame = _tryDecode(bytes);
          if (frame != null) {
            out.add(DefmtLine(frame));
          }
      }
    }
    return out;
  }

  DecodedFrame? _tryDecode(Uint8List rzcobsFrame) {
    try {
      return _decoder.decode(rzcobsDecode(rzcobsFrame));
    } on Object catch (error) {
      droppedFrames++;
      lastError = '$error';
      return null;
    }
  }
}
