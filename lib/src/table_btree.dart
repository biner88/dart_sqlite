import 'dart:typed_data';

import 'sqlite_format.dart';

class SqliteBtreeRow {
  SqliteBtreeRow(this.rowId, this.values, {this.recordOffset});

  final int rowId;
  final List<Object?> values;
  final int? recordOffset;
}

class SqliteTableBtree {
  static List<SqliteBtreeRow> readTree(
    SqlitePagerSync pager,
    int rootPage, {
    int pageStart = 0,
  }) {
    final page = pager.readPage(rootPage);
    if (page[pageStart] == 0x0d) {
      return readPage(
        page,
        pager.header.pageSize,
        pageStart: pageStart,
        pager: pager,
        pageNumber: rootPage,
      );
    }
    if (page[pageStart] != 0x05) {
      throw SqliteFormatException('unsupported table B-tree root page');
    }
    final count = _readU16(page, pageStart + 3);
    final children = <int>[];
    for (var index = 0; index < count; index++) {
      final pointer = _readU16(page, pageStart + 12 + index * 2);
      children.add(_readU32(page, pointer));
    }
    children.add(_readU32(page, pageStart + 8));
    return [
      for (final child in children)
        ...readPage(
          pager.readPage(child),
          pager.header.pageSize,
          pager: pager,
          pageNumber: child,
        ),
    ];
  }

  static void insertRow(
    SqlitePagerSync pager,
    int rootPage,
    int rowId,
    List<Object?> values, {
    int pageStart = 0,
  }) {
    final rows = readTree(pager, rootPage, pageStart: pageStart)
      ..add(SqliteBtreeRow(rowId, values))
      ..sort((a, b) => a.rowId.compareTo(b.rowId));
    rewriteRows(pager, rootPage, rows, pageStart: pageStart);
  }

  static void rewriteRows(
    SqlitePagerSync pager,
    int rootPage,
    List<SqliteBtreeRow> rows, {
    int pageStart = 0,
  }) {
    final existingChildren = _childPages(pager, rootPage, pageStart);
    final pages = _pack(rows, pager.header.pageSize, pager, pageStart);
    if (pages.length == 1) {
      for (final child in existingChildren) {
        pager.freePage(child);
      }
      pager.writePage(rootPage, pages.single);
      return;
    }

    // ponytail: rebuilds all leaves on insert; replace with incremental splits after correctness is stable.
    for (final child in existingChildren.skip(pages.length)) {
      pager.freePage(child);
    }
    final childPages = existingChildren.take(pages.length).toList();
    while (childPages.length < pages.length) {
      childPages.add(pager.allocatePage());
    }
    for (var index = 0; index < pages.length; index++) {
      pager.writePage(
        childPages[index],
        pageStart == 0 || index > 0
            ? pages[index]
            : _movePageHeader(pages[index], pageStart),
      );
    }
    pager.writePage(
      rootPage,
      _interiorPage(pager.header.pageSize, childPages, pages, pageStart),
    );
  }

  static void freeTree(
    SqlitePagerSync pager,
    int rootPage, {
    int pageStart = 0,
  }) {
    final children = _childPages(pager, rootPage, pageStart);
    final leaves = children.isEmpty ? [rootPage] : children;
    final pages = <int>{rootPage, ...children};
    for (final leaf in leaves) {
      final page = pager.readPage(leaf);
      final count = _readU16(page, pageStart + 3);
      for (var index = 0; index < count; index++) {
        final pointer = _readU16(page, pageStart + 8 + index * 2);
        final (payloadLength, payloadHeaderLength) = SqliteVarint.read(
          page,
          pointer,
        );
        final (_, rowIdLength) = SqliteVarint.read(
          page,
          pointer + payloadHeaderLength,
        );
        final payloadStart = pointer + payloadHeaderLength + rowIdLength;
        final localLength = _localPayloadLength(
          payloadLength,
          pager.header.pageSize,
        );
        if (payloadLength == localLength) continue;
        var next = _readU32(page, payloadStart + localLength);
        var remaining = payloadLength - localLength;
        while (remaining > 0) {
          if (next < 2 || next > pager.pageCount || !pages.add(next)) {
            throw SqliteFormatException('invalid overflow page: $next');
          }
          final overflow = pager.readPage(next);
          final used = remaining.clamp(0, pager.header.pageSize - 4);
          remaining -= used;
          next = _readU32(overflow, 0);
        }
      }
    }
    for (final page in pages) {
      pager.freePage(page);
    }
  }

