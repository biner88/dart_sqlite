/// A deliberately small, dependency-free, SQLite-compatible subset.
///
/// It supports an in-memory SQL engine and a growing, partially compatible
/// SQLite 3 file format.
library;

import 'src/sqlite_format.dart';
import 'src/table_btree.dart';
import 'src/index_btree.dart';

export 'src/sqlite_format.dart';
export 'src/table_btree.dart';
export 'src/index_btree.dart';

typedef SqlRow = Map<String, Object?>;

class SqliteException implements Exception {
  SqliteException(this.message);

  final String message;

  @override
  String toString() => 'SqliteException: $message';
}

typedef PureSqlException = SqliteException;

class PureDatabase {
  PureDatabase._(Map<String, _Table> tables, [this._pager])
    : _tables = tables,
      _indexes = {};

  factory PureDatabase.memory() => PureDatabase._({});

  factory PureDatabase.open(
    String path, {
    Duration busyTimeout = Duration.zero,
  }) {
    final pager = SqlitePagerSync.open(path, busyTimeout: busyTimeout);
    final database = PureDatabase._({}, pager);
    try {
      final refresh = database._refreshFile;
      if (pager.isWalMode) {
        pager.withSharedLock(refresh);
      } else {
        pager.withExclusiveLock(refresh);
      }
    } catch (_) {
      database.close();
      rethrow;
    }
    return database;
  }

  Map<String, _Table> _tables;
  Map<String, _Index> _indexes;
  SqlitePagerSync? _pager;
  var _userVersion = 0;
  var _foreignKeys = false;
  var _synchronous = 2;
  var _inTransaction = false;
  var _walTransaction = false;
  SqliteRollbackJournal? _transactionJournal;
  Map<String, _Table>? _memoryTransactionTables;

  int execute(String sql, [List<Object?> parameters = const []]) {
    final statement = _Parser(sql).parse();
    final values = parameters.map(_value).toList(growable: false);
    if (statement is _Begin) return _begin();
    if (statement is _Commit) return _commit();
    if (statement is _Rollback) return _rollback();
    if (_pager != null &&
        !_inTransaction &&
        statement is _Pragma &&
        _key(statement.name) == 'journal_mode' &&
        statement.value != null) {
      return _changeJournalMode(statement, values);
    }
    if (_pager != null && !_inTransaction && statement is! _Select) {
      return _persistentWrite(() => _execute(statement, values, sql));
    }
    return _execute(statement, values, sql);
  }

  List<SqlRow> select(String sql, [List<Object?> parameters = const []]) {
    final statement = _Parser(sql).parse();
    if (statement is _Pragma) {
      if (statement.value != null) {
        throw PureSqlException('PRAGMA assignment must use execute()');
      }
      return _withCurrentFile(
        () => [
          {statement.name.toLowerCase(): _pragmaValue(statement)},
        ],
      );
    }
    if (statement is! _Select) {
      throw PureSqlException('Only SELECT can be used with select()');
    }
    final values = parameters.map(_value).toList(growable: false);
    return _withCurrentFile(() => _select(statement, values));
  }

  T transaction<T>(T Function(PureDatabase database) action) {
    if (_pager == null) {
      final before = _cloneTables(_tables);
      try {
        return action(this);
      } catch (_) {
        _tables = before;
        rethrow;
      }
    }
    if (_inTransaction) {
      throw PureSqlException('nested transactions are not supported');
    }
    _begin();
    try {
      final result = action(this);
      _commit();
      return result;
    } catch (_) {
      if (_inTransaction) _rollback();
      rethrow;
    }
  }

  int _execute(_Statement statement, List<Object?> values, String sql) =>
      switch (statement) {
        _CreateTable() => _create(statement, sql: sql),
        _CreateIndex() => _createIndex(statement, sql: sql),
        _Pragma() => _pragma(statement, values),
        _AlterTable() => _alterTable(statement, sql: sql),
        _Begin() || _Commit() || _Rollback() => throw PureSqlException(
          'transaction control must use execute()',
        ),
        _Insert() => _insert(statement, values),
        _Update() => _update(statement, values),
        _Delete() => _delete(statement, values),
        _Select() => throw PureSqlException('SELECT must use select()'),
      };

  int _begin() {
    if (_inTransaction) throw PureSqlException('transaction already active');
    if (_pager == null) {
      _memoryTransactionTables = _cloneTables(_tables);
    } else {
      final pager = _pager!;
      while (true) {
        if (pager.isWalMode) {
          pager.acquireWalWriterLock();
          try {
            _refreshFile();
            if (!pager.isWalMode) {
              pager.releaseWalWriterLock();
              continue;
            }
            pager.beginWalTransaction();
            _walTransaction = true;
            break;
          } catch (_) {
            pager.releaseWalWriterLock();
            rethrow;
          }
        } else {
          pager.acquireExclusiveLock();
          try {
            _refreshFile();
            if (pager.isWalMode) {
              pager.releaseExclusiveLock();
              continue;
            }
            _transactionJournal = SqliteRollbackJournal.begin(
              pager.path,
              databaseHandle: pager.databaseHandle,
            );
            _walTransaction = false;
            break;
          } catch (_) {
            pager.releaseExclusiveLock();
            rethrow;
          }
        }
      }
    }
    _inTransaction = true;
    return 0;
  }

  int _commit() {
    if (!_inTransaction) return 0;
    try {
      if (_walTransaction) {
        _pager!.commitWalTransaction();
      } else {
        _transactionJournal?.commit();
      }
    } catch (_) {
      if (_walTransaction) _pager!.rollbackWalTransaction();
      rethrow;
    } finally {
      _transactionJournal = null;
      _memoryTransactionTables = null;
      _inTransaction = false;
      if (_walTransaction) {
        _pager?.releaseWalWriterLock();
        _walTransaction = false;
      } else {
        _pager?.releaseExclusiveLock();
      }
    }
    return 0;
  }

  int _rollback() {
    if (!_inTransaction) return 0;
    if (_pager == null) {
      _tables = _memoryTransactionTables!;
    } else if (_walTransaction) {
      try {
        _pager!.rollbackWalTransaction();
      } finally {
        _memoryTransactionTables = null;
        _inTransaction = false;
        _walTransaction = false;
        _pager!.releaseWalWriterLock();
      }
    } else {
      try {
        _transactionJournal!.rollback(
          _pager!.path,
          databaseHandle: _pager!.databaseHandle,
        );
        _refreshFile();
      } finally {
        _transactionJournal = null;
        _memoryTransactionTables = null;
        _inTransaction = false;
        _pager!.releaseExclusiveLock();
      }
    }
    _transactionJournal = null;
    _memoryTransactionTables = null;
    _inTransaction = false;
    return 0;
  }

  T _journalled<T>(T Function() action) {
    final journal = SqliteRollbackJournal.begin(
      _pager!.path,
      databaseHandle: _pager!.databaseHandle,
    );
    try {
      final result = action();
      journal.commit();
      return result;
    } catch (_) {
      journal.rollback(_pager!.path, databaseHandle: _pager!.databaseHandle);
      _refreshFile();
      rethrow;
    }
  }

  T _persistentWrite<T>(T Function() action) {
    final pager = _pager!;
    while (true) {
      if (pager.isWalMode) {
        pager.acquireWalWriterLock();
        try {
          _refreshFile();
          if (!pager.isWalMode) continue;
          pager.beginWalTransaction();
          try {
            final result = action();
            pager.commitWalTransaction();
            return result;
          } catch (_) {
            pager.rollbackWalTransaction();
            rethrow;
          }
        } finally {
          pager.releaseWalWriterLock();
        }
      }
      pager.acquireExclusiveLock();
      try {
        _refreshFile();
        if (pager.isWalMode) continue;
        return _journalled(action);
      } finally {
        pager.releaseExclusiveLock();
      }
    }
  }

  int _changeJournalMode(_Pragma statement, List<Object?> parameters) {
    final pager = _pager!;
    final mode = _pragmaInput(
      statement.value!,
      parameters,
    ).toString().toLowerCase();
    if (mode != 'wal' && mode != 'delete') {
      throw PureSqlException('unsupported journal mode: $mode');
    }
    if (mode == 'wal') {
      return pager.withExclusiveLock(() {
        _refreshFile();
        if (pager.isWalMode) return 0;
        return _journalled(() {
          pager.enableWalMode();
          return 0;
        });
      });
    }
    return pager.withExclusiveLock(() {
      _refreshFile();
      if (!pager.isWalMode) return 0;
      pager.disableWalMode();
      _refreshFile();
      return 0;
    });
  }

  T _withCurrentFile<T>(T Function() action, {bool write = false}) {
    final pager = _pager;
    if (pager == null || _inTransaction) return action();
    final withLock = write ? pager.withExclusiveLock : pager.withSharedLock;
    return withLock(() {
      _refreshFile();
      return action();
    });
  }

  void _refreshFile() {
    _pager!.refresh();
    _tables = {};
    _indexes = {};
    _loadFile();
  }

