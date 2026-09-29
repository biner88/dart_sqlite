import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const _sqliteMagic = 'SQLite format 3\x00';
const _legacyJournalMagic = 'PURE_SQLITE_JOURNAL_V1';
const _rollbackJournalMagic = [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7];
const _journalSectorSize = 512;

class SqliteFormatException implements Exception {
  SqliteFormatException(this.message);

  final String message;

  @override
  String toString() => 'SqliteFormatException: $message';
}

class SqliteDatabaseHeader {
  SqliteDatabaseHeader({
    required this.pageSize,
    this.writeVersion = 1,
    this.readVersion = 1,
    this.reservedBytes = 0,
    this.firstFreelistTrunkPage = 0,
    this.freelistPageCount = 0,
    this.databaseSizeInPages = 1,
    this.schemaCookie = 1,
    this.schemaFormat = 4,
    this.textEncoding = 1,
    this.userVersion = 0,
    this.applicationId = 0,
    this.versionValidFor = 0,
    this.sqliteVersion = 0,
  }) {
    _validatePageSize(pageSize);
    if (databaseSizeInPages < 1) {
      throw SqliteFormatException('database must contain at least one page');
    }
  }

  factory SqliteDatabaseHeader.create({int pageSize = 4096}) =>
      SqliteDatabaseHeader(pageSize: pageSize);

  factory SqliteDatabaseHeader.fromBytes(List<int> bytes) {
    if (bytes.length < 100) {
      throw SqliteFormatException('database header is shorter than 100 bytes');
    }
    if (utf8.decode(bytes.sublist(0, 16), allowMalformed: true) !=
        _sqliteMagic) {
      throw SqliteFormatException('not a SQLite 3 database');
    }
    final encodedPageSize = _readU16(bytes, 16);
    final pageSize = encodedPageSize == 1 ? 65536 : encodedPageSize;
    _validatePageSize(pageSize);
    final header = SqliteDatabaseHeader(
      pageSize: pageSize,
      writeVersion: bytes[18],
      readVersion: bytes[19],
      reservedBytes: bytes[20],
      firstFreelistTrunkPage: _readU32(bytes, 32),
      freelistPageCount: _readU32(bytes, 36),
      databaseSizeInPages: _readU32(bytes, 28),
      schemaCookie: _readU32(bytes, 40),
      schemaFormat: _readU32(bytes, 44),
      textEncoding: _readU32(bytes, 56),
      userVersion: _readU32(bytes, 60),
      applicationId: _readU32(bytes, 68),
      versionValidFor: _readU32(bytes, 92),
      sqliteVersion: _readU32(bytes, 96),
    );
    if (header.databaseSizeInPages == 0) {
      throw SqliteFormatException('database page count is zero');
    }
    return header;
  }

  int pageSize;
  int writeVersion;
  int readVersion;
  int reservedBytes;
  int firstFreelistTrunkPage;
  int freelistPageCount;
  int databaseSizeInPages;
  int schemaCookie;
  int schemaFormat;
  int textEncoding;
  int userVersion;
  int applicationId;
  int versionValidFor;
  int sqliteVersion;

  Uint8List toBytes() {
    final bytes = Uint8List(100);
    bytes.setRange(0, 16, utf8.encode(_sqliteMagic));
    _writeU16(bytes, 16, pageSize == 65536 ? 1 : pageSize);
    bytes[18] = writeVersion;
    bytes[19] = readVersion;
    bytes[20] = reservedBytes;
    bytes[21] = 64;
    bytes[22] = 32;
    bytes[23] = 32;
    _writeU32(bytes, 24, 1);
    _writeU32(bytes, 28, databaseSizeInPages);
    _writeU32(bytes, 32, firstFreelistTrunkPage);
    _writeU32(bytes, 36, freelistPageCount);
    _writeU32(bytes, 40, schemaCookie);
    _writeU32(bytes, 44, schemaFormat);
    _writeU32(bytes, 56, textEncoding);
    _writeU32(bytes, 60, userVersion);
    _writeU32(bytes, 68, applicationId);
    _writeU32(bytes, 92, versionValidFor);
    _writeU32(bytes, 96, sqliteVersion);
    return bytes;
  }
}

class SqliteVarint {
  static List<int> encode(int value) {
    final bytes = Uint8List(9);
    final length = write(value, bytes, 0);
    return bytes.sublist(0, length);
  }

  static int write(int value, Uint8List target, int offset) {
    // ponytail: non-negative varints cover record headers and current rowids;
    // add signed rowid encoding when B-tree mutation supports negative rowids.
    if (value < 0) {
      throw SqliteFormatException('negative varints are not supported yet');
    }
    var unsigned = value;
    if (unsigned > (1 << 63) - 1) {
      throw SqliteFormatException('varint is outside signed 64-bit range');
    }
    if (unsigned > 0x00ffffffffffffff) {
      for (var index = 7; index >= 0; index--) {
        target[offset + index] = 0x80 | (unsigned & 0x7f);
        unsigned >>= 7;
      }
      target[offset + 8] = unsigned & 0xff;
      return 9;
    }
    final reversed = <int>[];
    do {
      reversed.add(unsigned & 0x7f);
      unsigned >>= 7;
    } while (unsigned != 0);
    for (var index = 0; index < reversed.length; index++) {
      final last = index == reversed.length - 1;
      target[offset + index] =
          reversed[reversed.length - index - 1] | (last ? 0 : 0x80);
    }
    return reversed.length;
  }

  static (int value, int length) read(List<int> bytes, [int offset = 0]) {
    var value = 0;
    for (var index = 0; index < 9; index++) {
      final position = offset + index;
      if (position >= bytes.length) {
        throw SqliteFormatException('truncated varint');
      }
      final byte = bytes[position];
      if (index == 8) {
        value = (value << 8) | byte;
        if (value & (1 << 63) != 0) value -= (1 << 64);
        return (value, 9);
      }
      value = (value << 7) | (byte & 0x7f);
      if ((byte & 0x80) == 0) return (value, index + 1);
    }
    throw SqliteFormatException('invalid varint');
  }
}

