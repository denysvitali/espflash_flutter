/// Builds the defmt interned-string table from an ELF file, mirroring
/// defmt-decoder's `elf2table`.
///
/// Each interned string is a symbol in a `.defmt` section whose *name* is
/// a JSON object: `{"package":…,"tag":"defmt_info","data":"…",
/// "disambiguator":…,"crate_name":…}`. The symbol address is the
/// interning index sent on the wire. `_defmt_version_ = N` and
/// `_defmt_encoding_ = rzcobs|raw` symbols carry the wire format version.
library;

import 'dart:convert';

import 'elf.dart';

/// defmt wire format versions this decoder understands.
const supportedDefmtVersions = <String>{'3', '4'};

/// Log severity carried by a table entry's tag.
enum DefmtLevel { trace, debug, info, warn, error }

/// One interned string entry.
final class TableEntry {
  const TableEntry({
    required this.tag,
    required this.format,
    required this.rawSymbol,
  });

  /// e.g. `defmt_info`, `defmt_timestamp`, `defmt_prim`.
  final String tag;

  /// The format string (JSON `data` field).
  final String format;

  /// The full JSON symbol name (used for diagnostics).
  final String rawSymbol;

  /// Severity of this entry, if the tag is a log level.
  DefmtLevel? get level => switch (tag) {
    'defmt_trace' => DefmtLevel.trace,
    'defmt_debug' => DefmtLevel.debug,
    'defmt_info' => DefmtLevel.info,
    'defmt_warn' => DefmtLevel.warn,
    'defmt_error' => DefmtLevel.error,
    _ => null,
  };

  /// Entries with these tags can start a frame.
  bool get isPrintable =>
      level != null || tag == 'defmt_println';
}

/// defmt wire encoding.
enum DefmtEncoding { rzcobs, raw }

/// The parsed defmt table.
final class DefmtTable {
  DefmtTable({
    required this.entries,
    required this.timestamp,
    required this.version,
    required this.encoding,
  });

  /// Interning index (symbol address) → entry.
  final Map<int, TableEntry> entries;
  final TableEntry? timestamp;
  final String version;
  final DefmtEncoding encoding;

  bool get hasTimestamp => timestamp != null;

  /// Entry at [index], regardless of tag. Null if unknown.
  TableEntry? lookup(int index) => entries[index];

  /// Parse the defmt table out of [elf]. Returns null when the firmware
  /// doesn't use defmt at all; throws [FormatException] on inconsistencies.
  static DefmtTable? parse(ElfFile elf) {
    String? version;
    DefmtEncoding? encoding;
    for (final symbol in elf.symbols) {
      if (symbol.name.startsWith('_defmt_version_ = ')) {
        if (version != null && version != _versionOf(symbol.name)) {
          throw const FormatException('multiple defmt versions in use');
        }
        version = _versionOf(symbol.name);
      } else if (symbol.name.startsWith('_defmt_encoding_ = ')) {
        encoding =
            symbol.name.substring('_defmt_encoding_ = '.length).trim() == 'raw'
            ? DefmtEncoding.raw
            : DefmtEncoding.rzcobs;
      }
    }

    final defmtSections = elf.defmtSections;
    if (defmtSections.isEmpty) {
      if (version != null) {
        throw const FormatException(
          'defmt version found, but no .defmt metadata section',
        );
      }
      return null;
    }
    if (version == null) {
      throw const FormatException(
        'found .defmt metadata sections, but no defmt version symbol',
      );
    }
    if (!supportedDefmtVersions.contains(version)) {
      throw FormatException(
        'defmt wire format version mismatch: firmware uses version '
        '$version, this decoder supports ${supportedDefmtVersions.join('/')}',
      );
    }

    final sectionIndex = <int, ElfSection>{
      for (var i = 0; i < elf.sections.length; i++) i: elf.sections[i],
    };
    final defmtSectionIndices = <int>{};
    for (var i = 0; i < elf.sections.length; i++) {
      final s = elf.sections[i];
      if (s.name == '.defmt' || s.name.startsWith('.defmt.')) {
        defmtSectionIndices.add(i);
      }
    }

    final entries = <int, TableEntry>{};
    TableEntry? timestamp;
    for (final symbol in elf.symbols) {
      if (!defmtSectionIndices.contains(symbol.sectionIndex)) {
        continue;
      }
      final Map<String, Object?> json;
      try {
        final decoded = jsonDecode(symbol.name);
        if (decoded is! Map<String, Object?>) {
          continue;
        }
        json = decoded;
      } on Object {
        continue; // Not a defmt JSON symbol (e.g. section start markers).
      }
      final tag = json['tag'];
      final data = json['data'];
      if (tag is! String || data is! String) {
        continue;
      }
      final entry = TableEntry(
        tag: tag,
        format: data,
        rawSymbol: symbol.name,
      );
      if (tag == 'defmt_timestamp') {
        if (timestamp != null) {
          throw const FormatException('multiple defmt timestamp formats');
        }
        timestamp = entry;
      }
      entries[symbol.value] = entry;
      // Touch the section so an unused-variable warning can't hide a
      // parsing mistake above.
      assert(sectionIndex.containsKey(symbol.sectionIndex));
    }

    return DefmtTable(
      entries: entries,
      timestamp: timestamp,
      version: version,
      encoding: encoding ?? DefmtEncoding.rzcobs,
    );
  }

  static String _versionOf(String name) =>
      name.substring('_defmt_version_ = '.length).trim();
}
