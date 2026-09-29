import 'dart:typed_data';

import 'sqlite_format.dart';

class SqliteIndexEntry {
  SqliteIndexEntry(this.rowId, this.values);

  final int rowId;
  final List<Object?> values;

  List<Object?> get key => [...values, rowId];
}

class SqliteIndexBtree {
  static Uint8List emptyPage(int pageSize) {
    final page = Uint8List(pageSize);
    page[0] = 0x0a;
    _writeU16(page, 5, pageSize == 65536 ? 0 : pageSize);
    return page;
  }

  static List<SqliteIndexEntry> readTree(SqlitePagerSync pager, int rootPage) {
    final page = pager.readPage(rootPage);
    if (page[0] == 0x0a) return _readLeaf(page);
    if (page[0] != 0x02) {
      throw SqliteFormatException('unsupported index B-tree root page');
    }
    final count = _readU16(page, 3);
    final separators = <SqliteIndexEntry>[
      for (var index = 0; index < count; index++)
        _readInteriorEntry(page, _readU16(page, 12 + index * 2)),
    ];
    final children = <int>[
      for (var index = 0; index < count; index++)
        _readU32(page, _readU16(page, 12 + index * 2)),
      _readU32(page, 8),
    ];
    return [
      ...separators,
      for (final child in children) ..._readLeaf(pager.readPage(child)),
    ];
  }

  static void rewriteRows(
    SqlitePagerSync pager,
    int rootPage,
    List<SqliteIndexEntry> entries, {
    int Function(SqliteIndexEntry, SqliteIndexEntry)? compare,
  }) {
    entries.sort(compare ?? ((a, b) => _compareKey(a.key, b.key)));
    final existingChildren = _childPages(pager, rootPage);
    final pages = _pack(entries, pager.header.pageSize);
    if (pages.length == 1) {
      for (final child in existingChildren) {
        pager.freePage(child);
      }
      pager.writePage(rootPage, pages.single.page);
      return;
    }
    for (final child in existingChildren.skip(pages.length)) {
      pager.freePage(child);
    }
    for (var index = 0; index < pages.length - 1; index++) {
      final leafEntries = pages[index].entries.sublist(
        0,
        pages[index].entries.length - 1,
      );
      pages[index] = _PackedIndexPage(
        _buildLeaf(leafEntries, pager.header.pageSize),
        pages[index].last,
        leafEntries,
      );
    }
    final childPages = existingChildren.take(pages.length).toList();
    while (childPages.length < pages.length) {
      childPages.add(pager.allocatePage());
    }
    for (var index = 0; index < pages.length; index++) {
      pager.writePage(childPages[index], pages[index].page);
    }
    pager.writePage(
      rootPage,
      _interiorPage(pager.header.pageSize, childPages, pages),
    );
  }

  static void freeTree(SqlitePagerSync pager, int rootPage) {
    final children = _childPages(pager, rootPage);
    for (final page in [...children, rootPage]) {
      pager.freePage(page);
    }
  }

  static List<_PackedIndexPage> _pack(
    List<SqliteIndexEntry> entries,
    int pageSize,
  ) {
    final pages = <_PackedIndexPage>[];
    var page = emptyPage(pageSize);
    var pageEntries = <SqliteIndexEntry>[];
    var last = entries.isEmpty ? null : entries.first;
    for (final entry in entries) {
      try {
        page = _insertLeaf(page, pageSize, entry);
        pageEntries.add(entry);
        last = entry;
      } on SqliteFormatException {
        if (_readU16(page, 3) == 0) rethrow;
        pages.add(_PackedIndexPage(page, last!, pageEntries));
        page = _insertLeaf(emptyPage(pageSize), pageSize, entry);
        pageEntries = [entry];
        last = entry;
      }
    }
    pages.add(
      _PackedIndexPage(
        page,
        last ?? SqliteIndexEntry(0, const []),
        pageEntries,
      ),
    );
    return pages;
  }

  static Uint8List _buildLeaf(List<SqliteIndexEntry> entries, int pageSize) {
    var page = emptyPage(pageSize);
    for (final entry in entries) {
      page = _insertLeaf(page, pageSize, entry);
    }
    return page;
  }

  static Uint8List _insertLeaf(
    List<int> original,
    int pageSize,
    SqliteIndexEntry entry,
  ) {
    final page = Uint8List.fromList(original);
    final record = SqliteRecordCodec.encode(entry.key);
    final cell = <int>[]
      ..addAll(SqliteVarint.encode(record.length))
      ..addAll(record);
    final count = _readU16(page, 3);
    final contentStart = _readU16(page, 5);
    final actualContentStart = contentStart == 0 ? 65536 : contentStart;
    final newContentStart = actualContentStart - cell.length;
    if (newContentStart < 8 + (count + 1) * 2) {
      throw SqliteFormatException('index B-tree page is full');
    }
    page.setRange(newContentStart, actualContentStart, cell);
    _writeU16(page, 8 + count * 2, newContentStart);
    _writeU16(page, 3, count + 1);
    _writeU16(page, 5, newContentStart == 65536 ? 0 : newContentStart);
    return page;
  }

