/// Parser for `.tar.gz` firmware bundles produced by CI.
///
/// A bundle carries the artifacts of one build:
///
/// - `*full-flash*.bin` — complete flash image, written at offset 0
/// - `*ota*.bin` — application-only image, written at the app partition
/// - `*.elf` — the linked binary, for defmt decoding and RTT symbols
/// - `partitions.csv` — partition table (used to locate the app offset)
/// - `SHA256SUMS` — `<sha256>  <name>` lines covering every other file
///
/// File names are matched by shape, never by project-specific names, so
/// any producer following the same layout works.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Default app-partition offset when no partition table says otherwise.
const int defaultAppOffset = 0x10000;

/// True when [bytes] (named [name]) is a gzip archive: gzip magic wins
/// over the file name, since pickers often rename downloads.
bool looksLikeBundle(String name, Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
    return true;
  }
  final lower = name.toLowerCase();
  return lower.endsWith('.tar.gz') || lower.endsWith('.tgz');
}

/// True when [bytes] starts with the ELF magic.
bool looksLikeElf(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x7F &&
    bytes[1] == 0x45 &&
    bytes[2] == 0x4C &&
    bytes[3] == 0x46;

final class BundleFormatException implements Exception {
  const BundleFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One flashable image found in a bundle.
final class BundleImage {
  const BundleImage({
    required this.name,
    required this.bytes,
    required this.offset,
    required this.isFullFlash,
  });

  final String name;
  final Uint8List bytes;

  /// Flash offset this image must be written at.
  final int offset;

  /// True for whole-flash images (offset 0, includes bootloader and
  /// partition table).
  final bool isFullFlash;

  String get label => isFullFlash ? 'full flash' : 'app / OTA';
}

/// Contents of a parsed bundle.
final class FirmwareBundle {
  const FirmwareBundle({
    required this.images,
    required this.elf,
    required this.elfName,
    required this.partitionCsv,
    required this.verifiedFiles,
  });

  /// Flashable images, full-flash first.
  final List<BundleImage> images;

  /// The ELF, if the bundle ships one (defmt + RTT symbols).
  final Uint8List? elf;
  final String? elfName;

  /// Raw `partitions.csv`, if present.
  final String? partitionCsv;

  /// Number of files whose SHA256 was checked against `SHA256SUMS`.
  final int verifiedFiles;

  BundleImage? get preferredImage => images.isEmpty ? null : images.first;
}

/// Parse a gzip-compressed tar [bytes] into a [FirmwareBundle].
///
/// Throws [BundleFormatException] when the archive is unreadable, holds
/// no flashable image, or fails its own checksum file.
FirmwareBundle parseFirmwareBundle(Uint8List bytes) {
  final Archive archive;
  try {
    archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
  } on Object catch (error) {
    throw BundleFormatException('not a readable .tar.gz bundle: $error');
  }

  final files = <String, Uint8List>{};
  for (final entry in archive) {
    if (!entry.isFile) {
      continue;
    }
    // Flatten paths: bundles may or may not carry a leading directory.
    final name = entry.name.split('/').last;
    if (name.isEmpty) {
      continue;
    }
    files[name] = Uint8List.fromList(entry.readBytes() ?? const <int>[]);
  }
  if (files.isEmpty) {
    throw const BundleFormatException('bundle contains no files');
  }

  final verified = _verifyChecksums(files);

  final partitionCsv = _findPartitionCsv(files);
  final appOffset = partitionCsv == null
      ? defaultAppOffset
      : appOffsetFromPartitionCsv(partitionCsv) ?? defaultAppOffset;

  final images = <BundleImage>[];
  String? elfName;
  Uint8List? elf;
  for (final entry in files.entries) {
    final lower = entry.key.toLowerCase();
    if (lower.endsWith('.elf')) {
      // Prefer the first ELF; bundles may ship several build flavours.
      elf ??= entry.value;
      elfName ??= entry.key;
      continue;
    }
    if (!lower.endsWith('.bin')) {
      continue;
    }
    final isFull = lower.contains('full-flash') || lower.contains('full_flash');
    images.add(
      BundleImage(
        name: entry.key,
        bytes: entry.value,
        offset: isFull ? 0 : appOffset,
        isFullFlash: isFull,
      ),
    );
  }
  if (images.isEmpty) {
    throw const BundleFormatException(
      'bundle has no .bin image to flash',
    );
  }
  images.sort((a, b) {
    if (a.isFullFlash != b.isFullFlash) {
      return a.isFullFlash ? -1 : 1;
    }
    return a.name.compareTo(b.name);
  });

  return FirmwareBundle(
    images: images,
    elf: elf,
    elfName: elfName,
    partitionCsv: partitionCsv,
    verifiedFiles: verified,
  );
}

/// Verifies every `<sha256>  <name>` line of a checksum file. Returns the
/// number of files checked (0 when the bundle ships no checksums).
int _verifyChecksums(Map<String, Uint8List> files) {
  Uint8List? sums;
  for (final entry in files.entries) {
    if (entry.key.toUpperCase().contains('SHA256SUM')) {
      sums = entry.value;
      break;
    }
  }
  if (sums == null) {
    return 0;
  }
  final text = utf8.decode(sums, allowMalformed: true);
  var checked = 0;
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      continue;
    }
    final expected = parts.first.toLowerCase();
    final name = parts.last.replaceFirst(RegExp(r'^\*'), '').split('/').last;
    final data = files[name];
    if (data == null) {
      continue; // Bundle may legitimately omit optional artefacts.
    }
    final actual = sha256.convert(data).toString();
    if (actual != expected) {
      throw BundleFormatException(
        'checksum mismatch for $name (bundle is corrupt or truncated)',
      );
    }
    checked++;
  }
  return checked;
}

String? _findPartitionCsv(Map<String, Uint8List> files) {
  for (final entry in files.entries) {
    if (entry.key.toLowerCase().endsWith('.csv')) {
      return utf8.decode(entry.value, allowMalformed: true);
    }
  }
  return null;
}

/// First app partition offset from an ESP-IDF `partitions.csv`.
///
/// Columns: `Name, Type, SubType, Offset, Size, Flags`. The first `app`
/// row (factory or ota_0) wins; blank offsets are skipped because the
/// real value is computed by the generator, not stored in the CSV.
int? appOffsetFromPartitionCsv(String csv) {
  for (final rawLine in csv.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final columns = line.split(',').map((c) => c.trim()).toList();
    if (columns.length < 4) {
      continue;
    }
    if (columns[1].toLowerCase() != 'app') {
      continue;
    }
    final offset = columns[3];
    if (offset.isEmpty) {
      continue;
    }
    final parsed = _parseOffset(offset);
    if (parsed != null) {
      return parsed;
    }
  }
  return null;
}

int? _parseOffset(String text) {
  final value = text.trim().toLowerCase();
  if (value.startsWith('0x')) {
    return int.tryParse(value.substring(2), radix: 16);
  }
  // Sizes/offsets may use K/M suffixes.
  final match = RegExp(r'^(\d+)([km])?$').firstMatch(value);
  if (match == null) {
    return null;
  }
  final base = int.parse(match.group(1)!);
  return switch (match.group(2)) {
    'k' => base * 1024,
    'm' => base * 1024 * 1024,
    _ => base,
  };
}
