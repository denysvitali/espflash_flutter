import 'package:espflash_flutter/defmt/rzcobs.dart';
import 'package:flutter_test/flutter_test.dart';

/// (decoded, encoded) pairs from the rzcobs crate's own test suite
/// (Dirbaio/rzcobs v0.1.2), plus vectors generated with the crate's
/// `encode` for this repo (test comment in each group).
final _crateVectors = <(List<int>, List<int>)>[
  (_hex(''), _hex('')),
  (_hex('00'), _hex('7f')),
  (_hex('0000'), _hex('7f')),
  (_hex('00000000000000'), _hex('7f')),
  (_hex('0000000000000000'), _hex('7f7f')),
  (_hex('01'), _hex('017e')),
  (_hex('0100'), _hex('017e')),
  (_hex('0001'), _hex('017d')),
  (_hex('0102'), _hex('01027c')),
  (_hex('11223344556600'), _hex('11223344556640')),
  (_hex('11223344556677'), _hex('1122334455667780')),
  (_hex('1122334455667700'), _hex('1122334455667780')),
  (_hex('1122334455667788'), _hex('112233445566778881')),
  // 13 zeros + ff; 5 zeros, 44, zero, 6 zeros, ff.
  ([...List.filled(13, 0), 0xff], _hex('7fff3f')),
  (
    [...List.filled(5, 0), 0x44, 0, ...List.filled(6, 0), 0xff],
    _hex('445fff3f'),
  ),
  // 133 literal bytes → 0xfe run; 134 → 0xff; trailing zero absorbed.
  (
    [for (var i = 1; i <= 0x85; i++) i],
    [for (var i = 1; i <= 0x85; i++) i, 0xfe],
  ),
  (
    [for (var i = 1; i <= 0x85; i++) i, 0x00],
    [for (var i = 1; i <= 0x85; i++) i, 0xfe],
  ),
  (
    [for (var i = 1; i <= 0x86; i++) i],
    [for (var i = 1; i <= 0x86; i++) i, 0xff],
  ),
  (
    [for (var i = 1; i <= 0x86; i++) i, 0x00],
    [for (var i = 1; i <= 0x86; i++) i, 0xff, 0x7f],
  ),
];

/// Generated with rzcobs 0.1.2 `encode` (see tool/rzcobs-gen).
const _generatedVectors = <(String, String)>[
  ('01', '017e'),
  ('01020304050607', '0102030405060780'),
  ('00000000000000000000', '7f7f'),
  ('0100020003', '0102036a'),
  ('ff00ff00', 'ffff7a'),
  (
    '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20'
    '2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40'
    '4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60'
    '6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f80'
    '8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0'
    'a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0'
    'c1c2c3c4c5c6c7c8',
    '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20'
    '2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40'
    '4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60'
    '6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f80'
    '818283848586ff8788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f'
    'a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf'
    'c0c1c2c3c4c5c6c7c8bb',
  ),
  (
    '000102000405000708000a0b000d0e00101100131400161700191a001c1d001f'
    '20002223002526002829002b2c002e2f0031',
    '010204054907080a0b0d240e10111314121617191a491c1d1f20222423252628'
    '29122b2c2e2f49317e',
  ),
  ('070000000000000000000008', '077e086f'),
  ('68656c6c6f206465666d74', '68656c6c6f206465666d7484'),
  ('deadbeef000100020003cafe', 'deadbeef01500203cafe62'),
  // Realistic defmt frame: index 0x0002, u32 timestamp, u8 arg.
  ('020040420f002a', '0240420f2a22'),
];

List<int> _hex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

void main() {
  group('rzcobs', () {
    test('crate vectors: encode matches exactly', () {
      for (final (decoded, encoded) in _crateVectors) {
        expect(
          rzcobsEncode(decoded),
          encoded,
          reason: 'encode of $decoded',
        );
      }
    });

    test('crate vectors: decode prefix + phantom zeros', () {
      for (final (decoded, encoded) in _crateVectors) {
        final got = rzcobsDecode(encoded);
        expect(
          got.sublist(0, decoded.length),
          decoded,
          reason: 'decode of $encoded',
        );
        expect(
          got.sublist(decoded.length).every((b) => b == 0),
          isTrue,
          reason: 'trailing bytes of $encoded must be zeros',
        );
      }
    });

    test('generated vectors: encode matches the Rust crate', () {
      for (final (decoded, encoded) in _generatedVectors) {
        expect(
          rzcobsEncode(_hex(decoded)),
          _hex(encoded),
          reason: 'encode of $decoded',
        );
      }
    });

    test('generated vectors: decode round-trips via prefix', () {
      for (final (decoded, encoded) in _generatedVectors) {
        final want = _hex(decoded);
        final got = rzcobsDecode(_hex(encoded));
        expect(got.sublist(0, want.length), want);
      }
    });

    test('round-trip: encode then decode restores arbitrary data', () {
      final samples = <List<int>>[
        [1, 2, 3],
        [0, 1, 0, 2, 0, 3, 0],
        List<int>.generate(300, (i) => (i * 37) & 0xFF),
        List<int>.filled(20, 0),
      ];
      for (final sample in samples) {
        final got = rzcobsDecode(rzcobsEncode(sample));
        expect(got.sublist(0, sample.length), sample);
      }
    });

    test('decode rejects frames containing 0x00', () {
      expect(() => rzcobsDecode([0x01, 0x00, 0x7e]), throwsFormatException);
    });

    test('decode rejects truncated literal runs', () {
      expect(() => rzcobsDecode([0x01, 0xff]), throwsFormatException);
    });
  });
}