class SqliteRecordCodec {
  static Uint8List encode(List<Object?> values) {
    final serialTypes = <int>[];
    final bodies = <List<int>>[];
    for (final value in values) {
      final encoded = _encodeValue(value);
      serialTypes.add(encoded.$1);
      bodies.add(encoded.$2);
    }
    final serialBytes = <int>[];
    for (final type in serialTypes) {
      serialBytes.addAll(SqliteVarint.encode(type));
    }
    var headerSize = serialBytes.length + 1;
    while (SqliteVarint.encode(headerSize).length + serialBytes.length !=
        headerSize) {
      headerSize = SqliteVarint.encode(headerSize).length + serialBytes.length;
    }
    final result = BytesBuilder();
    result.add(SqliteVarint.encode(headerSize));
    result.add(serialBytes);
    for (final body in bodies) {
      result.add(body);
    }
    return result.takeBytes();
  }

  static List<Object?> decode(List<int> bytes) {
    final (headerSize, headerLength) = SqliteVarint.read(bytes);
    if (headerSize < headerLength || headerSize > bytes.length) {
      throw SqliteFormatException('invalid record header size');
    }
    final serialTypes = <int>[];
    var offset = headerLength;
    while (offset < headerSize) {
      final (type, length) = SqliteVarint.read(bytes, offset);
      serialTypes.add(type);
      offset += length;
    }
    final values = <Object?>[];
    for (final type in serialTypes) {
      if (type == 0) {
        values.add(null);
      } else if (type == 8 || type == 9) {
        values.add(type - 8);
      } else if (type == 7) {
        values.add(_readDouble(bytes, offset));
        offset += 8;
      } else if (type >= 12) {
        final length = (type - (type.isEven ? 12 : 13)) ~/ 2;
        if (offset + length > bytes.length)
          throw SqliteFormatException('truncated record value');
        final value = bytes.sublist(offset, offset + length);
        values.add(
          type.isEven ? Uint8List.fromList(value) : utf8.decode(value),
        );
        offset += length;
      } else if (type >= 1 && type <= 6) {
        final length = const [0, 1, 2, 3, 4, 6, 8][type];
        if (offset + length > bytes.length)
          throw SqliteFormatException('truncated integer value');
        values.add(_readSigned(bytes, offset, length));
        offset += length;
      } else {
        throw SqliteFormatException('reserved record serial type: $type');
      }
    }
    if (offset != bytes.length)
      throw SqliteFormatException('trailing record bytes');
    return values;
  }
}

class SqlitePager {
  SqlitePager._(this._path, this.header, this._pageCount);

  final String _path;
  final SqliteDatabaseHeader header;
  int _pageCount;

  static Future<SqlitePager> open(String path, {int pageSize = 4096}) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    if (!await file.exists()) await file.create();
    if (await file.length() == 0) {
      final header = SqliteDatabaseHeader.create(pageSize: pageSize);
      final page = Uint8List(pageSize);
      page.setRange(0, 100, header.toBytes());
      page[100] = 0x0d;
      _writeU16(page, 105, pageSize == 65536 ? 0 : pageSize);
      await file.writeAsBytes(page, flush: true);
      return SqlitePager._(path, header, 1);
    }
    final rawFile = await file.readAsBytes();
    final rawHeader = rawFile.sublist(0, 100);
    final header = SqliteDatabaseHeader.fromBytes(rawHeader);
    final length = rawFile.length;
    if (length % header.pageSize != 0) {
      throw SqliteFormatException(
        'database file is not a whole number of pages',
      );
    }
    final pageCount = length ~/ header.pageSize;
    if (pageCount != header.databaseSizeInPages) {
      throw SqliteFormatException(
        'header page count does not match file length',
      );
    }
    return SqlitePager._(path, header, pageCount);
  }

  int get pageCount => _pageCount;

  Future<Uint8List> readPage(int pageNumber) async {
    _checkPage(pageNumber);
    final bytes = await File(_path).readAsBytes();
    final start = (pageNumber - 1) * header.pageSize;
    return Uint8List.fromList(bytes.sublist(start, start + header.pageSize));
  }

  // ponytail: no journal or lock protocol yet; add rollback recovery before exposing concurrent writes.
  Future<void> writePage(int pageNumber, List<int> bytes) async {
    if (pageNumber < 1 || bytes.length != header.pageSize) {
      throw SqliteFormatException('page write has invalid size or number');
    }
    if (pageNumber > _pageCount) {
      _pageCount = pageNumber;
      header.databaseSizeInPages = _pageCount;
    }
    final file = File(_path);
    final old = await file.readAsBytes();
    final all = Uint8List(_pageCount * header.pageSize);
    all.setRange(0, old.length, old);
    all.setRange(
      (pageNumber - 1) * header.pageSize,
      pageNumber * header.pageSize,
      bytes,
    );
    all.setRange(0, 100, header.toBytes());
    await file.writeAsBytes(all, flush: true);
  }

  Future<void> close() async {}

  void _checkPage(int pageNumber) {
    if (pageNumber < 1 || pageNumber > _pageCount) {
      throw SqliteFormatException('page out of range: $pageNumber');
    }
  }
}

/// Synchronous VM pager used by the current synchronous database API.
class SqlitePagerSync {
  SqlitePagerSync._(
    this._path,
    this.header,
    this._pageCount,
    this._databaseFile,
    this._busyTimeout,
  ) : _walMode = header.writeVersion == 2 && header.readVersion == 2;

  final String _path;
  SqliteDatabaseHeader header;
  final _DatabaseFile _databaseFile;
  Duration _busyTimeout;
  Duration get busyTimeout => _busyTimeout;
  set busyTimeout(Duration value) {
    if (value.isNegative) throw ArgumentError.value(value, 'busyTimeout');
    _busyTimeout = value;
  }

  int _pageCount;
  bool _walMode;
  SqliteWalSnapshot? _walSnapshot;
  Map<int, Uint8List>? _pendingWalPages;
  var _hasExclusiveLock = false;
  var _hasSharedLock = false;
  var _hasWalWriterLock = false;
  var _closed = false;

  static final Map<String, _DatabaseFile> _databaseFiles = {};

