/// SEGGER RTT reader over a memory interface (SBA in production).
///
/// The control block layout (32-bit targets):
/// ```text
/// offset  size  field
///  0      16    acID = "SEGGER RTT\0\0\0\0\0\0"
/// 16       4    MaxNumUpBuffers
/// 20       4    MaxNumDownBuffers
/// 24      24    per up-buffer descriptor:
///               sName(4) pBuffer(4) SizeOfBuffer(4) WrOff(4) RdOff(4)
///               Flags(4)
/// ```
///
/// defmt-rtt exposes one up channel named "defmt"; its defmt stream is
/// rzcobs-framed (0x00-delimited), exactly what the defmt decoder eats.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../defmt/elf.dart';

/// Minimal memory interface the RTT reader needs.
abstract interface class TargetMemory {
  Future<int> read32(int address);

  Future<Uint32List> readBlock(int address, int wordCount);

  Future<void> write32(int address, int value);
}

final class RttError implements Exception {
  const RttError(this.message);

  final String message;

  @override
  String toString() => 'RTT error: $message';
}

/// One up-channel (target → host) descriptor.
final class RttUpChannel {
  RttUpChannel({
    required this.namePointer,
    required this.bufferAddress,
    required this.bufferSize,
    required this.descriptorAddress,
    required this.writeOffset,
    required this.readOffset,
  });

  final int namePointer;
  final int bufferAddress;
  final int bufferSize;

  /// Address of this descriptor in target memory (for RdOff writes).
  final int descriptorAddress;
  int writeOffset;
  int readOffset;
}

/// Located + parsed RTT control block.
final class RttControlBlock {
  RttControlBlock({required this.address, required this.upChannels});

  final int address;
  final List<RttUpChannel> upChannels;
}

/// ESP32-C3 DRAM range scanned when the ELF has no `_SEGGER_RTT` symbol.
const int esp32c3DramStart = 0x3FC80000;
const int esp32c3DramEnd = 0x3FCE0000;

final _rttSignature = ascii.encode('SEGGER RTT');

/// Locate the RTT control block: ELF `_SEGGER_RTT` symbol first, RAM
/// signature scan as fallback.
Future<RttControlBlock> locateRtt(
  TargetMemory mem,
  ElfFile? elf, {
  int scanStart = esp32c3DramStart,
  int scanEnd = esp32c3DramEnd,
}) async {
  final symbol = elf == null ? null : symbolByName(elf, '_SEGGER_RTT');
  if (symbol != null) {
    return readControlBlock(mem, symbol.value);
  }
  final found = await _scan(mem, scanStart, scanEnd);
  if (found == null) {
    throw const RttError(
      'no _SEGGER_RTT symbol and no control block signature in RAM '
      '(is the firmware running? built with defmt-rtt?)',
    );
  }
  return readControlBlock(mem, found);
}

/// Look up a symbol by exact name.
ElfSymbol? symbolByName(ElfFile elf, String name) {
  for (final symbol in elf.symbols) {
    if (symbol.name == name) {
      return symbol;
    }
  }
  return null;
}

/// Scan [scanStart, scanEnd) word-wise for the RTT signature.
Future<int?> _scan(TargetMemory mem, int start, int end) async {
  const chunkWords = 256; // 1 KiB per read
  final tail = Uint8List(15);
  var tailLen = 0;
  for (var addr = start; addr < end; addr += chunkWords * 4) {
    final words = (end - addr) ~/ 4;
    final count = words < chunkWords ? words : chunkWords;
    final data = await mem.readBlock(addr, count);
    final bytes = Uint8List.view(
      data.buffer.asByteData().buffer,
      data.offsetInBytes,
      count * 4,
    );
    // Overlap window: tail of previous chunk + this chunk.
    final window = Uint8List(tailLen + bytes.length)
      ..setRange(0, tailLen, tail)
      ..setRange(tailLen, tailLen + bytes.length, bytes);
    final at = _indexOf(window, _rttSignature);
    if (at != -1) {
      return addr - tailLen + at;
    }
    tailLen = 15 < window.length ? 15 : window.length;
    tail.setRange(0, tailLen, window, window.length - tailLen);
  }
  return null;
}

int _indexOf(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        continue outer;
      }
    }
    return i;
  }
  return -1;
}