  int _create(_CreateTable statement, {required String sql}) {
    final key = _key(statement.name);
    if (_tables.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('table already exists: ${statement.name}');
    }
    if (_pager == null) {
      _tables[key] = _Table(
        statement.name,
        statement.columns,
        schemaSql: sql.trim(),
        primaryKeyColumns: statement.primaryKeyColumns,
        checkExpressions: statement.checkExpressions,
      );
      return 0;
    }
    final pager = _pager!;
    final rootPage = pager.allocatePage();
    pager.writePage(
      rootPage,
      SqliteTableBtree.emptyPage(pager.header.pageSize),
    );
    SqliteTableBtree.insertRow(pager, 1, _nextSchemaRowId(), [
      'table',
      statement.name,
      statement.name,
      rootPage,
      sql.trim(),
    ], pageStart: 100);
    final table = _Table(
      statement.name,
      statement.columns,
      schemaSql: sql.trim(),
      rootPage: rootPage,
      primaryKeyColumns: statement.primaryKeyColumns,
      checkExpressions: statement.checkExpressions,
    );
    _tables[key] = table;
    var autoIndexNumber = 0;
    final autoIndexColumns = <List<String>>[
      for (final column in statement.columns)
        if ((column.primaryKey || column.unique) && column != table.rowIdColumn)
          [column.name],
      if (statement.primaryKeyColumns.isNotEmpty &&
          !(statement.primaryKeyColumns.length == 1 &&
              table.rowIdColumn?.name == statement.primaryKeyColumns.single))
        statement.primaryKeyColumns,
    ];
    for (final columns in autoIndexColumns) {
      autoIndexNumber++;
      final index = _Index(
        'sqlite_autoindex_${statement.name}_$autoIndexNumber',
        table,
        columns,
        rootPage: pager.allocatePage(),
        unique: true,
      );
      pager.writePage(
        index.rootPage!,
        SqliteIndexBtree.emptyPage(pager.header.pageSize),
      );
      table.indexes.add(index);
      _indexes[_key(index.name)] = index;
      SqliteTableBtree.insertRow(pager, 1, _nextSchemaRowId(), [
        'index',
        index.name,
        table.name,
        index.rootPage,
        null,
      ], pageStart: 100);
    }
    return 0;
  }

  int _alterTable(_AlterTable statement, {required String sql}) {
    final table = _table(statement.table);
    try {
      table.column(statement.column.name);
      throw PureSqlException('duplicate column name: ${statement.column.name}');
    } on PureSqlException catch (error) {
      if (!error.message.startsWith('no such column:')) rethrow;
    }
    if (statement.column.notNull &&
        table.rows.isNotEmpty &&
        statement.column.defaultExpression == null) {
      throw PureSqlException(
        'cannot add a NOT NULL column with existing null values',
      );
    }
    table.columns.add(statement.column);
    for (final row in table.rows) {
      row[statement.column.name] = statement.column.defaultExpression == null
          ? null
          : _eval(statement.column.defaultExpression!, const {}, const []);
    }
    final oldSql = table.schemaSql;
    if (oldSql == null) throw SqliteFormatException('missing table SQL');
    final close = oldSql.lastIndexOf(')');
    if (close < 0) throw SqliteFormatException('invalid CREATE TABLE SQL');
    table.schemaSql =
        '${oldSql.substring(0, close)}, ${_columnSql(statement.column)})';
    final pager = _pager;
    if (pager != null) {
      _rewriteTable(pager, table);
      final schemaRows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
      final updated = [
        for (final row in schemaRows)
          row.values.length >= 5 &&
                  row.values[0] == 'table' &&
                  _key(row.values[1].toString()) == _key(table.name)
              ? SqliteBtreeRow(
                  row.rowId,
                  [...row.values]..[4] = table.schemaSql,
                )
              : row,
      ];
      SqliteTableBtree.rewriteRows(pager, 1, updated, pageStart: 100);
    }
    return 0;
  }

  int _pragma(_Pragma statement, List<Object?> parameters) {
    final name = _key(statement.name);
    final expression = statement.value;
    if (expression == null) return 0;
    final value = _pragmaInput(expression, parameters);
    if (name == 'foreign_keys') {
      _foreignKeys = _truthy(value);
      return 0;
    }
    if (name == 'busy_timeout') {
      final milliseconds = _asInt(value);
      if (milliseconds < 0) {
        throw PureSqlException('busy_timeout must not be negative');
      }
      _pager?.busyTimeout = Duration(milliseconds: milliseconds);
      return 0;
    }
    if (name == 'synchronous') {
      _synchronous = switch (value.toString().toUpperCase()) {
        'OFF' => 0,
        'NORMAL' => 1,
        'FULL' => 2,
        'EXTRA' => 3,
        _ => _asInt(value),
      };
      if (_synchronous < 0 || _synchronous > 3) {
        throw PureSqlException('invalid synchronous value: $value');
      }
      return 0;
    }
    if (name == 'journal_mode') {
      final mode = value.toString().toLowerCase();
      if (mode != 'delete' && mode != 'wal') {
        throw PureSqlException('invalid journal mode: $value');
      }
      return 0;
    }
    if (name != 'user_version') {
      throw PureSqlException('unsupported PRAGMA: ${statement.name}');
    }
    final version = _asInt(value);
    if (version < 0) {
      throw PureSqlException('user_version must not be negative');
    }
    _userVersion = version;
    final pager = _pager;
    if (pager != null) {
      pager.header.userVersion = version;
      pager.writePage(1, pager.readPage(1));
    }
    return 0;
  }

  Object? _pragmaValue(_Pragma statement) {
    final name = _key(statement.name);
    if (name == 'foreign_keys') return _foreignKeys ? 1 : 0;
    if (name == 'busy_timeout') return _pager?.busyTimeout.inMilliseconds ?? 0;
    if (name == 'synchronous') return _synchronous;
    if (name == 'journal_mode') {
      if (_pager == null) return 'memory';
      return _pager!.isWalMode ? 'wal' : 'delete';
    }
    if (name == 'user_version') {
      return _pager?.header.userVersion ?? _userVersion;
    }
    throw PureSqlException('unsupported PRAGMA: ${statement.name}');
  }

  int _createIndex(_CreateIndex statement, {required String sql}) {
    final key = _key(statement.name);
    if (_indexes.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('index already exists: ${statement.name}');
    }
    final table = _table(statement.table);
    for (final column in statement.columns) {
      table.column(column);
    }
    final index = _Index(
      statement.name,
      table,
      statement.columns,
      unique: statement.unique,
      descending: statement.descending,
      where: statement.where,
    );
    _validateIndexRows(index, table.rows);
    if (_pager == null) {
      _indexes[key] = index;
      table.indexes.add(index);
      return 0;
    }
    final pager = _pager!;
    final rootPage = pager.allocatePage();
    index.rootPage = rootPage;
    pager.writePage(
      rootPage,
      SqliteIndexBtree.emptyPage(pager.header.pageSize),
    );
    SqliteIndexBtree.rewriteRows(pager, rootPage, _indexEntries(index));
    SqliteTableBtree.insertRow(pager, 1, _nextSchemaRowId(), [
      'index',
      statement.name,
      statement.table,
      rootPage,
      sql.trim(),
    ], pageStart: 100);
    _indexes[key] = index;
    table.indexes.add(index);
    return 0;
  }

  int _insert(_Insert statement, List<Object?> parameters) {
    final table = _table(statement.table);
    final columns =
        statement.columns ??
        table.columns.map((column) => column.name).toList();
    if (columns.length != statement.values.length) {
      throw PureSqlException('column/value count mismatch');
    }
    final row = <String, Object?>{};
    for (final column in table.columns) {
      row[column.name] = column.defaultExpression == null
          ? null
          : _eval(column.defaultExpression!, const {}, parameters);
    }
    for (var i = 0; i < columns.length; i++) {
      final column = table.column(columns[i]);
      row[column.name] = _eval(statement.values[i], row, parameters);
    }
    final rowIdColumn = table.rowIdColumn;
    final requestedRowId = rowIdColumn == null ? null : row[rowIdColumn.name];
    final rowId = requestedRowId == null
        ? table.nextRowId
        : _asInt(requestedRowId);
    if (rowId < 1) throw PureSqlException('rowid must be positive');
    if (rowIdColumn != null) row[rowIdColumn.name] = rowId;
    final conflicts = _conflictingRows(table, row, rowId);
    if (statement.conflict == 'ignore' && conflicts.isNotEmpty) return 0;
    if (statement.conflict == 'abort' && conflicts.isNotEmpty) {
      throw PureSqlException('UNIQUE constraint failed: ${table.name}');
    }
    final oldNextRowId = table.nextRowId;
    final oldRows = List<SqlRow>.from(table.rows);
    final oldRowIds = List<int>.from(table.rowIds);
    for (final index in conflicts.reversed) {
      if (_foreignKeys) _validateParentDelete(table, table.rows[index]);
      table.rows.removeAt(index);
      table.rowIds.removeAt(index);
    }
    try {
      _validate(table, row);
      table.nextRowId = rowId >= table.nextRowId ? rowId + 1 : table.nextRowId;
      table.rows.add(row);
      table.rowIds.add(rowId);
      for (final index in table.indexes) _validateIndexRows(index, table.rows);
    } catch (_) {
      table.rows
        ..clear()
        ..addAll(oldRows);
      table.rowIds
        ..clear()
        ..addAll(oldRowIds);
      table.nextRowId = oldNextRowId;
      rethrow;
    }
    final pager = _pager;
    if (pager != null) {
      try {
        if (conflicts.isEmpty) {
          SqliteTableBtree.insertRow(pager, table.rootPage!, rowId, [
            ..._storedValues(table, row),
          ]);
        } else {
          _rewriteTable(pager, table);
        }
        _rewriteIndexes(pager, table);
      } catch (_) {
        table.rows
          ..clear()
          ..addAll(oldRows);
        table.rowIds
          ..clear()
          ..addAll(oldRowIds);
        table.nextRowId = oldNextRowId;
        rethrow;
      }
    }
    return 1;
  }