  static SqlitePagerSync open(
    String path, {
    int pageSize = 4096,
    Duration busyTimeout = Duration.zero,
  }) {
    if (busyTimeout.isNegative) {
      throw ArgumentError.value(busyTimeout, 'busyTimeout');
    }
    final absolutePath = File(path).absolute.path;
    final file = File(absolutePath);
    file.parent.createSync(recursive: true);
    final databaseFile = _databaseFiles.putIfAbsent(
      absolutePath,
      () => _DatabaseFile(absolutePath),
    );
    databaseFile.references++;
    final owner = Object();
    try {
      final existing = databaseFile.readAll();
      final header = existing.length >= 100
          ? SqliteDatabaseHeader.fromBytes(existing.sublist(0, 100))
          : null;
      final walCandidate =
          header?.writeVersion == 2 &&
          header?.readVersion == 2 &&
          !File('$absolutePath-journal').existsSync() &&
          !File('$absolutePath.pure-journal').existsSync();
      if (walCandidate) {
        databaseFile.acquireShared(owner, busyTimeout);
      } else {
        databaseFile.acquireExclusive(owner, busyTimeout);
      }
      try {
        if (!walCandidate) {
          SqliteRollbackJournal.recover(
            absolutePath,
            databaseHandle: databaseFile.handle,
          );
        }
        final bytes = databaseFile.readAll();
        if (bytes.isEmpty) {
          final header = SqliteDatabaseHeader.create(pageSize: pageSize);
          final page = Uint8List(pageSize);
          page.setRange(0, 100, header.toBytes());
          page[100] = 0x0d;
          _writeU16(page, 105, pageSize == 65536 ? 0 : pageSize);
          databaseFile.writeAll(page);
          return SqlitePagerSync._(
            absolutePath,
            header,
            1,
            databaseFile,
            busyTimeout,
          );
        }
        final header = SqliteDatabaseHeader.fromBytes(bytes.sublist(0, 100));
        if ((header.writeVersion == 2) != (header.readVersion == 2) ||
            (header.writeVersion != 1 && header.writeVersion != 2) ||
            (header.readVersion != 1 && header.readVersion != 2)) {
          throw SqliteFormatException('unsupported SQLite journal mode');
        }
        if (bytes.length % header.pageSize != 0) {
          throw SqliteFormatException(
            'database file is not a whole number of pages',
          );
        }
        final pageCount = bytes.length ~/ header.pageSize;
        if (pageCount != header.databaseSizeInPages) {
          throw SqliteFormatException(
            'header page count does not match file length',
          );
        }
        if (header.writeVersion != 2) {
          final staleWal = File(SqliteWal.pathFor(absolutePath));
          if (staleWal.existsSync()) staleWal.deleteSync();
        }
        return SqlitePagerSync._(
          absolutePath,
          header,
          pageCount,
          databaseFile,
          busyTimeout,
        );
      } finally {
        databaseFile.release(owner);
      }
    } catch (_) {
      databaseFile.releaseReference();
      rethrow;
    }
  }

  int get pageCount => _pageCount;

  bool get isWalMode => _walMode;

  String get path => _path;

  RandomAccessFile get databaseHandle => _databaseFile.handle;

  Uint8List readPage(int pageNumber) {
    _checkPage(pageNumber);
    final pending = _pendingWalPages?[pageNumber];
    if (pending != null) return Uint8List.fromList(pending);
    final walPage = _walSnapshot?.pages[pageNumber];
    if (walPage != null) return Uint8List.fromList(walPage);
    final bytes = _databaseFile.readAll();
    final start = (pageNumber - 1) * header.pageSize;
    return Uint8List.fromList(bytes.sublist(start, start + header.pageSize));
  }

  void refresh() {
    final bytes = _databaseFile.readAll();
    if (bytes.length < 100) {
      throw SqliteFormatException('database is shorter than its header');
    }
    final diskHeader = SqliteDatabaseHeader.fromBytes(bytes.sublist(0, 100));
    if (bytes.length % diskHeader.pageSize != 0 ||
        bytes.length ~/ diskHeader.pageSize != diskHeader.databaseSizeInPages) {
      throw SqliteFormatException('database size does not match its header');
    }
    if (diskHeader.writeVersion == 2 && diskHeader.readVersion == 2) {
      final snapshot = SqliteWal.read(
        _path,
        pageSize: diskHeader.pageSize,
        databaseSize: diskHeader.databaseSizeInPages,
      );
      final pageOne =
          snapshot.pages[1] ??
          Uint8List.fromList(bytes.sublist(0, diskHeader.pageSize));
      final nextHeader = SqliteDatabaseHeader.fromBytes(
        pageOne.sublist(0, 100),
      );
      if (nextHeader.writeVersion != 2 || nextHeader.readVersion != 2) {
        throw SqliteFormatException('WAL page has an invalid database header');
      }
      header = nextHeader;
      _pageCount = snapshot.databaseSize;
      header.databaseSizeInPages = _pageCount;
      _walSnapshot = snapshot;
      _walMode = true;
    } else {
      header = diskHeader;
      _pageCount = diskHeader.databaseSizeInPages;
      _walSnapshot = null;
      _walMode = false;
    }
  }

  void acquireWalWriterLock() {
    if (!_walMode) throw StateError('WAL writer lock requires WAL mode');
    if (_hasWalWriterLock) return;
    _databaseFile.acquireWalWriter(this, busyTimeout);
    _hasWalWriterLock = true;
  }

  void releaseWalWriterLock() {
    if (!_hasWalWriterLock) return;
    _hasWalWriterLock = false;
    _databaseFile.releaseWalWriter(this);
  }

  void beginWalTransaction() {
    if (!_walMode || !_hasWalWriterLock || _pendingWalPages != null) {
      throw StateError('cannot begin WAL transaction');
    }
    _pendingWalPages = {};
  }

  void commitWalTransaction() {
    final pending = _pendingWalPages;
    if (pending == null) throw StateError('no WAL transaction is active');
    if (pending.isEmpty) {
      _pendingWalPages = null;
      return;
    }
    SqliteWal.append(
      _path,
      pageSize: header.pageSize,
      databaseSize: _pageCount,
      pages: pending,
    );
    _pendingWalPages = null;
    refresh();
  }