/// Read and parse the control block at [address]. Validates the ID.
Future<RttControlBlock> readControlBlock(TargetMemory mem, int address) async {
  final header = await mem.readBlock(address, 6); // 16B ID + 2 counts
  final idBytes = Uint8List(16);
  for (var i = 0; i < 4; i++) {
    final word = header[i];
    idBytes[i * 4] = word & 0xFF;
    idBytes[i * 4 + 1] = (word >> 8) & 0xFF;
    idBytes[i * 4 + 2] = (word >> 16) & 0xFF;
    idBytes[i * 4 + 3] = (word >> 24) & 0xFF;
  }
  for (var i = 0; i < _rttSignature.length; i++) {
    if (idBytes[i] != _rttSignature[i]) {
      // Include what we actually read: all-zero means the debug module
      // never left reset (or the block is not in RAM yet), whereas
      // plausible-looking bytes point at a wrong address or a bad
      // memory-access sequence.
      final hex = idBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      final allZero = idBytes.every((b) => b == 0);
      throw RttError(
        'no "SEGGER RTT" signature at 0x${address.toRadixString(16)} — '
        'read [$hex]'
        '${allZero ? ' (all zero: memory reads are not reaching the target)' : ''}',
      );
    }
  }
  final maxUp = header[4];
  if (maxUp == 0 || maxUp > 64) {
    throw RttError('implausible MaxNumUpBuffers $maxUp');
  }
  final descriptors = await mem.readBlock(address + 24, maxUp * 6);
  final channels = <RttUpChannel>[];
  for (var i = 0; i < maxUp; i++) {
    final base = i * 6;
    channels.add(
      RttUpChannel(
        namePointer: descriptors[base],
        bufferAddress: descriptors[base + 1],
        bufferSize: descriptors[base + 2],
        descriptorAddress: address + 24 + i * 24,
        writeOffset: descriptors[base + 3],
        readOffset: descriptors[base + 4],
      ),
    );
  }
  return RttControlBlock(address: address, upChannels: channels);
}

/// Polls one up channel for new bytes and acknowledges them (RdOff
/// advance) so a blocking firmware never wedges.
final class RttChannelReader {
  RttChannelReader(this._mem, this.channel);

  final TargetMemory _mem;
  final RttUpChannel channel;

  /// Read the channel name (NUL-terminated string in target RAM).
  Future<String> readName() async {
    if (channel.namePointer == 0) {
      return '';
    }
    final words = await _mem.readBlock(channel.namePointer, 8);
    final bytes = <int>[];
    for (final word in words) {
      for (var shift = 0; shift < 32; shift += 8) {
        final b = (word >> shift) & 0xFF;
        if (b == 0) {
          return ascii.decode(bytes, allowInvalid: true);
        }
        bytes.add(b);
      }
    }
    return ascii.decode(bytes, allowInvalid: true);
  }

  /// Returns bytes written since the last poll (possibly empty).
  Future<Uint8List> poll() async {
    // Re-read WrOff/RdOff (offsets 3 and 4 within the descriptor).
    final offsets = await _mem.readBlock(channel.descriptorAddress + 12, 2);
    channel.writeOffset = offsets[0];
    channel.readOffset = offsets[1];

    final wr = channel.writeOffset;
    final rd = channel.readOffset;
    final size = channel.bufferSize;
    if (wr == rd || size <= 0 || wr >= size || rd >= size) {
      return Uint8List(0);
    }
    final parts = <Uint8List>[];
    if (wr > rd) {
      parts.add(await _readBytes(channel.bufferAddress + rd, wr - rd));
    } else {
      parts.add(await _readBytes(channel.bufferAddress + rd, size - rd));
      if (wr > 0) {
        parts.add(await _readBytes(channel.bufferAddress, wr));
      }
    }
    // Acknowledge: host consumed through WrOff.
    await _mem.write32(channel.descriptorAddress + 16, wr);
    channel.readOffset = wr;

    final total = parts.fold<int>(0, (sum, p) => sum + p.length);
    final out = Uint8List(total);
    var at = 0;
    for (final part in parts) {
      out.setRange(at, at + part.length, part);
      at += part.length;
    }
    return out;
  }

  Future<Uint8List> _readBytes(int address, int length) async {
    // Align to words: read covering words and slice.
    final startWord = address & ~3;
    final endWord = (address + length + 3) & ~3;
    final words = await _mem.readBlock(startWord, (endWord - startWord) ~/ 4);
    final bytes = Uint8List(words.length * 4);
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      bytes[i * 4] = word & 0xFF;
      bytes[i * 4 + 1] = (word >> 8) & 0xFF;
      bytes[i * 4 + 2] = (word >> 16) & 0xFF;
      bytes[i * 4 + 3] = (word >> 24) & 0xFF;
    }
    final start = address - startWord;
    return Uint8List.sublistView(bytes, start, start + length);
  }
}