  List<int> _conflictingRows(_Table table, SqlRow row, int rowId) {
    final conflicts = <int>{};
    for (var index = 0; index < table.rows.length; index++) {
      if (table.rowIds[index] == rowId) conflicts.add(index);
      final old = table.rows[index];
      for (final column in table.columns) {
        if (column.unique || column.primaryKey) {
          final value = row[column.name];
          if (value != null && _columnEqual(column, old[column.name], value))
            conflicts.add(index);
        }
      }
      for (final uniqueIndex in table.indexes) {
        if (uniqueIndex.unique && _sameIndexKey(uniqueIndex, old, row))
          conflicts.add(index);
      }
    }
    return conflicts.toList()..sort();
  }

  bool _sameIndexKey(_Index index, SqlRow left, SqlRow right) {
    if (index.where != null &&
        (!_truthy(_eval(index.where!, left, const [])) ||
            !_truthy(_eval(index.where!, right, const [])))) {
      return false;
    }
    for (final column in index.columns) {
      final name = index.table.column(column).name;
      final a = left[name];
      final b = right[name];
      if (a == null || b == null) return false;
      if (!_columnEqual(index.table.column(column), a, b)) return false;
    }
    return true;
  }

  void _loadFile() {
    final pager = _pager!;
    final schemaRows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
    for (final schemaRow in schemaRows) {
      if (schemaRow.values.length < 5 || schemaRow.values[0] != 'table')
        continue;
      final sql = schemaRow.values[4];
      final rootPage = schemaRow.values[3];
      if (sql is! String || rootPage is! int) continue;
      final statement = _Parser(sql).parse();
      if (statement is! _CreateTable) continue;
      final table = _Table(
        statement.name,
        statement.columns,
        schemaSql: sql,
        rootPage: rootPage,
        primaryKeyColumns: statement.primaryKeyColumns,
        checkExpressions: statement.checkExpressions,
      );
      for (final row in SqliteTableBtree.readTree(pager, rootPage)) {
        if (row.values.length != table.columns.length) {
          throw SqliteFormatException('table row does not match schema');
        }
        final values = <String, Object?>{};
        for (var index = 0; index < table.columns.length; index++) {
          values[table.columns[index].name] = row.values[index];
        }
        final rowIdColumn = table.rowIdColumn;
        if (rowIdColumn != null && values[rowIdColumn.name] == null) {
          values[rowIdColumn.name] = row.rowId;
        }
        table.rows.add(values);
        table.rowIds.add(row.rowId);
        table.nextRowId = row.rowId >= table.nextRowId
            ? row.rowId + 1
            : table.nextRowId;
      }
      _tables[_key(table.name)] = table;
    }
    final autoIndexCounts = <String, int>{};
    for (final schemaRow in schemaRows) {
      if (schemaRow.values.length < 5 || schemaRow.values[0] != 'index') {
        continue;
      }
      final indexName = schemaRow.values[1];
      final sql = schemaRow.values[4];
      final rootPage = schemaRow.values[3];
      final tableName = schemaRow.values[2];
      if (rootPage is! int || tableName is! String || indexName is! String)
        continue;
      final table = _tables[_key(tableName)];
      if (table == null) throw SqliteFormatException('index table is missing');
      _CreateIndex? statement;
      List<String>? columns;
      var unique = false;
      var descending = const <bool>[];
      if (sql is String) {
        final parsed = _Parser(sql).parse();
        if (parsed is! _CreateIndex) continue;
        statement = parsed;
        columns = statement.columns;
        unique = statement.unique;
        descending = statement.descending;
      } else if (sql == null && indexName.startsWith('sqlite_autoindex_')) {
        final offset = autoIndexCounts[_key(table.name)] ?? 0;
        final candidates = <List<String>>[
          ...table.columns
              .where(
                (column) =>
                    (column.primaryKey || column.unique) &&
                    column != table.rowIdColumn,
              )
              .map((column) => [column.name]),
          if (table.primaryKeyColumns.isNotEmpty &&
              !(table.primaryKeyColumns.length == 1 &&
                  table.rowIdColumn?.name == table.primaryKeyColumns.single))
            table.primaryKeyColumns,
        ];
        if (offset >= candidates.length) continue;
        autoIndexCounts[_key(table.name)] = offset + 1;
        columns = candidates[offset];
        unique = true;
      } else {
        continue;
      }
      final index = _Index(
        indexName,
        table,
        columns,
        rootPage: rootPage,
        unique: unique,
        descending: descending,
        where: sql is String ? statement?.where : null,
      );
      _indexes[_key(index.name)] = index;
      table.indexes.add(index);
    }
  }

  int _nextSchemaRowId() {
    final pager = _pager!;
    final rows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
    return rows.isEmpty
        ? 1
        : rows.map((row) => row.rowId).reduce((a, b) => a > b ? a : b) + 1;
  }

  void close() {
    if (_inTransaction) _rollback();
    _pager?.close();
  }

  int _update(_Update statement, List<Object?> parameters) {
    final table = _table(statement.table);
    var count = 0;
    for (final row in table.rows) {
      if (!_matches(statement.where, row, parameters)) continue;
      final next = Map<String, Object?>.from(row);
      for (final entry in statement.assignments.entries) {
        next[table.column(entry.key).name] = _eval(
          entry.value,
          next,
          parameters,
        );
      }
      _validate(table, next, ignore: row);
      row
        ..clear()
        ..addAll(next);
      count++;
    }
    final pager = _pager;
    if (pager != null && count > 0) {
      _rewriteTable(pager, table);
      _rewriteIndexes(pager, table);
    }
    return count;
  }

  int _delete(_Delete statement, List<Object?> parameters) {
    final table = _table(statement.table);
    var count = 0;
    for (var index = table.rows.length - 1; index >= 0; index--) {
      if (!_matches(statement.where, table.rows[index], parameters)) continue;
      if (_foreignKeys) _validateParentDelete(table, table.rows[index]);
      table.rows.removeAt(index);
      table.rowIds.removeAt(index);
      count++;
    }
    final pager = _pager;
    if (pager != null && count > 0) {
      _rewriteTable(pager, table);
      _rewriteIndexes(pager, table);
    }
    return count;
  }

  void _rewriteTable(SqlitePagerSync pager, _Table table) {
    SqliteTableBtree.rewriteRows(pager, table.rootPage!, [
      for (var index = 0; index < table.rows.length; index++)
        SqliteBtreeRow(table.rowIds[index], [
          ..._storedValues(table, table.rows[index]),
        ]),
    ]);
  }

  void _rewriteIndexes(SqlitePagerSync pager, _Table table) {
    for (final index in table.indexes) {
      _validateIndexRows(index, table.rows);
      SqliteIndexBtree.rewriteRows(
        pager,
        index.rootPage!,
        _indexEntries(index),
        compare: (left, right) => _compareIndexEntries(index, left, right),
      );
    }
  }

  List<SqliteIndexEntry> _indexEntries(_Index index) => [
    for (var row = 0; row < index.table.rows.length; row++)
      if (index.where == null ||
          _truthy(_eval(index.where!, index.table.rows[row], const [])))
        SqliteIndexEntry(index.table.rowIds[row], [
          for (final column in index.columns)
            index.table.rows[row][index.table.column(column).name],
        ]),
  ];

  int _compareIndexEntries(
    _Index index,
    SqliteIndexEntry left,
    SqliteIndexEntry right,
  ) {
    for (var position = 0; position < index.columns.length; position++) {
      final column = index.table.column(index.columns[position]);
      final result = _compare(
        left.values[position],
        right.values[position],
        noCase: column.collation == 'NOCASE',
      );
      if (result != 0) {
        return position < index.descending.length && index.descending[position]
            ? -result
            : result;
      }
    }
    return left.rowId.compareTo(right.rowId);
  }

  void _validateIndexRows(_Index index, List<SqlRow> rows) {
    if (!index.unique) return;
    final indexedRows = [
      for (final row in rows)
        if (index.where == null || _truthy(_eval(index.where!, row, const [])))
          row,
    ];
    for (var left = 0; left < indexedRows.length; left++) {
      for (var right = left + 1; right < indexedRows.length; right++) {
        var equal = true;
        var hasNull = false;
        for (final column in index.columns) {
          final definition = index.table.column(column);
          final a = indexedRows[left][definition.name];
          final b = indexedRows[right][definition.name];
          if (a == null || b == null) {
            hasNull = true;
          } else if (!_columnEqual(definition, a, b)) {
            equal = false;
            break;
          }
        }
        if (equal && !hasNull) {
          throw PureSqlException('UNIQUE constraint failed: ${index.name}');
        }
      }
    }
  }

  void _validateForeignKeys(_Table table, SqlRow row) {
    for (final column in table.columns) {
      final parentName = column.referencesTable;
      final value = row[column.name];
      if (parentName == null || value == null) continue;
      final parent = _tables[_key(parentName)];
      if (parent == null) {
        throw PureSqlException('no such table: $parentName');
      }
      final parentColumn = parent.column(column.referencesColumn ?? 'rowid');
      if (!parent.rows.any(
        (parentRow) => _equal(parentRow[parentColumn.name], value),
      )) {
        throw PureSqlException('FOREIGN KEY constraint failed');
      }
    }
  }