  void rollbackWalTransaction() {
    if (_pendingWalPages == null) return;
    _pendingWalPages = null;
    refresh();
  }

  void enableWalMode() {
    if (_walMode) return;
    final pageOne = readPage(1);
    header
      ..writeVersion = 2
      ..readVersion = 2;
    pageOne.setRange(0, 100, header.toBytes());
    SqliteWal.initialize(_path, header.pageSize);
    _writePage(1, pageOne);
    refresh();
  }

  void disableWalMode() {
    if (!_walMode) return;
    final snapshot = SqliteWal.read(
      _path,
      pageSize: header.pageSize,
      databaseSize: header.databaseSizeInPages,
    );
    final journal = SqliteRollbackJournal.begin(
      _path,
      databaseHandle: databaseHandle,
    );
    try {
      final pageCount = snapshot.databaseSize;
      final original = _databaseFile.readAll();
      final database = Uint8List(pageCount * header.pageSize);
      database.setRange(0, min(original.length, database.length), original);
      for (final entry in snapshot.pages.entries) {
        final start = (entry.key - 1) * header.pageSize;
        database.setRange(start, start + header.pageSize, entry.value);
      }
      final nextHeader = SqliteDatabaseHeader.fromBytes(
        database.sublist(0, 100),
      )..databaseSizeInPages = pageCount;
      nextHeader
        ..writeVersion = 1
        ..readVersion = 1;
      database.setRange(0, 100, nextHeader.toBytes());
      _databaseFile.writeAll(database);
      journal.commit();
      final wal = File(SqliteWal.pathFor(_path));
      if (wal.existsSync()) wal.deleteSync();
      refresh();
    } catch (_) {
      journal.rollback(_path, databaseHandle: databaseHandle);
      refresh();
      rethrow;
    }
  }

  T withExclusiveLock<T>(T Function() action) {
    if (_closed) throw StateError('database pager is closed');
    if (_hasExclusiveLock) return action();
    if (_hasSharedLock) {
      throw StateError('cannot upgrade a shared lock on this connection');
    }
    acquireExclusiveLock();
    try {
      return action();
    } finally {
      releaseExclusiveLock();
    }
  }

  void acquireExclusiveLock() {
    if (_closed) throw StateError('database pager is closed');
    if (_hasExclusiveLock) {
      throw StateError('database lock is already held by this connection');
    }
    _databaseFile.acquireExclusive(this, busyTimeout);
    _hasExclusiveLock = true;
  }

  void releaseExclusiveLock() {
    if (!_hasExclusiveLock) return;
    _hasExclusiveLock = false;
    _databaseFile.release(this);
  }

  T withSharedLock<T>(T Function() action) {
    if (_closed) throw StateError('database pager is closed');
    if (_hasExclusiveLock || _hasSharedLock) return action();
    acquireSharedLock();
    try {
      return action();
    } finally {
      releaseSharedLock();
    }
  }

  void acquireSharedLock() {
    if (_closed) throw StateError('database pager is closed');
    if (_hasSharedLock || _hasExclusiveLock) {
      throw StateError('database lock is already held by this connection');
    }
    _databaseFile.acquireShared(this, busyTimeout);
    _hasSharedLock = true;
  }

  void releaseSharedLock() {
    if (!_hasSharedLock) return;
    _hasSharedLock = false;
    _databaseFile.release(this);
  }

  int allocatePage() {
    final trunkPage = header.firstFreelistTrunkPage;
    if (trunkPage != 0) {
      final trunk = readPage(trunkPage);
      final leafCount = _readU32(trunk, 4);
      if (leafCount > 0) {
        final pageNumber = _readU32(trunk, 8 + (leafCount - 1) * 4);
        _writeU32(trunk, 4, leafCount - 1);
        header.freelistPageCount--;
        writePage(trunkPage, trunk);
        writePage(pageNumber, Uint8List(header.pageSize));
        return pageNumber;
      }
      header.firstFreelistTrunkPage = _readU32(trunk, 0);
      header.freelistPageCount--;
      writePage(trunkPage, Uint8List(header.pageSize));
      return trunkPage;
    }
    _pageCount++;
    header.databaseSizeInPages = _pageCount;
    writePage(_pageCount, Uint8List(header.pageSize));
    return _pageCount;
  }

  void freePage(int pageNumber) {
    if (pageNumber <= 1 || pageNumber > _pageCount) {
      throw SqliteFormatException('invalid freelist page: $pageNumber');
    }
    final trunkPage = header.firstFreelistTrunkPage;
    if (trunkPage == 0) {
      header.firstFreelistTrunkPage = pageNumber;
      header.freelistPageCount++;
      final trunk = Uint8List(header.pageSize);
      writePage(pageNumber, trunk);
      return;
    }
    final trunk = readPage(trunkPage);
    final leafCount = _readU32(trunk, 4);
    final capacity = (header.pageSize - 8) ~/ 4;
    if (leafCount < capacity) {
      _writeU32(trunk, 8 + leafCount * 4, pageNumber);
      _writeU32(trunk, 4, leafCount + 1);
      header.freelistPageCount++;
      writePage(trunkPage, trunk);
      return;
    }
    header.firstFreelistTrunkPage = pageNumber;
    header.freelistPageCount++;
    final newTrunk = Uint8List(header.pageSize);
    _writeU32(newTrunk, 0, trunkPage);
    writePage(pageNumber, newTrunk);
  }

  void writePage(int pageNumber, List<int> bytes) {
    if (pageNumber < 1 || bytes.length != header.pageSize) {
      throw SqliteFormatException('page write has invalid size or number');
    }
    if (pageNumber > _pageCount) _pageCount = pageNumber;
    header.databaseSizeInPages = _pageCount;
    if (_walMode) {
      final pending = _pendingWalPages;
      if (pending == null) {
        throw StateError('WAL page writes require an active transaction');
      }
      pending[pageNumber] = Uint8List.fromList(bytes);
      final firstPage = Uint8List.fromList(pending[1] ?? readPage(1));
      firstPage.setRange(0, 100, header.toBytes());
      pending[1] = firstPage;
    } else {
      _writePage(pageNumber, bytes);
    }
  }

