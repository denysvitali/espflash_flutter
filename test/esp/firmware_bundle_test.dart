import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:espflash_flutter/esp/firmware_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a .tar.gz with [files], optionally appending a SHA256SUMS
/// entry covering them.
Uint8List buildBundle(
  Map<String, List<int>> files, {
  bool withChecksums = true,
  String? corruptChecksumFor,
}) {
  final archive = Archive();
  files.forEach((name, data) {
    archive.add(ArchiveFile.bytes(name, Uint8List.fromList(data)));
  });
  if (withChecksums) {
    final lines = <String>[
      for (final entry in files.entries)
        '${entry.key == corruptChecksumFor ? 'de' * 32 : sha256.convert(entry.value)}  ${entry.key}',
    ];
    archive.add(
      ArchiveFile.bytes(
        'SHA256SUMS',
        Uint8List.fromList(utf8.encode('${lines.join('\n')}\n')),
      ),
    );
  }
  final tar = TarEncoder().encodeBytes(archive);
  return Uint8List.fromList(GZipEncoder().encodeBytes(tar));
}

/// 4 bytes of ELF magic + padding, enough for the shape checks here.
final elfBytes = Uint8List.fromList([0x7F, 0x45, 0x4C, 0x46, ...List.filled(60, 0)]);

const partitionCsv = '''
# Name,   Type, SubType, Offset,   Size,  Flags
nvs,      data, nvs,     0x9000,   0x6000,
otadata,  data, ota,     0xf000,   0x2000,
app0,     app,  ota_0,   0x20000,  0x1C0000,
app1,     app,  ota_1,   0x1e0000, 0x1C0000,
''';

void main() {
  group('looksLikeBundle / looksLikeElf', () {
    test('gzip magic wins over the file name', () {
      final gz = buildBundle({'a.bin': [1, 2, 3]});
      expect(looksLikeBundle('downloaded-file', gz), isTrue);
      expect(looksLikeBundle('x.tar.gz', Uint8List(0)), isTrue);
      expect(looksLikeBundle('x.bin', Uint8List.fromList([1, 2])), isFalse);
    });

    test('ELF magic detected', () {
      expect(looksLikeElf(elfBytes), isTrue);
      expect(looksLikeElf(Uint8List.fromList([0xE9, 0, 0, 0])), isFalse);
    });
  });

  group('parseFirmwareBundle', () {
    test('full-flash image preferred, offset 0, ELF extracted', () {
      final bundle = parseFirmwareBundle(
        buildBundle({
          'fw-production-ota.bin': List<int>.filled(32, 0xAA),
          'fw-production-full-flash.bin': List<int>.filled(64, 0xBB),
          'fw-production.elf': elfBytes,
          'partitions.csv': utf8.encode(partitionCsv),
        }),
      );
      expect(bundle.images.first.isFullFlash, isTrue);
      expect(bundle.images.first.offset, 0);
      expect(bundle.images.first.bytes, hasLength(64));
      expect(bundle.images, hasLength(2));
      // OTA image goes to the first app partition from the CSV.
      expect(bundle.images[1].offset, 0x20000);
      expect(bundle.elf, elfBytes);
      expect(bundle.elfName, 'fw-production.elf');
      expect(bundle.verifiedFiles, 4);
    });

    test('app offset falls back to 0x10000 without a partition table', () {
      final bundle = parseFirmwareBundle(
        buildBundle({'app-ota.bin': List<int>.filled(8, 1)}),
      );
      expect(bundle.images.single.offset, 0x10000);
      expect(bundle.images.single.isFullFlash, isFalse);
    });

    test('checksum mismatch is rejected', () {
      final bytes = buildBundle(
        {
          'a-full-flash.bin': List<int>.filled(16, 7),
          'a.elf': elfBytes,
        },
        corruptChecksumFor: 'a-full-flash.bin',
      );
      expect(
        () => parseFirmwareBundle(bytes),
        throwsA(
          isA<BundleFormatException>().having(
            (e) => e.message,
            'message',
            contains('checksum mismatch'),
          ),
        ),
      );
    });

    test('bundle without checksums still parses (0 verified)', () {
      final bundle = parseFirmwareBundle(
        buildBundle(
          {'x-full-flash.bin': List<int>.filled(4, 9)},
          withChecksums: false,
        ),
      );
      expect(bundle.verifiedFiles, 0);
      expect(bundle.images, hasLength(1));
    });

    test('nested directory entries are flattened', () {
      final bundle = parseFirmwareBundle(
        buildBundle({
          'build/out/fw-full-flash.bin': List<int>.filled(4, 3),
          'build/out/fw.elf': elfBytes,
        }),
      );
      expect(bundle.images.single.name, 'fw-full-flash.bin');
      expect(bundle.elfName, 'fw.elf');
    });

    test('bundle with no .bin is rejected', () {
      expect(
        () => parseFirmwareBundle(buildBundle({'only.elf': elfBytes})),
        throwsA(isA<BundleFormatException>()),
      );
    });

    test('non-gzip input is rejected', () {
      expect(
        () => parseFirmwareBundle(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<BundleFormatException>()),
      );
    });
  });

  group('appOffsetFromPartitionCsv', () {
    test('first app row wins', () {
      expect(appOffsetFromPartitionCsv(partitionCsv), 0x20000);
    });

    test('decimal and K/M suffixes', () {
      expect(
        appOffsetFromPartitionCsv('app0, app, ota_0, 64K, 1M,'),
        64 * 1024,
      );
      expect(
        appOffsetFromPartitionCsv('app0, app, factory, 65536, 1M,'),
        65536,
      );
    });

    test('rows without an offset are skipped', () {
      expect(
        appOffsetFromPartitionCsv('app0, app, ota_0, , 1M,\n'
            'app1, app, ota_1, 0x30000, 1M,'),
        0x30000,
      );
    });

    test('no app row → null', () {
      expect(appOffsetFromPartitionCsv('nvs, data, nvs, 0x9000, 0x6000,'),
          isNull);
    });
  });
}