  static void rewriteLeafPage(
    SqlitePagerSync pager,
    int rootPage,
    List<SqliteBtreeRow> rows, {
    int pageStart = 0,
  }) {
    final page = pager.readPage(rootPage);
    page.fillRange(pageStart, page.length, 0);
    page[pageStart] = 0x0d;
    _writeU16(
      page,
      pageStart + 5,
      pager.header.pageSize == 65536 ? 0 : pager.header.pageSize,
    );
    var rewritten = page;
    for (final row in rows) {
      rewritten = insert(
        rewritten,
        pager.header.pageSize,
        row.rowId,
        row.values,
        pageStart: pageStart,
      );
    }
    pager.writePage(rootPage, rewritten);
  }

  static Uint8List emptyPage(int pageSize, {int pageStart = 0}) {
    final page = Uint8List(pageSize);
    page[pageStart] = 0x0d;
    _writeU16(page, pageStart + 5, pageSize == 65536 ? 0 : pageSize);
    return page;
  }

  static List<SqliteBtreeRow> readPage(
    List<int> page,
    int pageSize, {
    int pageStart = 0,
    SqlitePagerSync? pager,
    int? pageNumber,
  }) {
    if (page[pageStart] != 0x0d) {
      throw SqliteFormatException('expected a table leaf B-tree page');
    }
    final count = _readU16(page, pageStart + 3);
    final rows = <SqliteBtreeRow>[];
    for (var index = 0; index < count; index++) {
      final pointer = _readU16(page, pageStart + 8 + index * 2);
      final (payloadLength, payloadHeaderLength) = SqliteVarint.read(
        page,
        pointer,
      );
      final (rowId, rowIdLength) = SqliteVarint.read(
        page,
        pointer + payloadHeaderLength,
      );
      final start = pointer + payloadHeaderLength + rowIdLength;
      final payload = _readPayload(page, pageSize, start, payloadLength, pager);
      rows.add(
        SqliteBtreeRow(
          rowId,
          SqliteRecordCodec.decode(payload),
          recordOffset: pageNumber == null
              ? null
              : (pageNumber - 1) * pageSize + start,
        ),
      );
    }
    return rows;
  }

  static Uint8List insert(
    List<int> original,
    int pageSize,
    int rowId,
    List<Object?> values, {
    int pageStart = 0,
    SqlitePagerSync? pager,
  }) {
    final page = Uint8List.fromList(original);
    if (page[pageStart] != 0x0d) {
      throw SqliteFormatException('expected a table leaf B-tree page');
    }
    final record = SqliteRecordCodec.encode(values);
    final localLength = _localPayloadLength(record.length, pageSize);
    if (record.length > localLength && pager == null) {
      throw SqliteFormatException('large table cell needs a pager');
    }
    final cell = <int>[]
      ..addAll(SqliteVarint.encode(record.length))
      ..addAll(SqliteVarint.encode(rowId))
      ..addAll(record.sublist(0, localLength));
    if (record.length > localLength) {
      cell.addAll(
        _u32Bytes(
          _writeOverflow(pager!, record.sublist(localLength), pageSize),
        ),
      );
    }
    final count = _readU16(page, pageStart + 3);
    final contentStart = _readU16(page, pageStart + 5);
    final actualContentStart = contentStart == 0 ? 65536 : contentStart;
    final newContentStart = actualContentStart - cell.length;
    final pointerEnd = pageStart + 8 + (count + 1) * 2;
    if (newContentStart < pointerEnd) {
      // ponytail: single-leaf tables only; add page split and overflow pages here.
      throw SqliteFormatException('table B-tree page is full');
    }
    page.setRange(newContentStart, actualContentStart, cell);
    _writeU16(page, pageStart + 8 + count * 2, newContentStart);
    _writeU16(page, pageStart + 3, count + 1);
    _writeU16(
      page,
      pageStart + 5,
      newContentStart == 65536 ? 0 : newContentStart,
    );
    return page;
  }

  static List<Uint8List> _pack(
    List<SqliteBtreeRow> rows,
    int pageSize,
    SqlitePagerSync pager,
    int pageStart,
  ) {
    final pages = <Uint8List>[];
    var start = pageStart;
    var page = emptyPage(pageSize, pageStart: start);
    for (final row in rows) {
      try {
        page = insert(
          page,
          pageSize,
          row.rowId,
          row.values,
          pageStart: start,
          pager: pager,
        );
      } on SqliteFormatException {
        if (_readU16(page, start + 3) == 0) rethrow;
        pages.add(page);
        start = 0;
        page = insert(
          emptyPage(pageSize),
          pageSize,
          row.rowId,
          row.values,
          pager: pager,
        );
      }
    }
    pages.add(page);
    return pages;
  }

  static List<int> _childPages(
    SqlitePagerSync pager,
    int rootPage,
    int pageStart,
  ) {
    final page = pager.readPage(rootPage);
    if (page[pageStart] == 0x0d) return const [];
    if (page[pageStart] != 0x05) {
      throw SqliteFormatException('unsupported table B-tree root page');
    }
    final count = _readU16(page, pageStart + 3);
    return [
      for (var index = 0; index < count; index++)
        _readU32(page, _readU16(page, pageStart + 12 + index * 2)),
      _readU32(page, pageStart + 8),
    ];
  }