  void close() {
    if (_closed) return;
    rollbackWalTransaction();
    releaseExclusiveLock();
    releaseSharedLock();
    releaseWalWriterLock();
    _databaseFile.releaseReference();
    _closed = true;
  }

  void _writePage(int pageNumber, List<int> bytes) {
    final old = _databaseFile.readAll();
    final all = Uint8List(_pageCount * header.pageSize);
    all.setRange(0, old.length, old);
    all.setRange(
      (pageNumber - 1) * header.pageSize,
      pageNumber * header.pageSize,
      bytes,
    );
    all.setRange(0, 100, header.toBytes());
    _databaseFile.writeAll(all);
  }

  void _checkPage(int pageNumber) {
    if (pageNumber < 1 || pageNumber > _pageCount) {
      throw SqliteFormatException('page out of range: $pageNumber');
    }
  }
}

class _DatabaseFile {
  _DatabaseFile(this.path)
    : handle = File(path).openSync(mode: FileMode.append);

  static const _pendingByte = 0x40000000;
  static const _reservedByte = _pendingByte + 1;
  static const _sharedFirst = _pendingByte + 2;
  static const _sharedSize = 510;

  final String path;
  final RandomAccessFile handle;
  var references = 0;
  Object? _owner;
  var _exclusive = false;
  Object? _walWriterOwner;

  Uint8List readAll() {
    final length = handle.lengthSync();
    handle.setPositionSync(0);
    return Uint8List.fromList(length == 0 ? const [] : handle.readSync(length));
  }

  void writeAll(List<int> bytes) {
    handle
      ..truncateSync(0)
      ..setPositionSync(0)
      ..writeFromSync(bytes)
      ..flushSync();
  }

  void acquireShared(Object owner, Duration timeout) =>
      _acquire(owner, timeout, exclusive: false);

  void acquireExclusive(Object owner, Duration timeout) =>
      _acquire(owner, timeout, exclusive: true);

  void acquireWalWriter(Object owner, Duration timeout) {
    final stopwatch = Stopwatch()..start();
    while (true) {
      if (_walWriterOwner == null) {
        try {
          handle.lockSync(FileLock.exclusive, _reservedByte, _reservedByte + 1);
          _walWriterOwner = owner;
          return;
        } on FileSystemException {
          // Another WAL writer owns SQLite's reserved lock byte.
        }
      }
      if (stopwatch.elapsed >= timeout) {
        throw SqliteFormatException('database is locked: $path');
      }
      final remaining = timeout - stopwatch.elapsed;
      sleep(
        remaining < const Duration(milliseconds: 10)
            ? remaining
            : const Duration(milliseconds: 10),
      );
    }
  }

  void releaseWalWriter(Object owner) {
    if (_walWriterOwner != owner) return;
    _walWriterOwner = null;
    handle.unlockSync(_reservedByte, _reservedByte + 1);
  }

  void _acquire(Object owner, Duration timeout, {required bool exclusive}) {
    final stopwatch = Stopwatch()..start();
    while (true) {
      if (_owner == null) {
        try {
          if (exclusive) {
            _lockExclusive();
          } else {
            _lockShared();
          }
          _owner = owner;
          _exclusive = exclusive;
          return;
        } on FileSystemException {
          // Another SQLite connection owns a conflicting lock; keep waiting.
        }
      }
      if (stopwatch.elapsed >= timeout) {
        throw SqliteFormatException('database is locked: $path');
      }
      final remaining = timeout - stopwatch.elapsed;
      sleep(
        remaining < const Duration(milliseconds: 10)
            ? remaining
            : const Duration(milliseconds: 10),
      );
    }
  }

  void _lockShared() {
    var pending = false;
    var shared = false;
    try {
      handle.lockSync(FileLock.shared, _pendingByte, _pendingByte + 1);
      pending = true;
      handle.lockSync(FileLock.shared, _sharedFirst, _sharedFirst + 1);
      shared = true;
      handle.unlockSync(_pendingByte, _pendingByte + 1);
    } catch (_) {
      if (shared) handle.unlockSync(_sharedFirst, _sharedFirst + 1);
      if (pending) handle.unlockSync(_pendingByte, _pendingByte + 1);
      rethrow;
    }
  }

  void _lockExclusive() {
    var reserved = false;
    var pending = false;
    var shared = false;
    try {
      handle.lockSync(FileLock.exclusive, _reservedByte, _reservedByte + 1);
      reserved = true;
      handle.lockSync(FileLock.exclusive, _pendingByte, _pendingByte + 1);
      pending = true;
      handle.lockSync(
        FileLock.exclusive,
        _sharedFirst,
        _sharedFirst + _sharedSize,
      );
      shared = true;
    } catch (_) {
      if (shared) handle.unlockSync(_sharedFirst, _sharedFirst + _sharedSize);
      if (pending) handle.unlockSync(_pendingByte, _pendingByte + 1);
      if (reserved) handle.unlockSync(_reservedByte, _reservedByte + 1);
      rethrow;
    }
  }

  void release(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    if (_exclusive) {
      handle
        ..unlockSync(_sharedFirst, _sharedFirst + _sharedSize)
        ..unlockSync(_pendingByte, _pendingByte + 1)
        ..unlockSync(_reservedByte, _reservedByte + 1);
    } else {
      handle.unlockSync(_sharedFirst, _sharedFirst + 1);
    }
    _exclusive = false;
  }

  void releaseReference() {
    references--;
    if (references == 0) {
      handle.closeSync();
      SqlitePagerSync._databaseFiles.remove(path);
    }
  }
}

class SqliteRollbackJournal {
  SqliteRollbackJournal._(this._path);

  final String _path;