  void _validateParentDelete(_Table parent, SqlRow row) {
    for (final child in _tables.values) {
      for (final column in child.columns) {
        if (_key(column.referencesTable ?? '') != _key(parent.name)) continue;
        final parentColumn = parent.column(column.referencesColumn ?? 'rowid');
        final value = row[parentColumn.name];
        if (value != null &&
            child.rows.any(
              (childRow) => _equal(childRow[column.name], value),
            )) {
          throw PureSqlException('FOREIGN KEY constraint failed');
        }
      }
    }
  }

  List<Object?> _storedValues(_Table table, SqlRow row) => [
    for (final column in table.columns)
      column == table.rowIdColumn ? null : row[column.name],
  ];

  List<SqlRow> _select(
    _Select statement,
    List<Object?> parameters, {
    SqlRow outerRow = const {},
  }) {
    final table = _table(statement.table);
    final candidateRowIds = outerRow.isEmpty
        ? _indexCandidates(table, statement.where, parameters)
        : null;
    var joinedRows = <SqlRow>[];
    for (var index = 0; index < table.rows.length; index++) {
      if (candidateRowIds != null &&
          !candidateRowIds.contains(table.rowIds[index])) {
        continue;
      }
      joinedRows.add(
        Map<String, Object?>.from(outerRow)
          ..addAll(_qualifiedRow(table, table.rows[index], statement.alias)),
      );
    }
    for (final join in statement.joins) {
      final joinedTable = _table(join.table);
      final next = <SqlRow>[];
      for (final leftRow in joinedRows) {
        var matched = false;
        for (final rightRow in joinedTable.rows) {
          final combined = Map<String, Object?>.from(leftRow)
            ..addAll(_qualifiedRow(joinedTable, rightRow, join.alias));
          if (_truthy(_eval(join.on, combined, parameters))) {
            next.add(combined);
            matched = true;
          }
        }
        if (!matched && join.left) {
          next.add(
            Map<String, Object?>.from(leftRow)
              ..addAll(_qualifiedRow(joinedTable, const {}, join.alias)),
          );
        }
      }
      joinedRows = next;
    }
    var rows = <SqlRow>[];
    for (final row in joinedRows) {
      if (_matches(statement.where, row, parameters)) rows.add(row);
    }

    if (statement.groupBy.isNotEmpty ||
        statement.items.any((item) => _containsAggregate(item.expression))) {
      final groups = <List<SqlRow>>[];
      if (rows.isEmpty && statement.groupBy.isEmpty) {
        groups.add(const []);
      } else {
        for (final row in rows) {
          final group = groups.firstWhere(
            (candidate) => statement.groupBy.every(
              (expression) => _equal(
                _evalGroupKey(
                  expression,
                  candidate.first,
                  statement.items,
                  parameters,
                ),
                _evalGroupKey(expression, row, statement.items, parameters),
              ),
            ),
            orElse: () {
              final group = <SqlRow>[];
              groups.add(group);
              return group;
            },
          );
          group.add(row);
        }
      }
      var grouped = [
        for (final group in groups)
          _projectGroup(group, statement.items, parameters),
      ];
      if (statement.orderBy.isNotEmpty) {
        grouped.sort((a, b) {
          for (final order in statement.orderBy) {
            final result = _compare(
              a[order.name],
              b[order.name],
              noCase: order.noCase,
            );
            if (result != 0) return order.descending ? -result : result;
          }
          return 0;
        });
      }
      if (statement.limit != null) {
        final offset = statement.offset == null
            ? 0
            : _asInt(_eval(statement.offset!, const {}, parameters));
        final limit = _asInt(_eval(statement.limit!, const {}, parameters));
        if (limit < 0 || offset < 0) {
          throw PureSqlException('LIMIT/OFFSET must not be negative');
        }
        grouped = grouped.skip(offset).take(limit).toList();
      }
      return grouped;
    }

    if (statement.orderBy.isNotEmpty) {
      if (rows.isNotEmpty) {
        for (final order in statement.orderBy) {
          _readColumn(rows.first, order.name);
        }
      }
      rows.sort((a, b) {
        for (final order in statement.orderBy) {
          final result = _compare(
            _readColumn(a, order.name),
            _readColumn(b, order.name),
            noCase: order.noCase,
          );
          if (result != 0) return order.descending ? -result : result;
        }
        return 0;
      });
    }
    if (statement.limit != null) {
      final offset = statement.offset == null
          ? 0
          : _asInt(_eval(statement.offset!, const {}, parameters));
      final limit = _asInt(_eval(statement.limit!, const {}, parameters));
      if (limit < 0 || offset < 0) {
        throw PureSqlException('LIMIT/OFFSET must not be negative');
      }
      rows = rows.skip(offset).take(limit).toList();
    }

    return [for (final row in rows) _project(row, statement.items, parameters)];
  }

  SqlRow _projectGroup(
    List<SqlRow> group,
    List<_SelectItem> items,
    List<Object?> parameters,
  ) {
    final row = group.isEmpty ? <String, Object?>{} : group.first;
    return <String, Object?>{
      for (final item in items)
        item.outputName: item.expression is _ScalarSubquery
            ? _selectScalar(item.expression as _ScalarSubquery, row, parameters)
            : _evalGroup(item.expression, group, row, parameters),
    };
  }

  Object? _selectScalar(
    _ScalarSubquery expression,
    SqlRow outerRow,
    List<Object?> parameters,
  ) {
    if (expression.query.items.length != 1) {
      throw PureSqlException('scalar subquery must return one column');
    }
    final rows = _select(expression.query, parameters, outerRow: outerRow);
    return rows.isEmpty ? null : rows.first.values.first;
  }

  SqlRow _qualifiedRow(_Table table, SqlRow row, String? alias) {
    final result = <String, Object?>{...row};
    for (final column in table.columns) {
      final value = row[column.name];
      result['@${table.name}.${column.name}'] = value;
      if (alias != null) result['@$alias.${column.name}'] = value;
      if (column.collation != null) {
        result['@@collation:${column.name}'] = column.collation;
        result['@@collation:${table.name}.${column.name}'] = column.collation;
        if (alias != null) {
          result['@@collation:$alias.${column.name}'] = column.collation;
        }
      }
    }
    return result;
  }

  Set<int>? _indexCandidates(
    _Table table,
    _Expr? expression,
    List<Object?> parameters,
  ) {
    if (_pager == null ||
        expression is! _Binary ||
        expression.operator != '=') {
      return null;
    }
    String? column;
    _Expr? valueExpression;
    if (expression.left is _Column) {
      column = (expression.left as _Column).name;
      valueExpression = expression.right;
    } else if (expression.right is _Column) {
      column = (expression.right as _Column).name;
      valueExpression = expression.left;
    }
    if (column == null || valueExpression == null) return null;
    final value = _eval(valueExpression, const {}, parameters);
    if (value == null) return null;
    for (final index in table.indexes) {
      if (index.where != null ||
          index.columns.length != 1 ||
          _key(index.columns.single) != _key(column) ||
          index.rootPage == null) {
        continue;
      }
      return {
        for (final entry in SqliteIndexBtree.readTree(_pager!, index.rootPage!))
          if (_columnEqual(
            table.column(index.columns.single),
            entry.values.single,
            value,
          ))
            entry.rowId,
      };
    }
    return null;
  }

  SqlRow _project(
    SqlRow row,
    List<_SelectItem> items,
    List<Object?> parameters,
  ) {
    final result = <String, Object?>{};
    for (final item in items) {
      final expression = item.expression;
      if (expression is _Column &&
          (expression.name == '*' || expression.name.endsWith('.*'))) {
        final prefix = expression.name == '*'
            ? null
            : '@${expression.name.substring(0, expression.name.length - 1)}';
        for (final entry in row.entries) {
          if (prefix == null && !entry.key.startsWith('@')) {
            result[entry.key] = entry.value;
          } else if (prefix != null && entry.key.startsWith(prefix)) {
            result[entry.key.substring(prefix.length)] = entry.value;
          }
        }
      } else {
        result[item.outputName] = expression is _ScalarSubquery
            ? _selectScalar(expression, row, parameters)
            : _eval(expression, row, parameters);
      }
    }
    return result;
  }

  bool _matches(_Expr? expression, SqlRow row, List<Object?> parameters) {
    if (expression == null) return true;
    return _truthy(_eval(expression, row, parameters));
  }

  _Table _table(String name) {
    final table = _tables[_key(name)];
    if (table == null) throw PureSqlException('no such table: $name');
    return table;
  }

