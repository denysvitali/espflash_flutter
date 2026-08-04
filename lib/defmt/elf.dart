/// Minimal ELF32/ELF64 little-endian parser, just enough to extract the
/// `.defmt` section(s), the symbol table, and string tables needed to
/// build a defmt interned-string table.
///
/// Supports ET_EXEC/ET_DYN files as produced by Rust embedded toolchains
/// (RISC-V ESP32-C3 and friends are ELF32 LE).
library;

import 'dart:convert';
import 'dart:typed_data';

/// One ELF section header.
final class ElfSection {
  const ElfSection({
    required this.name,
    required this.type,
    required this.address,
    required this.offset,
    required this.size,
    required this.link,
    required this.entrySize,
  });

  final String name;
  final int type;
  final int address;
  final int offset;
  final int size;

  /// Section index of the associated table (symtab → strtab).
  final int link;
  final int entrySize;

  static const int shtSymtab = 2;
  static const int shtStrtab = 3;
}

/// One symbol table entry.
final class ElfSymbol {
  const ElfSymbol({
    required this.name,
    required this.value,
    required this.size,
    required this.sectionIndex,
  });

  final String name;

  /// Symbol address (`st_value`). For `.defmt` entries this doubles as
  /// the interning index sent on the wire.
  final int value;
  final int size;
  final int sectionIndex;
}

/// Parsed ELF file.
final class ElfFile {
  ElfFile._(this._bytes, this.sections, this.symbols);

  final Uint8List _bytes;

  /// All sections, in header order.
  final List<ElfSection> sections;

  /// All symbols from every SHT_SYMTAB section.
  final List<ElfSymbol> symbols;

  /// Raw contents of [section].
  Uint8List sectionBytes(ElfSection section) {
    final end = section.offset + section.size;
    if (end > _bytes.length) {
      throw const FormatException('section extends past end of file');
    }
    return Uint8List.sublistView(_bytes, section.offset, end);
  }

  /// Sections named `.defmt` or starting with `.defmt.`.
  List<ElfSection> get defmtSections => sections
      .where((s) => s.name == '.defmt' || s.name.startsWith('.defmt.'))
      .toList();

  /// Parse [bytes] as an ELF file. Throws [FormatException] on anything
  /// unexpected.
  static ElfFile parse(Uint8List bytes) {
    if (bytes.length < 16 ||
        bytes[0] != 0x7f ||
        bytes[1] != 0x45 || // E
        bytes[2] != 0x4c || // L
        bytes[3] != 0x46) {
      // F
      throw const FormatException('not an ELF file');
    }
    final is64 = switch (bytes[4]) {
      1 => false,
      2 => true,
      _ => throw const FormatException('unknown ELF class'),
    };
    if (bytes[5] != 1) {
      throw const FormatException('only little-endian ELF is supported');
    }
    final data = ByteData.sublistView(bytes);
    int u16(int off) => data.getUint16(off, Endian.little);
    int u32(int off) => data.getUint32(off, Endian.little);
    int u64(int off) => data.getUint64(off, Endian.little);

    final int shoff;
    final int shentsize;
    final int shnumRaw;
    final int shstrndxRaw;
    if (is64) {
      shoff = u64(0x28);
      shentsize = u16(0x3a);
      shnumRaw = u16(0x3c);
      shstrndxRaw = u16(0x3e);
    } else {
      shoff = u32(0x20);
      shentsize = u16(0x2e);
      shnumRaw = u16(0x30);
      shstrndxRaw = u16(0x32);
    }
    if (shoff == 0) {
      throw const FormatException('ELF has no section headers');
    }

    int shAddr(int index, int fieldOffset) {
      final base = shoff + index * shentsize + fieldOffset;
      return is64 ? u64(base) : u32(base);
    }

    // Field offsets within a section header (sh_addr / sh_offset / sh_size /
    // sh_link / sh_entsize) differ between ELF32 and ELF64.
    final fAddr = is64 ? 0x10 : 0x0c;
    final fOffset = is64 ? 0x18 : 0x10;
    final fSize = is64 ? 0x20 : 0x14;
    final fLink = is64 ? 0x28 : 0x18;
    final fEntsize = is64 ? 0x38 : 0x24;

    // Extended numbering: real counts live in section header 0.
    final shnum = shnumRaw == 0 ? shAddr(0, fSize) : shnumRaw;
    final shstrndx = shstrndxRaw == 0xffff ? shAddr(0, fLink) : shstrndxRaw;

    String strAt(int strtabOffset, int index) {
      final start = strtabOffset + index;
      var end = start;
      while (end < bytes.length && bytes[end] != 0) {
        end++;
      }
      // UTF-8, not code units: defmt format strings live in symbol
      // names and routinely contain non-ASCII (emoji, arrows, ×).
      // Decoding per byte turns "⚡" into "â¡".
      return utf8.decode(
        Uint8List.sublistView(bytes, start, end),
        allowMalformed: true,
      );
    }

    int shInt(int index, int fieldOffset) {
      final base = shoff + index * shentsize + fieldOffset;
      return is64 ? u64(base) : u32(base);
    }

    final sections = <ElfSection>[];
    for (var i = 0; i < shnum; i++) {
      final base = shoff + i * shentsize;
      final nameOff = u32(base);
      final type = u32(base + 4);
      final strtabOff = shInt(shstrndx, fOffset);
      sections.add(
        ElfSection(
          name: strAt(strtabOff, nameOff),
          type: type,
          address: shInt(i, fAddr),
          offset: shInt(i, fOffset),
          size: shInt(i, fSize),
          link: u32(base + fLink),
          entrySize: shInt(i, fEntsize),
        ),
      );
    }

    final symbols = <ElfSymbol>[];
    for (var i = 0; i < sections.length; i++) {
      final section = sections[i];
      if (section.type != ElfSection.shtSymtab || section.entrySize == 0) {
        continue;
      }
      final strtab = sections[section.link];
      final count = section.size ~/ section.entrySize;
      for (var s = 0; s < count; s++) {
        final base = section.offset + s * section.entrySize;
        final int nameOff;
        final int value;
        final int size;
        final int shndx;
        if (is64) {
          nameOff = u32(base);
          value = u64(base + 8);
          size = u64(base + 16);
          shndx = u16(base + 6);
        } else {
          nameOff = u32(base);
          value = u32(base + 4);
          size = u32(base + 8);
          shndx = u16(base + 14);
        }
        symbols.add(
          ElfSymbol(
            name: strAt(strtab.offset, nameOff),
            value: value,
            size: size,
            sectionIndex: shndx,
          ),
        );
      }
    }

    return ElfFile._(bytes, sections, symbols);
  }
}