  static SqliteRollbackJournal begin(
    String databasePath, {
    RandomAccessFile? databaseHandle,
  }) {
    final path = _journalPath(databasePath);
    final file = File(path);
    file.createSync(exclusive: true);
    final journal = file.openSync(mode: FileMode.append);
    try {
      final original = databaseHandle == null
          ? File(databasePath).readAsBytesSync()
          : _readAll(databaseHandle);
      if (original.length < 100) {
        throw SqliteFormatException('database is shorter than its header');
      }
      final databaseHeader = SqliteDatabaseHeader.fromBytes(
        original.sublist(0, 100),
      );
      final pageSize = databaseHeader.pageSize;
      if (original.length % pageSize != 0 ||
          original.length ~/ pageSize != databaseHeader.databaseSizeInPages) {
        throw SqliteFormatException('database size does not match its header');
      }
      final pageCount = databaseHeader.databaseSizeInPages;
      final nonce = Random.secure().nextInt(0x100000000);
      final header = Uint8List(_journalSectorSize);
      header.setRange(0, 8, _rollbackJournalMagic);
      _writeU32(header, 8, pageCount);
      _writeU32(header, 12, nonce);
      _writeU32(header, 16, pageCount);
      _writeU32(header, 20, _journalSectorSize);
      _writeU32(header, 24, pageSize);
      journal.writeFromSync(header);

      // ponytail: journal every original page; switch to first-write page
      // snapshots if the O(database size) transaction journal becomes costly.
      for (var pageNumber = 1; pageNumber <= pageCount; pageNumber++) {
        final start = (pageNumber - 1) * pageSize;
        final page = original.sublist(start, start + pageSize);
        final pageNumberBytes = Uint8List(4);
        _writeU32(pageNumberBytes, 0, pageNumber);
        final checksum = Uint8List(4);
        _writeU32(checksum, 0, _journalChecksum(page, nonce));
        journal
          ..writeFromSync(pageNumberBytes)
          ..writeFromSync(page)
          ..writeFromSync(checksum);
      }
      journal.flushSync();
    } catch (_) {
      journal.closeSync();
      if (file.existsSync()) file.deleteSync();
      rethrow;
    }
    journal.closeSync();
    return SqliteRollbackJournal._(path);
  }

  static void recover(String databasePath, {RandomAccessFile? databaseHandle}) {
    _recoverLegacyJournal(databasePath, databaseHandle);
    final file = File(_journalPath(databasePath));
    if (!file.existsSync()) return;
    final bytes = file.readAsBytesSync();
    if (bytes.length <= _journalSectorSize) {
      file.deleteSync();
      return;
    }
    if (!_hasRollbackJournalMagic(bytes, 0)) {
      throw SqliteFormatException('invalid rollback journal');
    }

    var pageSize = 0;
    var originalPageCount = 0;
    final originalPages = <int, Uint8List>{};
    var headerOffset = 0;
    while (headerOffset + 28 <= bytes.length &&
        _hasRollbackJournalMagic(bytes, headerOffset)) {
      final recordCount = _readU32(bytes, headerOffset + 8);
      final nonce = _readU32(bytes, headerOffset + 12);
      final databasePages = _readU32(bytes, headerOffset + 16);
      final sectorSize = _readU32(bytes, headerOffset + 20);
      final segmentPageSize = _readU32(bytes, headerOffset + 24);
      _validatePageSize(segmentPageSize);
      if (sectorSize < 512 ||
          sectorSize > 65536 ||
          sectorSize & (sectorSize - 1) != 0 ||
          headerOffset + sectorSize > bytes.length ||
          databasePages < 1) {
        throw SqliteFormatException('invalid rollback journal header');
      }
      if (pageSize == 0) {
        pageSize = segmentPageSize;
        originalPageCount = databasePages;
      } else if (pageSize != segmentPageSize ||
          originalPageCount != databasePages) {
        throw SqliteFormatException('inconsistent rollback journal headers');
      }

      final recordSize = pageSize + 8;
      var recordOffset = headerOffset + sectorSize;
      final recordsAvailable = (bytes.length - recordOffset) ~/ recordSize;
      final recordsToRead = recordCount == 0xffffffff
          ? recordsAvailable
          : recordCount;
      if (recordsToRead > recordsAvailable) {
        throw SqliteFormatException('truncated rollback journal records');
      }
      for (var index = 0; index < recordsToRead; index++) {
        final pageNumber = _readU32(bytes, recordOffset);
        if (pageNumber == 0 || pageNumber > originalPageCount) {
          throw SqliteFormatException('invalid rollback journal page number');
        }
        final pageStart = recordOffset + 4;
        final page = Uint8List.fromList(
          bytes.sublist(pageStart, pageStart + pageSize),
        );
        final checksum = _readU32(bytes, pageStart + pageSize);
        if (_journalChecksum(page, nonce) != checksum) {
          throw SqliteFormatException('rollback journal checksum mismatch');
        }
        originalPages.putIfAbsent(pageNumber, () => page);
        recordOffset += recordSize;
      }
      if (recordCount == 0xffffffff) break;
      final nextHeader =
          ((recordOffset + sectorSize - 1) ~/ sectorSize) * sectorSize;
      if (nextHeader >= bytes.length ||
          !_hasRollbackJournalMagic(bytes, nextHeader)) {
        break;
      }
      headerOffset = nextHeader;
    }
    if (pageSize == 0) {
      throw SqliteFormatException('invalid rollback journal header');
    }
    if (originalPages.isEmpty) {
      file.deleteSync();
      return;
    }

    final databaseFile = File(databasePath);
    final current = databaseHandle != null
        ? _readAll(databaseHandle)
        : databaseFile.existsSync()
        ? databaseFile.readAsBytesSync()
        : Uint8List(0);
    final restored = Uint8List(originalPageCount * pageSize);
    restored.setRange(0, min(current.length, restored.length), current);
    for (final entry in originalPages.entries) {
      final start = (entry.key - 1) * pageSize;
      restored.setRange(start, start + pageSize, entry.value);
    }
    final currentPages = (current.length + pageSize - 1) ~/ pageSize;
    for (var page = currentPages + 1; page <= originalPageCount; page++) {
      if (!originalPages.containsKey(page)) {
        throw SqliteFormatException('rollback journal is missing page $page');
      }
    }
    if (databaseHandle == null) {
      databaseFile.writeAsBytesSync(restored, flush: true);
    } else {
      _writeAll(databaseHandle, restored);
    }
    file.deleteSync();
  }