  static Uint8List _interiorPage(
    int pageSize,
    List<int> childPages,
    List<_PackedIndexPage> pages,
  ) {
    final page = Uint8List(pageSize);
    page[0] = 0x02;
    _writeU32(page, 8, childPages.last);
    var contentStart = pageSize;
    for (var index = 0; index < childPages.length - 1; index++) {
      final record = SqliteRecordCodec.encode(pages[index].last.key);
      final cell = Uint8List(
        4 + SqliteVarint.encode(record.length).length + record.length,
      );
      _writeU32(cell, 0, childPages[index]);
      final payloadLength = SqliteVarint.encode(record.length);
      cell.setRange(4, 4 + payloadLength.length, payloadLength);
      cell.setRange(4 + payloadLength.length, cell.length, record);
      contentStart -= cell.length;
      page.setRange(contentStart, contentStart + cell.length, cell);
      _writeU16(page, 12 + index * 2, contentStart);
    }
    _writeU16(page, 3, childPages.length - 1);
    _writeU16(page, 5, contentStart == 65536 ? 0 : contentStart);
    return page;
  }

  static List<SqliteIndexEntry> _readLeaf(List<int> page) {
    if (page[0] != 0x0a) {
      throw SqliteFormatException('expected an index leaf B-tree page');
    }
    final count = _readU16(page, 3);
    final entries = <SqliteIndexEntry>[];
    for (var index = 0; index < count; index++) {
      final pointer = _readU16(page, 8 + index * 2);
      final (length, lengthBytes) = SqliteVarint.read(page, pointer);
      final values = SqliteRecordCodec.decode(
        page.sublist(pointer + lengthBytes, pointer + lengthBytes + length),
      );
      if (values.isEmpty || values.last is! int) {
        throw SqliteFormatException('index key has no rowid suffix');
      }
      entries.add(
        SqliteIndexEntry(
          values.last as int,
          values.sublist(0, values.length - 1),
        ),
      );
    }
    return entries;
  }

  static SqliteIndexEntry _readInteriorEntry(List<int> page, int pointer) {
    final (length, lengthBytes) = SqliteVarint.read(page, pointer + 4);
    final values = SqliteRecordCodec.decode(
      page.sublist(
        pointer + 4 + lengthBytes,
        pointer + 4 + lengthBytes + length,
      ),
    );
    if (values.isEmpty || values.last is! int) {
      throw SqliteFormatException('index key has no rowid suffix');
    }
    return SqliteIndexEntry(
      values.last as int,
      values.sublist(0, values.length - 1),
    );
  }

  static List<int> _childPages(SqlitePagerSync pager, int rootPage) {
    final page = pager.readPage(rootPage);
    if (page[0] == 0x0a) return const [];
    if (page[0] != 0x02) {
      throw SqliteFormatException('unsupported index B-tree root page');
    }
    final count = _readU16(page, 3);
    return [
      for (var index = 0; index < count; index++)
        _readU32(page, _readU16(page, 12 + index * 2)),
      _readU32(page, 8),
    ];
  }
}

class _PackedIndexPage {
  _PackedIndexPage(this.page, this.last, this.entries);

  final Uint8List page;
  final SqliteIndexEntry last;
  final List<SqliteIndexEntry> entries;
}

int _compareKey(List<Object?> left, List<Object?> right) {
  for (var index = 0; index < left.length; index++) {
    final result = _compareValue(left[index], right[index]);
    if (result != 0) return result;
  }
  return 0;
}

int _compareValue(Object? left, Object? right) {
  if (left == null && right == null) return 0;
  if (left == null) return -1;
  if (right == null) return 1;
  if (left is num && right is num) return left.compareTo(right);
  return left.toString().compareTo(right.toString());
}

int _readU16(List<int> bytes, int offset) =>
    bytes[offset] << 8 | bytes[offset + 1];

int _readU32(List<int> bytes, int offset) =>
    bytes[offset] << 24 |
    bytes[offset + 1] << 16 |
    bytes[offset + 2] << 8 |
    bytes[offset + 3];

void _writeU16(Uint8List bytes, int offset, int value) {
  bytes[offset] = value >> 8 & 0xff;
  bytes[offset + 1] = value & 0xff;
}

void _writeU32(Uint8List bytes, int offset, int value) {
  bytes[offset] = value >> 24 & 0xff;
  bytes[offset + 1] = value >> 16 & 0xff;
  bytes[offset + 2] = value >> 8 & 0xff;
  bytes[offset + 3] = value & 0xff;
}