  void _validate(_Table table, SqlRow row, {SqlRow? ignore}) {
    for (final column in table.columns) {
      final value = row[column.name];
      if ((column.notNull ||
              table.primaryKeyColumns.any(
                (name) => _key(name) == _key(column.name),
              )) &&
          value == null) {
        throw PureSqlException(
          'NOT NULL constraint failed: ${table.name}.${column.name}',
        );
      }
      if ((column.primaryKey || column.unique) && value != null) {
        if (table.rows.any(
          (old) =>
              old != ignore && _columnEqual(column, old[column.name], value),
        )) {
          throw PureSqlException(
            'UNIQUE constraint failed: ${table.name}.${column.name}',
          );
        }
      }
      for (final check in column.checkExpressions) {
        final result = _eval(check, row, const []);
        if (result != null && !_truthy(result)) {
          throw PureSqlException(
            'CHECK constraint failed: ${table.name}.${column.name}',
          );
        }
      }
    }
    for (final check in table.checkExpressions) {
      final result = _eval(check, row, const []);
      if (result != null && !_truthy(result)) {
        throw PureSqlException('CHECK constraint failed: ${table.name}');
      }
    }
    if (_foreignKeys) _validateForeignKeys(table, row);
  }
}

typedef Row = Map<String, Object?>;
typedef ResultSet = List<Row>;

/// Compatibility entry point for applications migrating from package:sqlite3.
final sqlite3 = Sqlite();

class Sqlite {
  Database open(String path) => Database._(PureDatabase.open(path));
}

class Database {
  Database._(this._database);

  final PureDatabase _database;
  int updatedRows = 0;

  void execute(String sql, [List<Object?> parameters = const []]) {
    updatedRows = _database.execute(sql, parameters);
  }

  ResultSet select(String sql, [List<Object?> parameters = const []]) => [
    for (final row in _database.select(sql, parameters))
      {
        for (final entry in row.entries)
          if (!entry.key.startsWith('@'))
            entry.key.split('.').last: entry.value,
      },
  ];

  void dispose() => _database.close();
}

Object? _value(Object? value) {
  if (value == null || value is String || value is num) return value;
  if (value is bool) return value ? 1 : 0;
  if (value is List<int>) return List<int>.from(value);
  throw PureSqlException('unsupported value: ${value.runtimeType}');
}

Object? _pragmaInput(_Expr expression, List<Object?> parameters) =>
    expression is _Column && !expression.name.contains('.')
    ? expression.name
    : _eval(expression, const {}, parameters);

String _key(String name) => name.toLowerCase();

bool _columnEqual(_ColumnDef column, Object? left, Object? right) =>
    column.collation == 'NOCASE' && left is String && right is String
    ? _sqliteNoCase(left) == _sqliteNoCase(right)
    : _equal(left, right);

String _sqliteNoCase(String value) => value.replaceAllMapped(
  RegExp('[A-Z]'),
  (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) + 32),
);

Map<String, _Table> _cloneTables(Map<String, _Table> source) => {
  for (final entry in source.entries) entry.key: entry.value.copy(),
};

Object? _eval(_Expr expression, SqlRow row, List<Object?> parameters) =>
    switch (expression) {
      _Literal(:final value) => value,
      _Param(:final index) =>
        index < parameters.length
            ? parameters[index]
            : throw PureSqlException('missing parameter ${index + 1}'),
      _Column(:final name) => _readColumn(row, name),
      _Function(:final name, :final arguments) => _evalFunction(
        name,
        arguments,
        row,
        parameters,
      ),
      _Binary(:final left, :final operator, :final right) => _evalBinary(
        left,
        operator,
        right,
        row,
        parameters,
      ),
      _In(:final expression, :final values, :final negated) => _evalIn(
        expression,
        values,
        negated,
        row,
        parameters,
      ),
      _Case(:final branches, :final otherwise) => _evalCase(
        branches,
        otherwise,
        row,
        parameters,
      ),
      _ScalarSubquery() => throw PureSqlException(
        'scalar subquery must be projected by the database',
      ),
    };

Object? _evalCase(
  List<(_Expr, _Expr)> branches,
  _Expr? otherwise,
  SqlRow row,
  List<Object?> parameters,
) {
  for (final (condition, value) in branches) {
    if (_truthy(_eval(condition, row, parameters))) {
      return _eval(value, row, parameters);
    }
  }
  return otherwise == null ? null : _eval(otherwise, row, parameters);
}

Object? _evalGroupKey(
  _Expr expression,
  SqlRow row,
  List<_SelectItem> items,
  List<Object?> parameters,
) {
  if (expression is _Column &&
      !row.containsKey('@${expression.name}') &&
      !row.keys.any(
        (key) => !key.startsWith('@') && _key(key) == _key(expression.name),
      )) {
    for (final item in items) {
      if (_key(item.outputName) == _key(expression.name)) {
        return _eval(item.expression, row, parameters);
      }
    }
  }
  return _eval(expression, row, parameters);
}

Object? _evalBinary(
  _Expr leftExpression,
  String operator,
  _Expr rightExpression,
  SqlRow row,
  List<Object?> parameters,
) {
  final left = _eval(leftExpression, row, parameters);
  final right = _eval(rightExpression, row, parameters);
  final leftCollation = _expressionCollation(leftExpression, row);
  final collation = leftCollation == null || leftCollation == 'BINARY'
      ? _expressionCollation(rightExpression, row)
      : leftCollation;
  if (collation == 'NOCASE' && left is String && right is String) {
    final equal = _sqliteNoCase(left) == _sqliteNoCase(right);
    return switch (operator) {
      '=' || 'IS' => equal,
      '!=' || '<>' || 'IS NOT' => !equal,
      _ => _binary(operator, left, right),
    };
  }
  return _binary(operator, left, right);
}

String? _expressionCollation(_Expr expression, SqlRow row) {
  if (expression is! _Column) return null;
  final value = row['@@collation:${expression.name}'];
  return value is String ? value : null;
}

Object? _evalIn(
  _Expr expression,
  List<_Expr> values,
  bool negated,
  SqlRow row,
  List<Object?> parameters,
) {
  final value = _eval(expression, row, parameters);
  if (value == null) return null;
  final evaluatedValues = values
      .map((item) => _eval(item, row, parameters))
      .toList();
  if (evaluatedValues.any((item) => item != null && _equal(value, item))) {
    return !negated;
  }
  if (evaluatedValues.contains(null)) return null;
  return negated;
}

Object? _evalFunction(
  String name,
  List<_Expr> arguments,
  SqlRow row,
  List<Object?> parameters,
) {
  return _applyFunction(
    name,
    arguments.map((argument) => _eval(argument, row, parameters)).toList(),
  );
}

Object? _applyFunction(String name, List<Object?> values) {
  switch (name.toUpperCase()) {
    case 'COALESCE':
      for (final value in values) {
        if (value != null) return value;
      }
      return null;
    case 'LOWER':
      return values.single?.toString().toLowerCase();
    case 'UPPER':
      return values.single?.toString().toUpperCase();
    case 'STRFTIME':
      if (values.length < 2 || values.first is! String || values[1] is! num) {
        throw PureSqlException('strftime requires a format and numeric time');
      }
      if (values.length > 2 && values[2] != 'unixepoch') {
        throw PureSqlException('unsupported strftime modifier: ${values[2]}');
      }
      final seconds = (values[1]! as num).toInt();
      final date = DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000,
        isUtc: true,
      );
      final format = values.first! as String;
      return format
          .replaceAll('%Y', date.year.toString().padLeft(4, '0'))
          .replaceAll('%m', date.month.toString().padLeft(2, '0'))
          .replaceAll('%d', date.day.toString().padLeft(2, '0'))
          .replaceAll('%H', date.hour.toString().padLeft(2, '0'))
          .replaceAll('%M', date.minute.toString().padLeft(2, '0'))
          .replaceAll('%S', date.second.toString().padLeft(2, '0'));
    case 'COUNT':
      return values.single == '*'
          ? 1
          : values.single == null
          ? 0
          : 1;
    default:
      throw PureSqlException('unsupported function: $name');
  }
}

bool _containsAggregate(_Expr expression) => switch (expression) {
  _Function(:final name, :final arguments) =>
    const ['COUNT', 'SUM', 'MAX'].contains(name.toUpperCase()) ||
        arguments.any(_containsAggregate),
  _Binary(:final left, :final right) =>
    _containsAggregate(left) || _containsAggregate(right),
  _Case(:final branches, :final otherwise) =>
    branches.any(
          (branch) =>
              _containsAggregate(branch.$1) || _containsAggregate(branch.$2),
        ) ||
        (otherwise != null && _containsAggregate(otherwise)),
  _ => false,
};

Object? _evalGroup(
  _Expr expression,
  List<SqlRow> group,
  SqlRow row,
  List<Object?> parameters,
) => switch (expression) {
  _Function(:final name, :final arguments, :final distinct)
      when name.toUpperCase() == 'COUNT' =>
    _countGroup(arguments.single, group, parameters, distinct: distinct),
  _Function(:final name, :final arguments, :final distinct)
      when name.toUpperCase() == 'SUM' =>
    _sumGroup(arguments.single, group, parameters, distinct: distinct),
  _Function(:final name, :final arguments, :final distinct)
      when name.toUpperCase() == 'MAX' =>
    _maxGroup(arguments.single, group, parameters, distinct: distinct),
  _Function(:final name, :final arguments) => _applyFunction(
    name,
    arguments
        .map((argument) => _evalGroup(argument, group, row, parameters))
        .toList(),
  ),
  _Binary(:final left, :final operator, :final right) => _binary(
    operator,
    _evalGroup(left, group, row, parameters),
    _evalGroup(right, group, row, parameters),
  ),
  _Case(:final branches, :final otherwise) => _evalCase(
    branches,
    otherwise,
    row,
    parameters,
  ),
  _ => _eval(expression, row, parameters),
};