  static void _recoverLegacyJournal(
    String databasePath,
    RandomAccessFile? databaseHandle,
  ) {
    final file = File('$databasePath.pure-journal');
    if (!file.existsSync()) return;
    final bytes = file.readAsBytesSync();
    final magic = utf8.encode(_legacyJournalMagic);
    if (bytes.length < magic.length + 8 || !_sameBytes(bytes, magic, 0)) {
      throw SqliteFormatException('invalid legacy rollback journal');
    }
    final length = _readU64(bytes, magic.length);
    final start = magic.length + 8;
    if (length < 0 || start + length != bytes.length) {
      throw SqliteFormatException('invalid legacy rollback journal length');
    }
    if (databaseHandle == null) {
      File(databasePath).writeAsBytesSync(bytes.sublist(start), flush: true);
    } else {
      _writeAll(databaseHandle, bytes.sublist(start));
    }
    file.deleteSync();
  }

  void commit() {
    final file = File(_path);
    if (file.existsSync()) file.deleteSync();
  }

  void rollback(String databasePath, {RandomAccessFile? databaseHandle}) {
    recover(databasePath, databaseHandle: databaseHandle);
  }
}

class SqliteWalSnapshot {
  const SqliteWalSnapshot({
    required this.pages,
    required this.databaseSize,
    required this.validLength,
    required this.salt1,
    required this.salt2,
    required this.checksum,
    required this.header,
  });

  final Map<int, Uint8List> pages;
  final int databaseSize;
  final int validLength;
  final int salt1;
  final int salt2;
  final (int, int) checksum;
  final Uint8List? header;
}

/// SQLite WAL file reader/writer. The transient wal-index is rebuilt by SQLite
/// from this standard WAL when a native SQLite connection opens the database.
class SqliteWal {
  static const _magic = 0x377f0682;
  static const _version = 3007000;

  static String pathFor(String databasePath) => '$databasePath-wal';

  static SqliteWalSnapshot read(
    String databasePath, {
    required int pageSize,
    required int databaseSize,
  }) {
    final file = File(pathFor(databasePath));
    if (!file.existsSync() || file.lengthSync() == 0) {
      return SqliteWalSnapshot(
        pages: {},
        databaseSize: databaseSize,
        validLength: 0,
        salt1: 0,
        salt2: 0,
        checksum: (0, 0),
        header: null,
      );
    }
    final bytes = file.readAsBytesSync();
    if (bytes.length < 32) {
      throw SqliteFormatException('truncated SQLite WAL header');
    }
    final magic = _readU32(bytes, 0);
    if (magic != _magic && magic != 0x377f0683) {
      throw SqliteFormatException('invalid SQLite WAL magic');
    }
    final littleEndianChecksum = magic == _magic;
    if (_readU32(bytes, 4) != _version || _readU32(bytes, 8) != pageSize) {
      throw SqliteFormatException('incompatible SQLite WAL header');
    }
    final salt1 = _readU32(bytes, 16);
    final salt2 = _readU32(bytes, 20);
    final headerChecksum = _checksum(bytes, 0, 24, (
      0,
      0,
    ), littleEndian: littleEndianChecksum);
    if (headerChecksum.$1 != _readU32(bytes, 24) ||
        headerChecksum.$2 != _readU32(bytes, 28)) {
      throw SqliteFormatException('SQLite WAL header checksum mismatch');
    }

    var checksum = headerChecksum;
    var lastCommitChecksum = headerChecksum;
    var lastCommitLength = 32;
    var committedSize = databaseSize;
    final pages = <int, Uint8List>{};
    final pending = <(int, Uint8List)>[];
    final frameSize = 24 + pageSize;
    for (
      var offset = 32;
      offset + frameSize <= bytes.length;
      offset += frameSize
    ) {
      final pageNumber = _readU32(bytes, offset);
      final frameDatabaseSize = _readU32(bytes, offset + 4);
      if (pageNumber == 0 ||
          _readU32(bytes, offset + 8) != salt1 ||
          _readU32(bytes, offset + 12) != salt2) {
        break;
      }
      final page = Uint8List.fromList(
        bytes.sublist(offset + 24, offset + frameSize),
      );
      final frameChecksumBytes = Uint8List(8 + pageSize)
        ..setRange(0, 8, bytes, offset)
        ..setRange(8, 8 + pageSize, page);
      checksum = _checksum(
        frameChecksumBytes,
        0,
        frameChecksumBytes.length,
        checksum,
        littleEndian: littleEndianChecksum,
      );
      if (checksum.$1 != _readU32(bytes, offset + 16) ||
          checksum.$2 != _readU32(bytes, offset + 20)) {
        break;
      }
      pending.add((pageNumber, page));
      if (frameDatabaseSize != 0) {
        for (final frame in pending) {
          if (frame.$1 <= frameDatabaseSize) pages[frame.$1] = frame.$2;
        }
        pending.clear();
        committedSize = frameDatabaseSize;
        lastCommitLength = offset + frameSize;
        lastCommitChecksum = checksum;
      }
    }

    return SqliteWalSnapshot(
      pages: pages,
      databaseSize: committedSize,
      validLength: lastCommitLength,
      salt1: salt1,
      salt2: salt2,
      checksum: lastCommitChecksum,
      header: Uint8List.fromList(bytes.sublist(0, 32)),
    );
  }

  static void initialize(String databasePath, int pageSize) {
    final header = Uint8List(32);
    final random = Random.secure();
    final salt1 = random.nextInt(0x100000000);
    var salt2 = random.nextInt(0x100000000);
    if (salt1 == salt2) salt2 = (salt2 + 1) & 0xffffffff;
    _writeU32(header, 0, _magic);
    _writeU32(header, 4, _version);
    _writeU32(header, 8, pageSize);
    _writeU32(header, 12, 0);
    _writeU32(header, 16, salt1);
    _writeU32(header, 20, salt2);
    final checksum = _checksum(header, 0, 24, (0, 0), littleEndian: true);
    _writeU32(header, 24, checksum.$1);
    _writeU32(header, 28, checksum.$2);
    File(pathFor(databasePath)).writeAsBytesSync(header, flush: true);
  }