  static Uint8List _interiorPage(
    int pageSize,
    List<int> childPages,
    List<Uint8List> leafPages,
    int pageStart,
  ) {
    final page = Uint8List(pageSize);
    page[pageStart] = 0x05;
    _writeU32(page, pageStart + 8, childPages.last);
    var contentStart = pageSize;
    for (var index = 0; index < childPages.length - 1; index++) {
      final maxRowId = _maxRowId(leafPages[index], index == 0 ? pageStart : 0);
      final cell = Uint8List(4 + SqliteVarint.encode(maxRowId).length);
      _writeU32(cell, 0, childPages[index]);
      cell.setRange(4, cell.length, SqliteVarint.encode(maxRowId));
      contentStart -= cell.length;
      page.setRange(contentStart, contentStart + cell.length, cell);
      _writeU16(page, pageStart + 12 + index * 2, contentStart);
    }
    _writeU16(page, pageStart + 3, childPages.length - 1);
    _writeU16(page, pageStart + 5, contentStart == 65536 ? 0 : contentStart);
    return page;
  }

  static Uint8List _movePageHeader(List<int> page, int sourceStart) {
    final result = Uint8List.fromList(page);
    final headerLength = 8 + _readU16(page, sourceStart + 3) * 2;
    result.setRange(
      0,
      headerLength,
      page.sublist(sourceStart, sourceStart + headerLength),
    );
    return result;
  }

  static int _maxRowId(List<int> page, [int pageStart = 0]) {
    final count = _readU16(page, pageStart + 3);
    if (count == 0) throw SqliteFormatException('empty table B-tree leaf');
    final pointer = _readU16(page, pageStart + 8 + (count - 1) * 2);
    final (_, payloadHeaderLength) = SqliteVarint.read(page, pointer);
    return SqliteVarint.read(page, pointer + payloadHeaderLength).$1;
  }

  static int _localPayloadLength(int payloadLength, int pageSize) {
    final maxLocal = pageSize - 35;
    final minLocal = ((pageSize - 12) * 32 ~/ 255) - 23;
    if (payloadLength <= maxLocal) return payloadLength;
    final local = minLocal + (payloadLength - minLocal) % (pageSize - 4);
    return local > maxLocal ? minLocal : local;
  }

  static List<int> _readPayload(
    List<int> page,
    int pageSize,
    int start,
    int payloadLength,
    SqlitePagerSync? pager,
  ) {
    final localLength = _localPayloadLength(payloadLength, pageSize);
    final end = start + localLength;
    if (end > page.length) throw SqliteFormatException('truncated B-tree cell');
    final result = <int>[...page.sublist(start, end)];
    if (payloadLength == localLength) return result;
    if (pager == null || end + 4 > page.length) {
      throw SqliteFormatException('table cell has no overflow pager');
    }
    var next = _readU32(page, end);
    while (result.length < payloadLength) {
      if (next < 2 || next > pager.pageCount) {
        throw SqliteFormatException('invalid overflow page: $next');
      }
      final overflow = pager.readPage(next);
      final take = (payloadLength - result.length).clamp(0, pageSize - 4);
      result.addAll(overflow.sublist(4, 4 + take));
      next = _readU32(overflow, 0);
    }
    return result;
  }

  static int _writeOverflow(
    SqlitePagerSync pager,
    List<int> payload,
    int pageSize,
  ) {
    final count = (payload.length + pageSize - 5) ~/ (pageSize - 4);
    final pages = [
      for (var index = 0; index < count; index++) pager.allocatePage(),
    ];
    for (var index = 0; index < pages.length; index++) {
      final start = index * (pageSize - 4);
      final end = (start + pageSize - 4).clamp(start, payload.length);
      final page = Uint8List(pageSize);
      if (index + 1 < pages.length) _writeU32(page, 0, pages[index + 1]);
      page.setRange(4, 4 + end - start, payload.sublist(start, end));
      pager.writePage(pages[index], page);
    }
    return pages.first;
  }
}

int _readU16(List<int> bytes, int offset) =>
    bytes[offset] << 8 | bytes[offset + 1];

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

int _readU32(List<int> bytes, int offset) =>
    bytes[offset] << 24 |
    bytes[offset + 1] << 16 |
    bytes[offset + 2] << 8 |
    bytes[offset + 3];

List<int> _u32Bytes(int value) => [
  value >> 24 & 0xff,
  value >> 16 & 0xff,
  value >> 8 & 0xff,
  value & 0xff,
];
