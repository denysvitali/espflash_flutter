import 'dart:convert';
import 'dart:typed_data';

import 'package:espflash_flutter/defmt/defmt.dart';
import 'package:espflash_flutter/defmt/rzcobs_stream.dart';
import 'package:espflash_flutter/rtt/rtt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../defmt/defmt_decoder_test.dart' show buildTestElf, defmtSymbol;

/// Sparse fake target memory.
final class FakeMemory implements TargetMemory {
  final Map<int, int> words = <int, int>{};
  final List<(int, int)> writes = <(int, int)>[];

  void writeBytes(int address, List<int> data) {
    for (var i = 0; i < data.length; i++) {
      final wordAddr = (address + i) & ~3;
      final shift = ((address + i) & 3) * 8;
      final old = words[wordAddr] ?? 0;
      words[wordAddr] = (old & ~(0xFF << shift)) | (data[i] << shift);
    }
  }

  @override
  Future<int> read32(int address) async => words[address] ?? 0;

  @override
  Future<Uint32List> readBlock(int address, int wordCount) async =>
      Uint32List.fromList([
        for (var i = 0; i < wordCount; i++) words[address + i * 4] ?? 0,
      ]);

  @override
  Future<void> write32(int address, int value) async {
    words[address] = value;
    writes.add((address, value));
  }
}

/// Build a fake RTT control block in [mem]: 1 up channel "defmt" with a
/// 64-byte ring.
(int cbAddr, int descAddr, int bufAddr) buildRttBlock(FakeMemory mem) {
  const cb = 0x20000000;
  const desc = cb + 24;
  const name = 0x20000100;
  const buf = 0x20000200;
  mem.writeBytes(cb, ascii.encode('SEGGER RTT') + List.filled(6, 0));
  mem.words[cb + 16] = 1; // MaxNumUpBuffers
  mem.words[cb + 20] = 0; // MaxNumDownBuffers
  mem.writeBytes(name, ascii.encode('defmt'));
  mem.words[desc + 0] = name;
  mem.words[desc + 4] = buf;
  mem.words[desc + 8] = 64;
  mem.words[desc + 12] = 0; // WrOff
  mem.words[desc + 16] = 0; // RdOff
  return (cb, desc, buf);
}

void main() {
  group('RTT control block', () {
    test('located via _SEGGER_RTT symbol and parsed', () async {
      final mem = FakeMemory();
      final (cb, _, _) = buildRttBlock(mem);
      final elf = ElfFile.parse(buildTestElf([('_SEGGER_RTT', cb)]));
      final block = await locateRtt(mem, elf);
      expect(block.address, cb);
      expect(block.upChannels, hasLength(1));
      expect(block.upChannels.single.bufferSize, 64);
      final name = await RttChannelReader(mem, block.upChannels.single)
          .readName();
      expect(name, 'defmt');
    });

    test('bad signature throws', () async {
      final mem = FakeMemory();
      expect(
        () => readControlBlock(mem, 0x20000000),
        throwsA(isA<RttError>()),
      );
    });
  });

  group('RttChannelReader.poll', () {
    test('linear read advances RdOff', () async {
      final mem = FakeMemory();
      final (_, desc, buf) = buildRttBlock(mem);
      mem.writeBytes(buf, [1, 2, 3, 4, 5]);
      mem.words[desc + 12] = 5; // WrOff
      final reader = RttChannelReader(
        mem,
        RttUpChannel(
          namePointer: 0,
          bufferAddress: buf,
          bufferSize: 64,
          descriptorAddress: desc,
          writeOffset: 0,
          readOffset: 0,
        ),
      );
      final data = await reader.poll();
      expect(data, [1, 2, 3, 4, 5]);
      expect(mem.words[desc + 16], 5); // RdOff acknowledged
    });

    test('wrap-around read returns both segments in order', () async {
      final mem = FakeMemory();
      final (_, desc, buf) = buildRttBlock(mem);
      // RdOff=60, WrOff=4 → data = buf[60..64] + buf[0..4].
      mem.writeBytes(buf + 60, [0xAA, 0xBB, 0xCC, 0xDD]);
      mem.writeBytes(buf, [1, 2, 3, 4]);
      mem.words[desc + 12] = 4; // WrOff
      mem.words[desc + 16] = 60; // RdOff
      final reader = RttChannelReader(
        mem,
        RttUpChannel(
          namePointer: 0,
          bufferAddress: buf,
          bufferSize: 64,
          descriptorAddress: desc,
          writeOffset: 4,
          readOffset: 60,
        ),
      );
      final data = await reader.poll();
      expect(data, [0xAA, 0xBB, 0xCC, 0xDD, 1, 2, 3, 4]);
      expect(mem.words[desc + 16], 4);
    });

    test('empty when WrOff == RdOff', () async {
      final mem = FakeMemory();
      final (_, desc, buf) = buildRttBlock(mem);
      final reader = RttChannelReader(
        mem,
        RttUpChannel(
          namePointer: 0,
          bufferAddress: buf,
          bufferSize: 64,
          descriptorAddress: desc,
          writeOffset: 0,
          readOffset: 0,
        ),
      );
      expect(await reader.poll(), isEmpty);
    });
  });

  group('DefmtStreamDecoder (bare rzcobs, RTT-style)', () {
    final elf = buildTestElf([
      (defmtSymbol('defmt_timestamp', '{=u32}'), 2),
      (defmtSymbol('defmt_info', 'Hello {=u8}!'), 4),
    ]);
    final table = DefmtTable.parse(ElfFile.parse(elf))!;

    Uint8List rttFrame(int index, List<int> payload) => Uint8List.fromList([
      ...rzcobsEncode(Uint8List.fromList([
        index & 0xFF, index >> 8, ...payload,
      ])),
      0x00,
    ]);

    List<int> u32(int v) =>
        [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

    test('decodes 00-delimited frames, no FF00 prefix', () {
      final decoder = DefmtStreamDecoder(table);
      final lines = decoder.feed([
        ...rttFrame(4, [...u32(123), 7]),
        ...rttFrame(4, [...u32(124), 8]),
      ]);
      expect(lines, hasLength(2));
      expect((lines[0] as DefmtLine).frame.text, 'Hello 7!');
      expect((lines[0] as DefmtLine).frame.timestamp, '123');
      expect((lines[1] as DefmtLine).frame.text, 'Hello 8!');
      expect(decoder.droppedFrames, 0);
    });

    test('frame split across feeds; garbage frame dropped, stream survives',
        () {
      final decoder = DefmtStreamDecoder(table);
      final wire = rttFrame(4, [...u32(1), 42]);
      expect(decoder.feed(wire.sublist(0, 3)), isEmpty);
      final lines = decoder.feed([
        ...wire.sublist(3),
        0x99, 0x88, 0x00, // bogus rzcobs (unknown index)
        ...rttFrame(4, [...u32(2), 43]),
      ]);
      final texts = lines.whereType<DefmtLine>().map(
            (l) => l.frame.text,
          );
      expect(texts, ['Hello 42!', 'Hello 43!']);
      expect(decoder.droppedFrames, 1);
    });
  });
}