  static void append(
    String databasePath, {
    required int pageSize,
    required int databaseSize,
    required Map<int, Uint8List> pages,
  }) {
    if (pages.isEmpty) return;
    final path = pathFor(databasePath);
    if (!File(path).existsSync() || File(path).lengthSync() == 0) {
      initialize(databasePath, pageSize);
    }
    final snapshot = read(
      databasePath,
      pageSize: pageSize,
      databaseSize: databaseSize,
    );
    final header = snapshot.header;
    if (header == null)
      throw SqliteFormatException('missing SQLite WAL header');
    final salt1 = _readU32(header, 16);
    final salt2 = _readU32(header, 20);
    final littleEndianChecksum = _readU32(header, 0) == _magic;
    var checksum = snapshot.checksum;
    final frames = BytesBuilder(copy: false);
    final entries = pages.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final frameHeader = Uint8List(24);
      _writeU32(frameHeader, 0, entry.key);
      _writeU32(frameHeader, 4, index == entries.length - 1 ? databaseSize : 0);
      _writeU32(frameHeader, 8, salt1);
      _writeU32(frameHeader, 12, salt2);
      final checksumBytes = Uint8List(8 + pageSize)
        ..setRange(0, 8, frameHeader)
        ..setRange(8, 8 + pageSize, entry.value);
      checksum = _checksum(
        checksumBytes,
        0,
        checksumBytes.length,
        checksum,
        littleEndian: littleEndianChecksum,
      );
      _writeU32(frameHeader, 16, checksum.$1);
      _writeU32(frameHeader, 20, checksum.$2);
      frames
        ..add(frameHeader)
        ..add(entry.value);
    }

    final wal = File(path).openSync(mode: FileMode.append);
    try {
      wal
        ..truncateSync(snapshot.validLength)
        ..setPositionSync(snapshot.validLength)
        ..writeFromSync(frames.takeBytes())
        ..flushSync();
    } finally {
      wal.closeSync();
    }
  }

  static (int, int) _checksum(
    List<int> bytes,
    int start,
    int end,
    (int, int) previous, {
    required bool littleEndian,
  }) {
    if ((end - start) % 8 != 0) {
      throw ArgumentError('WAL checksum input must be divisible by 8');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes), start, end);
    var sum0 = previous.$1;
    var sum1 = previous.$2;
    final endian = littleEndian ? Endian.little : Endian.big;
    for (var offset = 0; offset < data.lengthInBytes; offset += 8) {
      sum0 = (sum0 + data.getUint32(offset, endian) + sum1) & 0xffffffff;
      sum1 = (sum1 + data.getUint32(offset + 4, endian) + sum0) & 0xffffffff;
    }
    return (sum0, sum1);
  }
}

Uint8List _readAll(RandomAccessFile handle) {
  final length = handle.lengthSync();
  handle.setPositionSync(0);
  return Uint8List.fromList(length == 0 ? const [] : handle.readSync(length));
}

void _writeAll(RandomAccessFile handle, List<int> bytes) {
  handle
    ..truncateSync(0)
    ..setPositionSync(0)
    ..writeFromSync(bytes)
    ..flushSync();
}

(int, List<int>) _encodeValue(Object? value) {
  if (value == null) return (0, const []);
  if (value is bool) value = value ? 1 : 0;
  if (value is int) {
    if (value == 0) return (8, const []);
    if (value == 1) return (9, const []);
    final length = value >= -128 && value <= 127
        ? 1
        : value >= -32768 && value <= 32767
        ? 2
        : value >= -8388608 && value <= 8388607
        ? 3
        : value >= -2147483648 && value <= 2147483647
        ? 4
        : value >= -140737488355328 && value <= 140737488355327
        ? 6
        : 8;
    return (
      const [0, 1, 2, 3, 4, 6, 8].indexOf(length),
      _signedBytes(value, length),
    );
  }
  if (value is double) {
    final data = ByteData(8)..setFloat64(0, value, Endian.big);
    return (7, data.buffer.asUint8List());
  }
  if (value is String) {
    final bytes = utf8.encode(value);
    return (13 + bytes.length * 2, bytes);
  }
  if (value is List<int>) {
    return (12 + value.length * 2, value);
  }
  throw SqliteFormatException('unsupported record value: ${value.runtimeType}');
}

List<int> _signedBytes(int value, int length) {
  final result = Uint8List(length);
  var unsigned = value < 0 ? value + (1 << (length * 8)) : value;
  for (var index = length - 1; index >= 0; index--) {
    result[index] = unsigned & 0xff;
    unsigned >>= 8;
  }
  return result;
}

int _readSigned(List<int> bytes, int offset, int length) {
  var value = 0;
  for (var index = 0; index < length; index++)
    value = value * 256 + bytes[offset + index];
  if (bytes[offset] & 0x80 != 0) value -= 1 << (length * 8);
  return value;
}

double _readDouble(List<int> bytes, int offset) => ByteData.sublistView(
  Uint8List.fromList(bytes),
  offset,
  offset + 8,
).getFloat64(0, Endian.big);

void _validatePageSize(int pageSize) {
  if (pageSize != 65536 &&
      (pageSize < 512 || pageSize > 32768 || pageSize & (pageSize - 1) != 0)) {
    throw SqliteFormatException('invalid SQLite page size: $pageSize');
  }
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

String _journalPath(String databasePath) => '$databasePath-journal';

int _readU64(List<int> bytes, int offset) =>
    (_readU32(bytes, offset) << 32) | _readU32(bytes, offset + 4);

bool _hasRollbackJournalMagic(List<int> bytes, int offset) =>
    offset >= 0 &&
    offset + _rollbackJournalMagic.length <= bytes.length &&
    _sameBytes(bytes, _rollbackJournalMagic, offset);

int _journalChecksum(List<int> page, int nonce) {
  var checksum = nonce;
  for (var offset = page.length - 200; offset >= 0; offset -= 200) {
    checksum = (checksum + page[offset]) & 0xffffffff;
  }
  return checksum;
}

bool _sameBytes(List<int> bytes, List<int> expected, int offset) {
  for (var index = 0; index < expected.length; index++) {
    if (bytes[offset + index] != expected[index]) return false;
  }
  return true;
}