int _countGroup(
  _Expr expression,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
}) {
  if (expression is _Column && expression.name == '*') return group.length;
  final values = <Object?>{};
  var count = 0;
  for (final row in group) {
    final value = _eval(expression, row, parameters);
    if (value != null && (!distinct || values.add(value))) count++;
  }
  return count;
}

Object? _sumGroup(
  _Expr expression,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
}) {
  num? sum;
  final seen = <Object?>{};
  for (final row in group) {
    final value = _eval(expression, row, parameters);
    if (value is num && (!distinct || seen.add(value))) {
      sum = (sum ?? 0) + value;
    }
  }
  return sum;
}

Object? _maxGroup(
  _Expr expression,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
}) {
  Object? maximum;
  final seen = <Object?>{};
  for (final row in group) {
    final value = _eval(expression, row, parameters);
    if (value == null || distinct && !seen.add(value)) continue;
    if (maximum == null || _compare(value, maximum) > 0) maximum = value;
  }
  return maximum;
}

Object? _readColumn(SqlRow row, String name) {
  final qualified = row['@$name'];
  if (qualified != null || row.containsKey('@$name')) return qualified;
  for (final entry in row.entries) {
    if (!entry.key.startsWith('@') && _key(entry.key) == _key(name)) {
      return entry.value;
    }
  }
  throw PureSqlException('no such column: $name');
}

Object? _binary(String operator, Object? left, Object? right) {
  switch (operator) {
    case '+':
    case '-':
    case '*':
    case '/':
      if (left == null || right == null) return null;
      if (left is! num || right is! num) {
        throw PureSqlException('arithmetic operands must be numeric');
      }
      if (operator == '+') return left + right;
      if (operator == '-') return left - right;
      if (operator == '*') return left * right;
      if (right == 0) return null;
      return left is int && right is int ? left ~/ right : left / right;
    case 'AND':
      return _truthy(left) && _truthy(right);
    case 'OR':
      return _truthy(left) || _truthy(right);
    case 'IS':
      return right == null ? left == null : _equal(left, right);
    case 'IS NOT':
      return right == null ? left != null : !_equal(left, right);
    case '=':
      return left != null && right != null && _equal(left, right);
    case '!=':
    case '<>':
      return left != null && right != null && !_equal(left, right);
    case '<':
      return left != null && right != null && _compare(left, right) < 0;
    case '<=':
      return left != null && right != null && _compare(left, right) <= 0;
    case '>':
      return left != null && right != null && _compare(left, right) > 0;
    case '>=':
      return left != null && right != null && _compare(left, right) >= 0;
    case 'LIKE':
      return left != null &&
          right != null &&
          _like(left.toString(), right.toString());
  }
  throw PureSqlException('unsupported operator: $operator');
}

bool _truthy(Object? value) =>
    value is bool ? value : value != null && value != 0 && value != '';

bool _equal(Object? left, Object? right) => left == right;

int _compare(Object? left, Object? right, {bool noCase = false}) {
  if (left == null && right == null) return 0;
  if (left == null) return -1;
  if (right == null) return 1;
  if (left is num && right is num) return left.compareTo(right);
  final leftText = noCase ? _sqliteNoCase(left.toString()) : left.toString();
  final rightText = noCase ? _sqliteNoCase(right.toString()) : right.toString();
  return leftText.compareTo(rightText);
}

bool _like(String value, String pattern) {
  final escaped = pattern.replaceAllMapped(
    RegExp(r'([.\\+\^\$\{\}\[\]\(\)])'),
    (match) => '\\${match.group(1)}',
  );
  final regex = '^${escaped.replaceAll('%', '.*').replaceAll('_', '.')}\$';
  return RegExp(regex, dotAll: true).hasMatch(value);
}

int _asInt(Object? value) {
  if (value is int) return value;
  throw PureSqlException('expected integer, got $value');
}

String _columnSql(_ColumnDef column) => [
  column.name,
  if (column.typeName != null) column.typeName!,
  if (column.notNull) 'NOT NULL',
  if (column.defaultExpression != null)
    'DEFAULT ${_expressionSql(column.defaultExpression!)}',
].join(' ');

String _expressionSql(_Expr expression) => switch (expression) {
  _Literal(:final value) =>
    value == null
        ? 'NULL'
        : value is String
        ? "'${value.replaceAll("'", "''")}'"
        : value.toString(),
  _ => throw PureSqlException('unsupported default expression'),
};

class _Table {
  _Table(
    this.name,
    this.columns, {
    this.rootPage,
    this.schemaSql,
    this.primaryKeyColumns = const [],
    this.checkExpressions = const [],
  });

  final String name;
  final List<_ColumnDef> columns;
  final int? rootPage;
  final List<String> primaryKeyColumns;
  final List<_Expr> checkExpressions;
  String? schemaSql;
  final List<SqlRow> rows = [];
  final List<int> rowIds = [];
  final List<_Index> indexes = [];
  int nextRowId = 1;

  _ColumnDef? get rowIdColumn {
    for (final column in columns) {
      if (column.primaryKey && column.typeName?.toUpperCase() == 'INTEGER') {
        return column;
      }
    }
    if (primaryKeyColumns.length == 1) {
      final column = this.column(primaryKeyColumns.single);
      if (column.typeName?.toUpperCase() == 'INTEGER') return column;
    }
    return null;
  }

  _ColumnDef column(String name) {
    for (final column in columns) {
      if (_key(column.name) == _key(name)) return column;
    }
    throw PureSqlException('no such column: $name');
  }

  _Table copy() {
    final result = _Table(
      name,
      List<_ColumnDef>.from(columns),
      rootPage: rootPage,
      schemaSql: schemaSql,
      primaryKeyColumns: primaryKeyColumns,
      checkExpressions: checkExpressions,
    );
    result.rows.addAll(rows.map((row) => Map<String, Object?>.from(row)));
    result.rowIds.addAll(rowIds);
    result.nextRowId = nextRowId;
    return result;
  }
}

class _ColumnDef {
  _ColumnDef(
    this.name, {
    this.typeName,
    this.notNull = false,
    this.primaryKey = false,
    this.unique = false,
    this.defaultExpression,
    this.referencesTable,
    this.referencesColumn,
    this.collation,
    this.checkExpressions = const [],
  });

  final String name;
  final String? typeName;
  final bool notNull;
  final bool primaryKey;
  final bool unique;
  final _Expr? defaultExpression;
  final String? referencesTable;
  final String? referencesColumn;
  final String? collation;
  final List<_Expr> checkExpressions;
}

class _Index {
  _Index(
    this.name,
    this.table,
    this.columns, {
    this.rootPage,
    this.unique = false,
    this.descending = const [],
    this.where,
  });

  final String name;
  final _Table table;
  final List<String> columns;
  int? rootPage;
  final bool unique;
  final List<bool> descending;
  final _Expr? where;
}

sealed class _Statement {}

class _CreateTable extends _Statement {
  _CreateTable(
    this.name,
    this.columns,
    this.ifNotExists, {
    this.primaryKeyColumns = const [],
    this.checkExpressions = const [],
  });

  final String name;
  final List<_ColumnDef> columns;
  final bool ifNotExists;
  final List<String> primaryKeyColumns;
  final List<_Expr> checkExpressions;
}

class _CreateIndex extends _Statement {
  _CreateIndex(
    this.name,
    this.table,
    this.columns, {
    this.unique = false,
    this.ifNotExists = false,
    this.descending = const [],
    this.where,
  });

  final String name;
  final String table;
  final List<String> columns;
  final bool unique;
  final bool ifNotExists;
  final List<bool> descending;
  final _Expr? where;
}

class _AlterTable extends _Statement {
  _AlterTable(this.table, this.column);

  final String table;
  final _ColumnDef column;
}

class _Begin extends _Statement {}

class _Commit extends _Statement {}

class _Rollback extends _Statement {}

class _Pragma extends _Statement {
  _Pragma(this.name, this.value);

  final String name;
  final _Expr? value;
}

class _Insert extends _Statement {
  _Insert(this.table, this.columns, this.values, {this.conflict = 'abort'});
  final String table;
  final List<String>? columns;
  final List<_Expr> values;
  final String conflict;
}

class _Select extends _Statement {
  _Select(
    this.items,
    this.table,
    this.alias,
    this.joins,
    this.where,
    this.groupBy,
    this.orderBy,
    this.limit,
    this.offset,
  );
  final List<_SelectItem> items;
  final String table;
  final String? alias;
  final List<_Join> joins;
  final _Expr? where;
  final List<_Expr> groupBy;
  final List<_Order> orderBy;
  final _Expr? limit;
  final _Expr? offset;
}

class _Join {
  _Join(this.table, this.alias, this.on, this.left);

  final String table;
  final String? alias;
  final _Expr on;
  final bool left;
}

class _Update extends _Statement {
  _Update(this.table, this.assignments, this.where);
  final String table;
  final Map<String, _Expr> assignments;
  final _Expr? where;
}

class _Delete extends _Statement {
  _Delete(this.table, this.where);
  final String table;
  final _Expr? where;
}

class _SelectItem {
  _SelectItem(this.expression, this.outputName);
  final _Expr expression;
  final String outputName;
}

class _Function extends _Expr {
  _Function(this.name, this.arguments, {this.distinct = false});

  final String name;
  final List<_Expr> arguments;
  final bool distinct;
}

class _Case extends _Expr {
  _Case(this.branches, this.otherwise);

  final List<(_Expr, _Expr)> branches;
  final _Expr? otherwise;
}

class _ScalarSubquery extends _Expr {
  _ScalarSubquery(this.query);

  final _Select query;
}

class _In extends _Expr {
  _In(this.expression, this.values, this.negated);

  final _Expr expression;
  final List<_Expr> values;
  final bool negated;
}

class _Order {
  _Order(this.name, this.descending, this.noCase);
  final String name;
  final bool descending;
  final bool noCase;
}

sealed class _Expr {}

class _Literal extends _Expr {
  _Literal(this.value);
  final Object? value;
}

class _Param extends _Expr {
  _Param(this.index);
  final int index;
}

class _Column extends _Expr {
  _Column(this.name);
  final String name;
}

class _Binary extends _Expr {
  _Binary(this.left, this.operator, this.right);
  final _Expr left;
  final String operator;
  final _Expr right;
}

enum _TokenType { word, number, string, parameter, symbol, eof }

class _Token {
  _Token(this.type, this.text, [this.value]);
  final _TokenType type;
  final String text;
  final Object? value;
}

class _Tokenizer {
  _Tokenizer(this.sql);
  final String sql;
  var _offset = 0;

  List<_Token> tokenize() {
    final result = <_Token>[];
    while (_offset < sql.length) {
      final code = sql.codeUnitAt(_offset);
      if (code <= 32) {
        _offset++;
        continue;
      }
      if (sql.startsWith('--', _offset)) {
        final end = sql.indexOf('\n', _offset + 2);
        _offset = end < 0 ? sql.length : end + 1;
        continue;
      }
      final char = sql[_offset];
      if (char == "'") {
        result.add(_Token(_TokenType.string, char, _string()));
      } else if (_isLetter(code) || char == '_') {
        final start = _offset++;
        while (_offset < sql.length &&
            (_isLetterOrDigit(sql.codeUnitAt(_offset)) ||
                sql[_offset] == '_')) {
          _offset++;
        }
        result.add(_Token(_TokenType.word, sql.substring(start, _offset)));
      } else if (_isDigit(code)) {
        final start = _offset++;
        while (_offset < sql.length &&
            (_isDigit(sql.codeUnitAt(_offset)) || sql[_offset] == '.')) {
          _offset++;
        }
        result.add(_Token(_TokenType.number, sql.substring(start, _offset)));
      } else if (char == '?') {
        final start = _offset++;
        while (_offset < sql.length && _isDigit(sql.codeUnitAt(_offset)))
          _offset++;
        result.add(_Token(_TokenType.parameter, sql.substring(start, _offset)));
      } else {
        final two = _offset + 1 < sql.length
            ? sql.substring(_offset, _offset + 2)
            : '';
        if (const ['<=', '>=', '<>', '!='].contains(two)) {
          result.add(_Token(_TokenType.symbol, two));
          _offset += 2;
        } else if ('(),=*<>+-/;.'.contains(char)) {
          result.add(_Token(_TokenType.symbol, char));
          _offset++;
        } else {
          throw PureSqlException('unexpected character: $char');
        }
      }
    }
    result.add(_Token(_TokenType.eof, ''));
    return result;
  }

  String _string() {
    _offset++;
    final buffer = StringBuffer();
    while (_offset < sql.length) {
      final char = sql[_offset++];
      if (char != "'") {
        buffer.write(char);
      } else if (_offset < sql.length && sql[_offset] == "'") {
        buffer.write("'");
        _offset++;
      } else {
        return buffer.toString();
      }
    }
    throw PureSqlException('unterminated string');
  }

  bool _isDigit(int code) => code >= 48 && code <= 57;
  bool _isLetter(int code) =>
      code >= 65 && code <= 90 || code >= 97 && code <= 122;
  bool _isLetterOrDigit(int code) => _isLetter(code) || _isDigit(code);
}

class _Parser {
  _Parser(String sql) : _tokens = _Tokenizer(sql).tokenize();
  final List<_Token> _tokens;
  var _index = 0;
  var _nextParameter = 0;

  _Statement parse() {
    final statement = switch (_word) {
      'CREATE' => _create(),
      'ALTER' => _alterTable(),
      'BEGIN' => _begin(),
      'COMMIT' => _commit(),
      'END' => _commit(),
      'ROLLBACK' => _rollback(),
      'PRAGMA' => _pragma(),
      'INSERT' => _insert(),
      'SELECT' => _select(),
      'UPDATE' => _update(),
      'DELETE' => _delete(),
      _ => throw PureSqlException('unsupported statement: ${_peek.text}'),
    };
    if (_accept(';')) {}
    _expectType(_TokenType.eof);
    return statement;
  }

  _Statement _create() {
    _expectWord('CREATE');
    final unique = _acceptWord('UNIQUE');
    if (_acceptWord('INDEX')) return _createIndex(unique);
    _expectWord('TABLE');
    final ifNotExists =
        _acceptWord('IF') && _acceptWord('NOT') && _acceptWord('EXISTS');
    final name = _identifier();
    _expect('(');
    final columns = <_ColumnDef>[];
    final primaryKeyColumns = <String>[];
    final checks = <_Expr>[];
    do {
      if (_acceptWord('PRIMARY')) {
        _expectWord('KEY');
        _expect('(');
        primaryKeyColumns.add(_identifier());
        while (_accept(',')) primaryKeyColumns.add(_identifier());
        _expect(')');
      } else if (_acceptWord('CHECK')) {
        checks.add(_checkExpression());
      } else {
        final columnName = _identifier();
        final typeName = _peek.type == _TokenType.word ? _advance().text : null;
        var notNull = false;
        var primaryKey = false;
        var unique = false;
        _Expr? defaultExpression;
        String? referencesTable;
        String? referencesColumn;
        String? collation;
        final columnChecks = <_Expr>[];
        while (_peek.type == _TokenType.word) {
          if (_acceptWord('NOT')) {
            _expectWord('NULL');
            notNull = true;
          } else if (_acceptWord('PRIMARY')) {
            _expectWord('KEY');
            primaryKey = true;
          } else if (_acceptWord('UNIQUE')) {
            unique = true;
          } else if (_acceptWord('DEFAULT')) {
            defaultExpression = _primary();
          } else if (_acceptWord('REFERENCES')) {
            referencesTable = _identifier();
            if (_accept('(')) {
              referencesColumn = _identifier();
              _expect(')');
            }
          } else if (_acceptWord('COLLATE')) {
            collation = _identifier().toUpperCase();
            if (!const ['BINARY', 'NOCASE'].contains(collation)) {
              throw PureSqlException('unsupported collation: $collation');
            }
          } else if (_acceptWord('CHECK')) {
            columnChecks.add(_checkExpression());
          } else {
            break;
          }
        }
        columns.add(
          _ColumnDef(
            columnName,
            typeName: typeName,
            notNull: notNull,
            primaryKey: primaryKey,
            unique: unique,
            defaultExpression: defaultExpression,
            referencesTable: referencesTable,
            referencesColumn: referencesColumn,
            collation: collation,
            checkExpressions: columnChecks,
          ),
        );
      }
    } while (_accept(','));
    _expect(')');
    return _CreateTable(
      name,
      columns,
      ifNotExists,
      primaryKeyColumns: primaryKeyColumns,
      checkExpressions: checks,
    );
  }

  _Expr _checkExpression() {
    _expect('(');
    final expression = _expression();
    _expect(')');
    return expression;
  }

  _Statement _createIndex(bool unique) {
    final ifNotExists =
        _acceptWord('IF') && _acceptWord('NOT') && _acceptWord('EXISTS');
    final name = _identifier();
    _expectWord('ON');
    final table = _identifier();
    _expect('(');
    final columns = <String>[];
    final descending = <bool>[];
    do {
      columns.add(_identifier());
      final isDescending = _acceptWord('DESC');
      if (!isDescending) _acceptWord('ASC');
      descending.add(isDescending);
    } while (_accept(','));
    _expect(')');
    final where = _acceptWord('WHERE') ? _expression() : null;
    return _CreateIndex(
      name,
      table,
      columns,
      unique: unique,
      ifNotExists: ifNotExists,
      descending: descending,
      where: where,
    );
  }

  _Statement _pragma() {
    _expectWord('PRAGMA');
    final name = _identifier();
    final value = _accept('=') ? _expression() : null;
    return _Pragma(name, value);
  }

  _Statement _begin() {
    _expectWord('BEGIN');
    if (_peek.type == _TokenType.word) {
      final mode = _advance().text.toUpperCase();
      if (!const ['DEFERRED', 'IMMEDIATE', 'EXCLUSIVE'].contains(mode)) {
        throw PureSqlException('unsupported BEGIN mode: $mode');
      }
    }
    return _Begin();
  }

  _Statement _commit() {
    _advance();
    return _Commit();
  }

  _Statement _rollback() {
    _expectWord('ROLLBACK');
    return _Rollback();
  }

  _Statement _alterTable() {
    _expectWord('ALTER');
    _expectWord('TABLE');
    final table = _identifier();
    _expectWord('ADD');
    _acceptWord('COLUMN');
    final name = _identifier();
    final typeName = _peek.type == _TokenType.word ? _advance().text : null;
    var notNull = false;
    _Expr? defaultExpression;
    while (_peek.type == _TokenType.word) {
      if (_acceptWord('NOT')) {
        _expectWord('NULL');
        notNull = true;
      } else if (_acceptWord('DEFAULT')) {
        defaultExpression = _primary();
      } else {
        throw PureSqlException('unsupported ALTER TABLE option: ${_peek.text}');
      }
    }
    return _AlterTable(
      table,
      _ColumnDef(
        name,
        typeName: typeName,
        notNull: notNull,
        defaultExpression: defaultExpression,
      ),
    );
  }

  _Statement _insert() {
    _expectWord('INSERT');
    var conflict = 'abort';
    if (_acceptWord('OR')) {
      if (_acceptWord('IGNORE')) {
        conflict = 'ignore';
      } else if (_acceptWord('REPLACE')) {
        conflict = 'replace';
      } else {
        throw PureSqlException('unsupported INSERT conflict action');
      }
    }
    _expectWord('INTO');
    final table = _identifier();
    List<String>? columns;
    if (_accept('(')) {
      columns = [_identifier()];
      while (_accept(',')) columns.add(_identifier());
      _expect(')');
    }
    _expectWord('VALUES');
    _expect('(');
    final values = [_expression()];
    while (_accept(',')) values.add(_expression());
    _expect(')');
    return _Insert(table, columns, values, conflict: conflict);
  }

  _Statement _select() {
    _expectWord('SELECT');
    final items = <_SelectItem>[];
    if (_accept('*')) {
      items.add(_SelectItem(_Column('*'), '*'));
    } else {
      do {
        final expression = _expression();
        final name = _acceptWord('AS')
            ? _identifier()
            : expression is _Column
            ? expression.name
            : 'column${items.length + 1}';
        items.add(_SelectItem(expression, name));
      } while (_accept(','));
    }
    _expectWord('FROM');
    final table = _identifier();
    final alias = _acceptWord('AS')
        ? _identifier()
        : _acceptAlias(_peek.text)
        ? _identifier()
        : null;
    final joins = <_Join>[];
    while (true) {
      var left = false;
      if (_acceptWord('LEFT')) {
        left = true;
        _acceptWord('OUTER');
      }
      if (!_acceptWord('JOIN')) {
        if (left) throw PureSqlException('expected JOIN');
        break;
      }
      final joinedTable = _identifier();
      final alias = _acceptWord('AS')
          ? _identifier()
          : _acceptAlias(_peek.text)
          ? _identifier()
          : null;
      _expectWord('ON');
      joins.add(_Join(joinedTable, alias, _expression(), left));
    }
    final where = _acceptWord('WHERE') ? _expression() : null;
    final groupBy = <_Expr>[];
    if (_acceptWord('GROUP')) {
      _expectWord('BY');
      groupBy.add(_expression());
      while (_accept(',')) groupBy.add(_expression());
    }
    final order = <_Order>[];
    if (_acceptWord('ORDER')) {
      _expectWord('BY');
      do {
        var name = _identifier();
        if (_accept('.')) name = '$name.${_identifier()}';
        var noCase = false;
        if (_acceptWord('COLLATE')) {
          _expectWord('NOCASE');
          noCase = true;
        }
        final descending = _acceptWord('DESC');
        if (!descending) _acceptWord('ASC');
        order.add(_Order(name, descending, noCase));
      } while (_accept(','));
    }
    final limit = _acceptWord('LIMIT') ? _expression() : null;
    final offset = _acceptWord('OFFSET') ? _expression() : null;
    return _Select(
      items,
      table,
      alias,
      joins,
      where,
      groupBy,
      order,
      limit,
      offset,
    );
  }

  bool _acceptAlias(String word) =>
      _peek.type == _TokenType.word &&
      !const [
        'WHERE',
        'ORDER',
        'LIMIT',
        'GROUP',
        'JOIN',
        'LEFT',
        'ON',
      ].contains(word.toUpperCase());

  _Statement _update() {
    _expectWord('UPDATE');
    final table = _identifier();
    _expectWord('SET');
    final assignments = <String, _Expr>{};
    do {
      final name = _identifier();
      _expect('=');
      assignments[name] = _expression();
    } while (_accept(','));
    final where = _acceptWord('WHERE') ? _expression() : null;
    return _Update(table, assignments, where);
  }

  _Statement _delete() {
    _expectWord('DELETE');
    _expectWord('FROM');
    final table = _identifier();
    final where = _acceptWord('WHERE') ? _expression() : null;
    return _Delete(table, where);
  }

  _Expr _expression() => _or();

  _Expr _or() {
    var result = _and();
    while (_acceptWord('OR')) result = _Binary(result, 'OR', _and());
    return result;
  }

  _Expr _and() {
    var result = _comparison();
    while (_acceptWord('AND')) result = _Binary(result, 'AND', _comparison());
    return result;
  }

  _Expr _comparison() {
    var result = _additive();
    if (_peek.type == _TokenType.symbol &&
        const ['=', '!=', '<>', '<', '<=', '>', '>='].contains(_peek.text)) {
      final operator = _advance().text;
      result = _Binary(result, operator, _additive());
    } else if (_acceptWord('IS')) {
      final operator = _acceptWord('NOT') ? 'IS NOT' : 'IS';
      result = _Binary(result, operator, _additive());
    } else if (_acceptWord('LIKE')) {
      result = _Binary(result, 'LIKE', _additive());
    } else if (_acceptWord('NOT')) {
      if (!_acceptWord('IN')) throw PureSqlException('expected IN');
      result = _In(result, _inValues(), true);
    } else if (_acceptWord('IN')) {
      result = _In(result, _inValues(), false);
    }
    return result;
  }

  _Expr _additive() {
    var result = _multiplicative();
    while (_peek.type == _TokenType.symbol &&
        const ['+', '-'].contains(_peek.text)) {
      result = _Binary(result, _advance().text, _multiplicative());
    }
    return result;
  }

  _Expr _multiplicative() {
    var result = _primary();
    while (_peek.type == _TokenType.symbol &&
        const ['*', '/'].contains(_peek.text)) {
      result = _Binary(result, _advance().text, _primary());
    }
    return result;
  }

  List<_Expr> _inValues() {
    _expect('(');
    final values = <_Expr>[_expression()];
    while (_accept(',')) values.add(_expression());
    _expect(')');
    return values;
  }

  _Expr _primary() {
    if (_accept('(')) {
      if (_word == 'SELECT') {
        final query = _select();
        _expect(')');
        if (query is! _Select) {
          throw PureSqlException('scalar subquery must contain SELECT');
        }
        return _ScalarSubquery(query);
      }
      final result = _expression();
      _expect(')');
      return result;
    }
    final token = _advance();
    if (token.type == _TokenType.parameter) {
      final index = token.text.length == 1
          ? _nextParameter++
          : int.parse(token.text.substring(1)) - 1;
      return _Param(index);
    }
    if (token.type == _TokenType.string) return _Literal(token.value);
    if (token.type == _TokenType.number)
      return _Literal(
        token.text.contains('.')
            ? double.parse(token.text)
            : int.parse(token.text),
      );
    if (token.type == _TokenType.word) {
      final word = token.text.toUpperCase();
      if (word == 'CASE') {
        final branches = <(_Expr, _Expr)>[];
        while (_acceptWord('WHEN')) {
          final condition = _expression();
          _expectWord('THEN');
          branches.add((condition, _expression()));
        }
        final otherwise = _acceptWord('ELSE') ? _expression() : null;
        _expectWord('END');
        return _Case(branches, otherwise);
      }
      if (word == 'NULL') return _Literal(null);
      if (word == 'TRUE') return _Literal(1);
      if (word == 'FALSE') return _Literal(0);
      if (word == 'ON') return _Literal(1);
      if (word == 'OFF') return _Literal(0);
      if (_accept('(')) {
        final distinct = _acceptWord('DISTINCT');
        final arguments = <_Expr>[];
        if (_accept('*')) {
          arguments.add(_Column('*'));
        } else {
          arguments.add(_expression());
          while (_accept(',')) arguments.add(_expression());
        }
        _expect(')');
        return _Function(token.text, arguments, distinct: distinct);
      }
      if (_accept('.')) {
        return _Column(
          _accept('*') ? '${token.text}.*' : '${token.text}.${_identifier()}',
        );
      }
      return _Column(token.text);
    }
    throw PureSqlException('expected expression, got ${token.text}');
  }

  String get _word =>
      _peek.type == _TokenType.word ? _peek.text.toUpperCase() : '';
  _Token get _peek => _tokens[_index];
  _Token _advance() => _tokens[_index++];

  String _identifier() {
    final token = _advance();
    if (token.type != _TokenType.word)
      throw PureSqlException('expected identifier');
    return token.text;
  }

  void _expect(String text) {
    if (!_accept(text))
      throw PureSqlException('expected "$text", got "${_peek.text}"');
  }

  void _expectWord(String word) {
    if (!_acceptWord(word))
      throw PureSqlException('expected $word, got ${_peek.text}');
  }

  void _expectType(_TokenType type) {
    if (_peek.type != type)
      throw PureSqlException('unexpected token: ${_peek.text}');
  }

  bool _accept(String text) {
    if (_peek.text != text) return false;
    _advance();
    return true;
  }

  bool _acceptWord(String word) {
    if (_word != word) return false;
    _advance();
    return true;
  }
}
