/// A deliberately small, dependency-free, SQLite-compatible subset.
///
/// It supports an in-memory SQL engine and a growing, partially compatible
/// SQLite 3 file format.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'src/sqlite_format.dart';
import 'src/table_btree.dart';
import 'src/index_btree.dart';

export 'src/sqlite_format.dart';
export 'src/table_btree.dart';
export 'src/index_btree.dart';

/// A SQL result row, keyed by the selected column names.
typedef SqlRow = Map<String, Object?>;

/// An error raised for unsupported SQL or a failed database operation.
class SqliteException implements Exception {
  /// Creates an exception with a human-readable [message].
  SqliteException(this.message);

  /// The reason the SQL operation failed.
  final String message;

  @override
  String toString() => 'SqliteException: $message';
}

class _ConflictFailException implements Exception {
  _ConflictFailException(this.error, this.stackTrace, this.changes);

  final Object error;
  final StackTrace stackTrace;
  final int changes;
}

/// Compatibility name for [SqliteException].
typedef PureSqlException = SqliteException;

/// A synchronous SQLite-compatible database.
///
/// Use [memory] for a transient database or [open] for a persistent SQLite
/// file. The supported SQL syntax is a subset of SQLite; unsupported
/// statements throw [SqliteException].
class PureDatabase {
  PureDatabase._(Map<String, _Table> tables, [this._pager])
    : _tables = tables,
      _indexes = {},
      _views = {},
      _viewStack = {};

  /// Creates an in-memory database that is discarded when closed.
  factory PureDatabase.memory() => PureDatabase._({});

  /// Opens or creates a persistent SQLite database at [path].
  ///
  /// [busyTimeout] controls how long lock acquisition waits before failing.
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
  Map<String, _CreateView> _views;
  final Set<String> _viewStack;
  SqlitePagerSync? _pager;
  var _userVersion = 0;
  var _applicationId = 0;
  var _schemaVersion = 1;
  var _foreignKeys = false;
  var _synchronous = 2;
  var _inTransaction = false;
  var _walTransaction = false;
  SqliteRollbackJournal? _transactionJournal;
  Map<String, _Table>? _memoryTransactionTables;
  Map<String, _CreateView>? _memoryTransactionViews;
  int? _memoryTransactionSchemaVersion;

  /// Executes one supported SQL statement with a positional list or named map.
  ///
  /// Returns the number of rows changed by `INSERT`, `UPDATE`, or `DELETE`;
  /// other supported statements return zero.
  int execute(String sql, [Object? parameters = const []]) {
    final statements = _splitSqlStatements(sql);
    if (statements.isEmpty) throw PureSqlException('SQL is empty');
    if (statements.length > 1 && _hasBoundParameters(parameters)) {
      throw PureSqlException('parameters are not supported for SQL scripts');
    }
    var changed = 0;
    for (final statementSql in statements) {
      changed += _executeOne(statementSql, parameters);
    }
    return changed;
  }

  int _executeOne(String sql, Object? parameters) {
    final parser = _Parser(sql);
    final statement = parser.parse();
    final values = _bindParameters(parser, parameters);
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
    int run() {
      final changesSchema = _changesSchema(statement);
      final changed = _execute(statement, values, sql);
      if (changesSchema) _incrementSchemaVersion();
      return changed;
    }

    if (_pager != null && !_inTransaction && statement is! _Select) {
      _ConflictFailException? failure;
      final changed = _persistentWrite(() {
        try {
          return run();
        } on _ConflictFailException catch (error) {
          failure = error;
          return error.changes;
        }
      });
      if (failure != null) {
        Error.throwWithStackTrace(failure!.error, failure!.stackTrace);
      }
      return changed;
    }
    try {
      return run();
    } on _ConflictFailException catch (failure) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
  }

  bool _changesSchema(_Statement statement) => switch (statement) {
    _CreateTable(:final name) => !_tables.containsKey(_key(name)),
    _CreateView(:final name) =>
      !_views.containsKey(_key(name)) &&
          !_tables.containsKey(_key(name)) &&
          !_indexes.containsKey(_key(name)),
    _CreateIndex(:final name) => !_indexes.containsKey(_key(name)),
    _RenameTable() || _RenameColumn() || _DropColumn() || _AlterTable() => true,
    _Drop(:final type, :final name) => switch (type) {
      'table' => _tables.containsKey(_key(name)),
      'view' => _views.containsKey(_key(name)),
      'index' => _indexes.containsKey(_key(name)),
      _ => false,
    },
    _ => false,
  };

  void _incrementSchemaVersion() {
    final pager = _pager;
    if (pager == null) {
      _schemaVersion = (_schemaVersion + 1) & 0xffffffff;
      return;
    }
    pager.header.schemaCookie = (pager.header.schemaCookie + 1) & 0xffffffff;
    _schemaVersion = pager.header.schemaCookie;
    pager.writePage(1, pager.readPage(1));
  }

  /// Runs a `SELECT` or read-only `PRAGMA` and returns its rows.
  ///
  /// Bind positional placeholders with a list and named placeholders with a map.
  List<SqlRow> select(String sql, [Object? parameters = const []]) {
    final parser = _Parser(sql);
    final statement = parser.parse();
    final values = _bindParameters(parser, parameters);
    if (statement is _Pragma) {
      if (statement.value != null) {
        throw PureSqlException('PRAGMA assignment must use execute()');
      }
      return _withCurrentFile(() => _pragmaRows(statement, values));
    }
    if (statement is! _Select) {
      throw PureSqlException('Only SELECT can be used with select()');
    }
    return _withCurrentFile(() => _select(statement, values));
  }

  /// Commits [action] on success and rolls it back if [action] throws.
  ///
  /// Nested transactions are not supported for persistent databases.
  T transaction<T>(T Function(PureDatabase database) action) {
    if (_pager == null) {
      final before = _cloneTables(_tables);
      final beforeViews = Map<String, _CreateView>.of(_views);
      final beforeSchemaVersion = _schemaVersion;
      try {
        return action(this);
      } catch (_) {
        _tables = before;
        _views = beforeViews;
        _indexes = {
          for (final table in before.values)
            for (final index in table.indexes) _key(index.name): index,
        };
        _schemaVersion = beforeSchemaVersion;
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
        _CreateView() => _createView(statement, sql: sql),
        _Drop() => _drop(statement),
        _CreateIndex() => _createIndex(statement, sql: sql),
        _Pragma() => _pragma(statement, values),
        _RenameTable() => _renameTable(statement),
        _RenameColumn() => _renameColumn(statement),
        _DropColumn() => _dropColumn(statement),
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
      _memoryTransactionViews = Map.of(_views);
      _memoryTransactionSchemaVersion = _schemaVersion;
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
      _memoryTransactionViews = null;
      _memoryTransactionSchemaVersion = null;
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
      _views = _memoryTransactionViews!;
      _schemaVersion = _memoryTransactionSchemaVersion!;
      _indexes = {
        for (final table in _tables.values)
          for (final index in table.indexes) _key(index.name): index,
      };
    } else if (_walTransaction) {
      try {
        _pager!.rollbackWalTransaction();
        _refreshFile();
      } finally {
        _memoryTransactionTables = null;
        _memoryTransactionViews = null;
        _memoryTransactionSchemaVersion = null;
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
        _memoryTransactionViews = null;
        _memoryTransactionSchemaVersion = null;
        _inTransaction = false;
        _pager!.releaseExclusiveLock();
      }
    }
    _transactionJournal = null;
    _memoryTransactionTables = null;
    _memoryTransactionSchemaVersion = null;
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
    _applicationId = _pager!.header.applicationId;
    _userVersion = _pager!.header.userVersion;
    _schemaVersion = _pager!.header.schemaCookie;
    _tables = {};
    _indexes = {};
    _views = {};
    _loadFile();
  }

  int _create(_CreateTable statement, {required String sql}) {
    final key = _key(statement.name);
    if (_tables.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('table already exists: ${statement.name}');
    }
    if (_pager == null) {
      final table = _Table(
        statement.name,
        statement.columns,
        schemaSql: sql.trim(),
        primaryKeyColumns: statement.primaryKeyColumns,
        checkExpressions: statement.checkExpressions,
        uniqueConstraints: statement.uniqueConstraints,
        foreignKeyConstraints: statement.foreignKeyConstraints,
      );
      _tables[key] = table;
      final constraints = <List<String>>[
        for (final column in table.columns)
          if ((column.primaryKey || column.unique) &&
              column != table.rowIdColumn)
            [column.name],
        if (table.primaryKeyColumns.isNotEmpty &&
            !(table.primaryKeyColumns.length == 1 &&
                table.rowIdColumn?.name == table.primaryKeyColumns.single))
          table.primaryKeyColumns,
        ...table.uniqueConstraints,
      ];
      for (var index = 0; index < constraints.length; index++) {
        final uniqueIndex = _Index(
          'sqlite_autoindex_${table.name}_${index + 1}',
          table,
          constraints[index],
          unique: true,
        );
        table.indexes.add(uniqueIndex);
        _indexes[_key(uniqueIndex.name)] = uniqueIndex;
      }
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
      uniqueConstraints: statement.uniqueConstraints,
      foreignKeyConstraints: statement.foreignKeyConstraints,
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
      ...statement.uniqueConstraints,
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

  int _createView(_CreateView statement, {required String sql}) {
    final key = _key(statement.name);
    if (_tables.containsKey(key) ||
        _indexes.containsKey(key) ||
        _views.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('view already exists: ${statement.name}');
    }
    statement.schemaSql = sql.trim();
    _views[key] = statement;
    final pager = _pager;
    if (pager != null) {
      SqliteTableBtree.insertRow(pager, 1, _nextSchemaRowId(), [
        'view',
        statement.name,
        statement.name,
        0,
        sql.trim(),
      ], pageStart: 100);
    }
    return 0;
  }

  int _renameTable(_RenameTable statement) {
    final oldKey = _key(statement.table);
    final newKey = _key(statement.newName);
    final table = _table(statement.table);
    if (_tables.containsKey(newKey) ||
        _indexes.containsKey(newKey) ||
        _views.containsKey(newKey) ||
        newKey.startsWith('sqlite_')) {
      throw PureSqlException('table already exists: ${statement.newName}');
    }
    final oldName = table.name;
    final oldSql = table.schemaSql;
    if (oldSql == null) throw SqliteFormatException('missing table SQL');
    final newSql = _renameSqlIdentifiersAfter(
      _renameSqlIdentifiersAfter(oldSql, oldName, statement.newName, 'table'),
      oldName,
      statement.newName,
      'references',
    );
    final renamedViews = <String, _CreateView>{};
    for (final entry in _views.entries) {
      final viewSql = entry.value.schemaSql;
      if (viewSql == null) throw SqliteFormatException('missing view SQL');
      final renamedSql = _renameSqlIdentifiersAfter(
        viewSql,
        oldName,
        statement.newName,
        'source',
      );
      if (renamedSql != viewSql) {
        final parsed = _Parser(renamedSql).parse();
        if (parsed is! _CreateView) {
          throw SqliteFormatException('invalid view SQL');
        }
        parsed.schemaSql = renamedSql;
        renamedViews[entry.key] = parsed;
      }
    }

    final pager = _pager;
    if (pager != null) {
      final schemaRows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
      final updatedRows = [
        for (final row in schemaRows)
          _renameSchemaRow(row, oldName, statement.newName, newSql),
      ];
      SqliteTableBtree.rewriteRows(pager, 1, updatedRows, pageStart: 100);
    }

    _tables.remove(oldKey);
    table.name = statement.newName;
    table.schemaSql = newSql;
    _tables[newKey] = table;
    final autoIndexPrefix = 'sqlite_autoindex_${oldName}_';
    for (final index in table.indexes) {
      if (!_key(index.name).startsWith(_key(autoIndexPrefix))) continue;
      final suffix = index.name.substring(autoIndexPrefix.length);
      _indexes.remove(_key(index.name));
      index.name = 'sqlite_autoindex_${statement.newName}_$suffix';
      _indexes[_key(index.name)] = index;
    }
    for (final other in _tables.values) {
      final schemaSql = other.schemaSql;
      if (schemaSql != null) {
        other.schemaSql = _renameSqlIdentifiersAfter(
          schemaSql,
          oldName,
          statement.newName,
          'references',
        );
      }
      for (final column in other.columns) {
        if (column.referencesTable != null &&
            _key(column.referencesTable!) == oldKey) {
          column.referencesTable = statement.newName;
        }
      }
      for (final foreignKey in other.foreignKeyConstraints) {
        if (_key(foreignKey.table) == oldKey) {
          foreignKey.table = statement.newName;
        }
      }
    }
    _views.addAll(renamedViews);
    return 0;
  }

  int _renameColumn(_RenameColumn statement) {
    final table = _table(statement.table);
    final column = table.column(statement.oldName);
    if (table.columns.any(
      (other) => _key(other.name) == _key(statement.newName),
    )) {
      throw PureSqlException('duplicate column name: ${statement.newName}');
    }
    if (table.indexes.isNotEmpty ||
        table.checkExpressions.isNotEmpty ||
        table.uniqueConstraints.isNotEmpty ||
        table.foreignKeyConstraints.isNotEmpty ||
        table.columns.any(
          (item) =>
              item.checkExpressions.isNotEmpty || item.referencesTable != null,
        )) {
      throw PureSqlException(
        'cannot rename a column with indexes, checks, or foreign keys',
      );
    }
    for (final other in _tables.values) {
      for (final foreignKey in _foreignKeysFor(other)) {
        if (_key(foreignKey.table) == _key(table.name) &&
            _referencedColumns(
              foreignKey,
              table,
            ).any((name) => _key(name) == _key(column.name))) {
          throw PureSqlException(
            'cannot rename a column referenced by a foreign key',
          );
        }
      }
    }
    for (final view in _views.values) {
      final viewSql = view.schemaSql;
      if (viewSql == null) throw SqliteFormatException('missing view SQL');
      if (_renameSqlIdentifiersAfter(
            viewSql,
            table.name,
            '__rename_probe__',
            'source',
          ) !=
          viewSql) {
        throw PureSqlException('cannot rename a column referenced by a view');
      }
    }
    final oldSql = table.schemaSql;
    if (oldSql == null) throw SqliteFormatException('missing table SQL');
    final newSql = _renameSingleColumnToken(
      oldSql,
      table.name,
      column.name,
      statement.newName,
    );
    final parsed = _Parser(newSql).parse();
    if (parsed is! _CreateTable ||
        parsed.columns.length != table.columns.length) {
      throw SqliteFormatException('invalid renamed CREATE TABLE SQL');
    }
    final before = _snapshotRows();
    final oldColumns = List<_ColumnDef>.from(table.columns);
    final oldColumnName = column.name;
    try {
      column.name = statement.newName;
      for (final row in table.rows) {
        final previous = Map<String, Object?>.from(row);
        row
          ..clear()
          ..addAll({
            for (final item in table.columns)
              item.name:
                  previous[_key(item.name) == _key(statement.newName)
                      ? oldColumnName
                      : item.name],
          });
      }
      table.schemaSql = newSql;
      final pager = _pager;
      if (pager != null) {
        _rewriteTable(pager, table);
        final schemaRows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
        SqliteTableBtree.rewriteRows(pager, 1, [
          for (final row in schemaRows)
            row.values.length >= 5 &&
                    row.values[0] == 'table' &&
                    _key(row.values[1].toString()) == _key(table.name)
                ? SqliteBtreeRow(row.rowId, [...row.values]..[4] = newSql)
                : row,
        ], pageStart: 100);
      }
    } catch (_) {
      column.name = oldColumnName;
      table.columns
        ..clear()
        ..addAll(oldColumns);
      table.schemaSql = oldSql;
      _restoreRows(before);
      rethrow;
    }
    return 0;
  }

  int _dropColumn(_DropColumn statement) {
    final table = _table(statement.table);
    final column = table.column(statement.name);
    if (table.columns.length == 1 ||
        table.rowIdColumn == column ||
        table.indexes.isNotEmpty ||
        table.primaryKeyColumns.isNotEmpty ||
        table.checkExpressions.isNotEmpty ||
        table.uniqueConstraints.isNotEmpty ||
        table.foreignKeyConstraints.isNotEmpty ||
        column.primaryKey ||
        column.unique ||
        table.columns.any(
          (item) =>
              item.checkExpressions.isNotEmpty || item.referencesTable != null,
        )) {
      throw PureSqlException(
        'cannot drop a column with indexes or constraints',
      );
    }
    for (final child in _tables.values) {
      for (final foreignKey in _foreignKeysFor(child)) {
        if (_key(foreignKey.table) == _key(table.name) &&
            _referencedColumns(
              foreignKey,
              table,
            ).any((name) => _key(name) == _key(column.name))) {
          throw PureSqlException(
            'cannot drop a column referenced by a foreign key',
          );
        }
      }
    }
    for (final view in _views.values) {
      final viewSql = view.schemaSql;
      if (viewSql == null) throw SqliteFormatException('missing view SQL');
      if (_renameSqlIdentifiersAfter(
            viewSql,
            table.name,
            '__drop_probe__',
            'source',
          ) !=
          viewSql) {
        throw PureSqlException('cannot drop a column referenced by a view');
      }
    }
    final oldSql = table.schemaSql;
    if (oldSql == null) throw SqliteFormatException('missing table SQL');
    final newSql = _dropSingleColumnDefinition(oldSql, table.name, column.name);
    final parsed = _Parser(newSql).parse();
    if (parsed is! _CreateTable ||
        parsed.columns.length != table.columns.length - 1) {
      throw SqliteFormatException('invalid CREATE TABLE after DROP COLUMN');
    }
    final before = _snapshotRows();
    final oldColumns = List<_ColumnDef>.from(table.columns);
    try {
      table.columns
        ..clear()
        ..addAll(parsed.columns);
      for (final row in table.rows) {
        row.remove(column.name);
      }
      table.schemaSql = newSql;
      final pager = _pager;
      if (pager != null) {
        _rewriteTable(pager, table);
        final schemaRows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
        SqliteTableBtree.rewriteRows(pager, 1, [
          for (final row in schemaRows)
            row.values.length >= 5 &&
                    row.values[0] == 'table' &&
                    _key(row.values[1].toString()) == _key(table.name)
                ? SqliteBtreeRow(row.rowId, [...row.values]..[4] = newSql)
                : row,
        ], pageStart: 100);
      }
    } catch (_) {
      table.columns
        ..clear()
        ..addAll(oldColumns);
      table.schemaSql = oldSql;
      _restoreRows(before);
      rethrow;
    }
    return 0;
  }

  SqliteBtreeRow _renameSchemaRow(
    SqliteBtreeRow row,
    String oldName,
    String newName,
    String renamedTableSql,
  ) {
    if (row.values.length < 5) return row;
    final values = List<Object?>.from(row.values);
    final type = values[0];
    if (type == 'table' && values[4] is String) {
      final rowName = values[1]?.toString() ?? '';
      values[4] = _key(rowName) == _key(oldName)
          ? renamedTableSql
          : _renameSqlIdentifiersAfter(
              values[4] as String,
              oldName,
              newName,
              'references',
            );
      if (_key(rowName) == _key(oldName)) {
        values[1] = newName;
        values[2] = newName;
      }
    } else if (type == 'index' &&
        _key(values[2]?.toString() ?? '') == _key(oldName)) {
      values[2] = newName;
      final indexName = values[1]?.toString() ?? '';
      final autoIndexPrefix = 'sqlite_autoindex_${oldName}_';
      if (_key(indexName).startsWith(_key(autoIndexPrefix))) {
        values[1] =
            'sqlite_autoindex_${newName}_'
            '${indexName.substring(autoIndexPrefix.length)}';
      }
      if (values[4] is String) {
        values[4] = _renameSqlIdentifiersAfter(
          values[4] as String,
          oldName,
          newName,
          'index',
        );
      }
    } else if (type == 'view' && values[4] is String) {
      values[4] = _renameSqlIdentifiersAfter(
        values[4] as String,
        oldName,
        newName,
        'source',
      );
    }
    return SqliteBtreeRow(row.rowId, values);
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
    if (name == 'application_id') {
      final applicationId = _asInt(value);
      if (applicationId < 0 || applicationId > 0xffffffff) {
        throw PureSqlException(
          'application_id must be an unsigned 32-bit integer',
        );
      }
      _applicationId = applicationId;
      final pager = _pager;
      if (pager != null) {
        pager.header.applicationId = applicationId;
        pager.writePage(1, pager.readPage(1));
      }
      return 0;
    }
    if (name == 'schema_version') {
      final version = _asInt(value);
      if (version < 0 || version > 0xffffffff) {
        throw PureSqlException(
          'schema_version must be an unsigned 32-bit integer',
        );
      }
      _schemaVersion = version;
      final pager = _pager;
      if (pager != null) {
        pager.header.schemaCookie = version;
        pager.writePage(1, pager.readPage(1));
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
    if (name == 'application_id') {
      return _pager?.header.applicationId ?? _applicationId;
    }
    if (name == 'schema_version') {
      return _pager?.header.schemaCookie ?? _schemaVersion;
    }
    if (name == 'encoding') return 'UTF-8';
    if (name == 'page_size') return _pager?.header.pageSize ?? 4096;
    if (name == 'page_count') return _pager?.pageCount ?? 0;
    if (name == 'freelist_count') {
      return _pager?.header.freelistPageCount ?? 0;
    }
    if (name == 'auto_vacuum') return 0;
    throw PureSqlException('unsupported PRAGMA: ${statement.name}');
  }

  List<SqlRow> _pragmaRows(_Pragma statement, List<Object?> parameters) {
    final name = _key(statement.name);
    if (name == 'pragma_list') {
      return [
        for (final pragma in const [
          'application_id',
          'auto_vacuum',
          'busy_timeout',
          'collation_list',
          'database_list',
          'encoding',
          'foreign_key_check',
          'foreign_key_list',
          'foreign_keys',
          'freelist_count',
          'function_list',
          'index_info',
          'index_list',
          'index_xinfo',
          'integrity_check',
          'journal_mode',
          'page_count',
          'page_size',
          'pragma_list',
          'quick_check',
          'schema_version',
          'synchronous',
          'table_info',
          'table_list',
          'table_xinfo',
          'user_version',
        ])
          {'name': pragma},
      ];
    }
    if (name == 'table_info' || name == 'table_xinfo') {
      final table = _pragmaTable(statement, parameters);
      return [
        for (var index = 0; index < table.columns.length; index++)
          {
            'cid': index,
            'name': table.columns[index].name,
            'type': table.columns[index].typeName ?? '',
            'notnull': table.columns[index].notNull ? 1 : 0,
            'dflt_value': table.columns[index].defaultExpression == null
                ? null
                : _expressionSql(table.columns[index].defaultExpression!),
            'pk': _primaryKeyPosition(table, table.columns[index]),
            if (name == 'table_xinfo') 'hidden': 0,
          },
      ];
    }
    if (name == 'index_list') {
      final table = _pragmaTable(statement, parameters);
      return [
        for (var index = 0; index < table.indexes.length; index++)
          {
            'seq': index,
            'name': table.indexes[index].name,
            'unique': table.indexes[index].unique ? 1 : 0,
            'origin': _indexOrigin(table, table.indexes[index]),
            'partial': table.indexes[index].where == null ? 0 : 1,
          },
      ];
    }
    if (name == 'index_info' || name == 'index_xinfo') {
      final argument = statement.argument;
      if (argument == null) {
        throw PureSqlException('PRAGMA $name requires an index name');
      }
      final indexName = _pragmaInput(argument, parameters).toString();
      final index = _indexes[_key(indexName)];
      if (index == null) throw PureSqlException('no such index: $indexName');
      return [
        for (var position = 0; position < index.columns.length; position++)
          {
            if (name == 'index_info') 'seqno': position,
            if (name == 'index_xinfo') 'seqno': position,
            if (name == 'index_info')
              'cid': index.table.columns.indexWhere(
                (column) => _key(column.name) == _key(index.columns[position]),
              ),
            if (name == 'index_xinfo')
              'cid': index.table.columns.indexWhere(
                (column) => _key(column.name) == _key(index.columns[position]),
              ),
            'name': index.columns[position],
            if (name == 'index_xinfo')
              'desc':
                  position < index.descending.length &&
                      index.descending[position]
                  ? 1
                  : 0,
            if (name == 'index_xinfo')
              'coll':
                  index.table.column(index.columns[position]).collation ??
                  'BINARY',
            if (name == 'index_xinfo') 'key': 1,
          },
        if (name == 'index_xinfo')
          {
            'seqno': index.columns.length,
            'cid': -1,
            'name': null,
            'desc': 0,
            'coll': 'BINARY',
            'key': 0,
          },
      ];
    }
    if (name == 'foreign_key_list') {
      final table = _pragmaTable(statement, parameters);
      final foreignKeys = _foreignKeysFor(table);
      return [
        for (var id = 0; id < foreignKeys.length; id++)
          for (var seq = 0; seq < foreignKeys[id].columns.length; seq++)
            {
              'id': id,
              'seq': seq,
              'table': foreignKeys[id].table,
              'from': foreignKeys[id].columns[seq],
              'to': foreignKeys[id].referencedColumns.length > seq
                  ? foreignKeys[id].referencedColumns[seq]
                  : null,
              'on_update': foreignKeys[id].onUpdate,
              'on_delete': foreignKeys[id].onDelete,
              'match': 'NONE',
            },
      ];
    }
    if (name == 'foreign_key_check') {
      final tables = statement.argument == null
          ? _tables.values
          : [_pragmaTable(statement, parameters)];
      final violations = <SqlRow>[];
      for (final table in tables) {
        final foreignKeys = _foreignKeysFor(table);
        for (var id = 0; id < foreignKeys.length; id++) {
          final foreignKey = foreignKeys[id];
          final parent = _tables[_key(foreignKey.table)];
          if (parent == null) continue;
          final parentColumns = _referencedColumns(foreignKey, parent);
          if (parentColumns.length != foreignKey.columns.length) continue;
          for (var row = 0; row < table.rows.length; row++) {
            final values = [
              for (final column in foreignKey.columns)
                table.rows[row][table.column(column).name],
            ];
            if (values.any((value) => value == null)) continue;
            final found = parent.rows.any((parentRow) {
              for (var index = 0; index < values.length; index++) {
                if (!_equal(
                  parentRow[parent.column(parentColumns[index]).name],
                  values[index],
                )) {
                  return false;
                }
              }
              return true;
            });
            if (!found) {
              violations.add({
                'table': table.name,
                'rowid': table.rowIds[row],
                'parent': parent.name,
                'fkid': id,
              });
            }
          }
        }
      }
      return violations;
    }
    if (name == 'database_list') {
      return [
        {'seq': 0, 'name': 'main', 'file': _pager?.path ?? ''},
      ];
    }
    if (name == 'table_list') {
      return [
        for (final table in _tables.values)
          {
            'schema': 'main',
            'name': table.name,
            'type': 'table',
            'ncol': table.columns.length,
            'wr': 0,
            'strict': 0,
          },
        for (final view in _views.values)
          {
            'schema': 'main',
            'name': view.name,
            'type': 'view',
            'ncol':
                view.columns?.length ?? _selectColumnNames(view.query).length,
            'wr': 0,
            'strict': 0,
          },
      ];
    }
    if (name == 'collation_list') {
      return [
        {'seq': 0, 'name': 'BINARY'},
        {'seq': 1, 'name': 'NOCASE'},
      ];
    }
    if (name == 'function_list') {
      const aggregates = {
        'AVG',
        'COUNT',
        'GROUP_CONCAT',
        'MAX',
        'MIN',
        'SUM',
        'TOTAL',
      };
      return [
        for (final function in const [
          'ACOS',
          'ACOSH',
          'ABS',
          'ASIN',
          'ASINH',
          'ATAN',
          'ATAN2',
          'ATANH',
          'AVG',
          'CEIL',
          'CEILING',
          'CHAR',
          'COALESCE',
          'CONCAT',
          'CONCAT_WS',
          'COS',
          'COSH',
          'COUNT',
          'DATE',
          'DATETIME',
          'DEGREES',
          'EXP',
          'FLOOR',
          'GROUP_CONCAT',
          'HEX',
          'IFNULL',
          'IIF',
          'INSTR',
          'LN',
          'LOG',
          'LOG10',
          'LOG2',
          'JULIANDAY',
          'LENGTH',
          'LIKELIHOOD',
          'LIKELY',
          'LOWER',
          'LTRIM',
          'MAX',
          'MIN',
          'MOD',
          'NULLIF',
          'PI',
          'POW',
          'POWER',
          'QUOTE',
          'RADIANS',
          'RANDOM',
          'RANDOMBLOB',
          'REPLACE',
          'ROUND',
          'RTRIM',
          'SIGN',
          'SIN',
          'SINH',
          'SQRT',
          'STRFTIME',
          'SUBSTR',
          'SUBSTRING',
          'SUM',
          'TIME',
          'TOTAL',
          'TAN',
          'TANH',
          'TRIM',
          'TRUNC',
          'TYPEOF',
          'UNICODE',
          'UNIXEPOCH',
          'UNLIKELY',
          'UPPER',
          'ZEROBLOB',
        ])
          {
            'name': function,
            'builtin': 1,
            'type': aggregates.contains(function) ? 'a' : 's',
            'enc': 'utf8',
          },
      ];
    }
    if (name == 'integrity_check' || name == 'quick_check') {
      final errors = _integrityErrors();
      return [
        for (final error in errors.isEmpty ? const ['ok'] : errors)
          {statement.name.toLowerCase(): error},
      ];
    }
    return [
      {statement.name.toLowerCase(): _pragmaValue(statement)},
    ];
  }

  _Table _pragmaTable(_Pragma statement, List<Object?> parameters) {
    if (statement.argument == null) {
      throw PureSqlException('PRAGMA ${statement.name} requires a table name');
    }
    final tableName = _pragmaInput(statement.argument!, parameters).toString();
    return _selectTable(tableName, const {}, parameters);
  }

  String _indexOrigin(_Table table, _Index index) {
    if (!index.name.startsWith('sqlite_autoindex_')) return 'c';
    final primaryColumns = table.primaryKeyColumns.isNotEmpty
        ? table.primaryKeyColumns
        : table.columns
              .where((column) => column.primaryKey)
              .map((column) => column.name)
              .toList();
    final isPrimaryKey =
        primaryColumns.isNotEmpty &&
        index.columns.length == primaryColumns.length &&
        index.columns.every(
          (column) => primaryColumns.any(
            (primaryColumn) => _key(primaryColumn) == _key(column),
          ),
        );
    return isPrimaryKey ? 'pk' : 'u';
  }

  int _primaryKeyPosition(_Table table, _ColumnDef column) {
    if (column.primaryKey) return 1;
    final index = table.primaryKeyColumns.indexWhere(
      (name) => _key(name) == _key(column.name),
    );
    return index < 0 ? 0 : index + 1;
  }

  List<String> _integrityErrors() {
    final errors = <String>[];
    final foreignKeys = _foreignKeys;
    _foreignKeys = false;
    try {
      for (final table in _tables.values) {
        for (final row in table.rows) {
          try {
            _validate(table, row, ignore: row);
          } on SqliteException catch (error) {
            errors.add(error.message);
          }
        }
        for (final index in table.indexes) {
          try {
            _validateIndexRows(index, table.rows);
          } on SqliteException catch (error) {
            errors.add(error.message);
          }
        }
      }
    } finally {
      _foreignKeys = foreignKeys;
    }
    return errors;
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

  int _drop(_Drop statement) {
    if (statement.type == 'view') {
      final view = _views.remove(_key(statement.name));
      if (view == null) {
        if (statement.ifExists) return 0;
        throw PureSqlException('no such view: ${statement.name}');
      }
      if (_pager != null) _rewriteSchemaWithout(_pager!, {_key(view.name)});
      return 0;
    }
    if (statement.type == 'table') {
      final table = _tables[_key(statement.name)];
      if (table == null) {
        if (statement.ifExists) return 0;
        throw PureSqlException('no such table: ${statement.name}');
      }
      if (_foreignKeys) {
        final before = _snapshotRows();
        final changedTables = <_Table>{};
        try {
          for (final rowId in List<int>.from(table.rowIds)) {
            _deleteRowWithActions(table, rowId, changedTables, {});
          }
          changedTables.remove(table);
          _rewriteChangedTables(changedTables);
        } catch (_) {
          _restoreRows(before);
          rethrow;
        }
      }
      final schemaNames = {
        _key(table.name),
        for (final index in table.indexes) _key(index.name),
      };
      final pager = _pager;
      if (pager != null) {
        for (final index in table.indexes) {
          if (index.rootPage != null) {
            SqliteIndexBtree.freeTree(pager, index.rootPage!);
          }
        }
        SqliteTableBtree.freeTree(pager, table.rootPage!);
        _rewriteSchemaWithout(pager, schemaNames);
      }
      for (final index in table.indexes) {
        _indexes.remove(_key(index.name));
      }
      _tables.remove(_key(table.name));
      return 0;
    }
    final index = _indexes[_key(statement.name)];
    if (index == null) {
      if (statement.ifExists) return 0;
      throw PureSqlException('no such index: ${statement.name}');
    }
    if (index.name.startsWith('sqlite_autoindex_')) {
      throw PureSqlException('cannot drop an internal index');
    }
    final pager = _pager;
    if (pager != null) {
      SqliteIndexBtree.freeTree(pager, index.rootPage!);
      _rewriteSchemaWithout(pager, {_key(index.name)});
    }
    index.table.indexes.remove(index);
    _indexes.remove(_key(index.name));
    return 0;
  }

  void _rewriteSchemaWithout(SqlitePagerSync pager, Set<String> names) {
    final rows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
    SqliteTableBtree.rewriteRows(
      pager,
      1,
      rows
          .where(
            (row) =>
                row.values.length < 2 ||
                !const ['table', 'index', 'view'].contains(row.values[0]) ||
                !names.contains(_key(row.values[1].toString())),
          )
          .toList(),
      pageStart: 100,
    );
  }

  int _insert(_Insert statement, List<Object?> parameters) {
    final table = _table(statement.table);
    final before = _snapshotRows();
    final oldNextRowId = table.nextRowId;
    try {
      var changed = 0;
      final rows = statement.select == null
          ? statement.rows
          : [
              for (final row in _select(statement.select!, parameters))
                [for (final value in row.values) _Literal(value)],
            ];
      for (final values in rows) {
        final rowBefore = statement.conflict == 'fail' ? _snapshotRows() : null;
        try {
          changed += _insertRow(statement, table, values, parameters);
        } catch (error, stackTrace) {
          if (rowBefore != null && _isIgnorableUpdateError(error, table)) {
            _restoreRows(rowBefore);
            throw _ConflictFailException(error, stackTrace, changed);
          }
          rethrow;
        }
      }
      return changed;
    } catch (error) {
      if (error is _ConflictFailException) rethrow;
      _restoreRows(before);
      table.nextRowId = oldNextRowId;
      if (statement.conflict == 'rollback' &&
          _inTransaction &&
          _isIgnorableUpdateError(error, table)) {
        _rollback();
      }
      rethrow;
    }
  }

  int _insertRow(
    _Insert statement,
    _Table table,
    List<_Expr> values,
    List<Object?> parameters,
  ) {
    final columns = statement.defaultValues
        ? const <String>[]
        : statement.columns ??
              table.columns.map((column) => column.name).toList();
    if (columns.length != values.length) {
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
      row[column.name] = _eval(values[i], row, parameters);
    }
    final rowIdColumn = table.rowIdColumn;
    final requestedRowId = rowIdColumn == null ? null : row[rowIdColumn.name];
    final rowId = requestedRowId == null
        ? table.nextRowId
        : _asInt(requestedRowId);
    if (rowId < 1) throw PureSqlException('rowid must be positive');
    if (rowIdColumn != null) row[rowIdColumn.name] = rowId;
    final conflicts = _conflictingRows(table, row, rowId);
    if (statement.upsertNothing) {
      final target = statement.upsertTarget;
      if (target != null && !_isUniqueTarget(table, target)) {
        throw PureSqlException(
          'ON CONFLICT target does not match a UNIQUE key',
        );
      }
      if (conflicts.any(
        (index) =>
            target == null ||
            _matchesConflictTarget(table, row, table.rows[index], target),
      )) {
        return 0;
      }
    }
    if (statement.upsertAssignments != null) {
      final target = statement.upsertTarget;
      if (target != null && !_isUniqueTarget(table, target)) {
        throw PureSqlException(
          'ON CONFLICT target does not match a UNIQUE key',
        );
      }
      int? conflictIndex;
      for (final index in conflicts) {
        if (target == null ||
            _matchesConflictTarget(table, row, table.rows[index], target)) {
          conflictIndex = index;
          break;
        }
      }
      if (conflictIndex != null) {
        final existing = table.rows[conflictIndex];
        final context = _qualifiedRow(table, existing, null);
        for (final column in table.columns) {
          context['@excluded.${column.name}'] = row[column.name];
        }
        if (statement.upsertWhere != null &&
            !_matches(statement.upsertWhere, context, parameters)) {
          return 0;
        }
        final next = Map<String, Object?>.from(existing);
        for (final entry in statement.upsertAssignments!.entries) {
          next[table.column(entry.key).name] = _eval(
            entry.value,
            context,
            parameters,
          );
        }
        final before = _snapshotRows();
        final changedTables = <_Table>{};
        try {
          _updateRowWithActions(
            table,
            table.rowIds[conflictIndex],
            next,
            changedTables,
            {},
          );
          for (final changed in changedTables) {
            for (final changedRow in changed.rows) {
              _validate(changed, changedRow, ignore: changedRow);
            }
            for (final index in changed.indexes) {
              _validateIndexRows(index, changed.rows);
            }
          }
          _rewriteChangedTables(changedTables);
        } catch (_) {
          _restoreRows(before);
          rethrow;
        }
        return 1;
      }
    }
    if (statement.conflict == 'ignore' && conflicts.isNotEmpty) return 0;
    if (const ['abort', 'fail', 'rollback'].contains(statement.conflict) &&
        conflicts.isNotEmpty) {
      throw PureSqlException('UNIQUE constraint failed: ${table.name}');
    }
    final before = _snapshotRows();
    final oldNextRowId = table.nextRowId;
    final changedTables = <_Table>{};
    final conflictRowIds = [for (final index in conflicts) table.rowIds[index]];
    try {
      for (final rowId in conflictRowIds.reversed) {
        final index = table.rowIds.indexOf(rowId);
        if (index < 0) continue;
        if (_foreignKeys) {
          _deleteRowWithActions(table, rowId, changedTables, {});
        } else {
          table.rows.removeAt(index);
          table.rowIds.removeAt(index);
        }
      }
      _validate(table, row);
      table.nextRowId = rowId >= table.nextRowId ? rowId + 1 : table.nextRowId;
      table.rows.add(row);
      table.rowIds.add(rowId);
      if (changedTables.isNotEmpty) changedTables.add(table);
      for (final index in table.indexes) {
        _validateIndexRows(index, table.rows);
      }
    } catch (_) {
      _restoreRows(before);
      table.nextRowId = oldNextRowId;
      rethrow;
    }
    final pager = _pager;
    if (pager != null) {
      try {
        if (changedTables.isNotEmpty) {
          _rewriteChangedTables(changedTables);
        } else {
          if (conflicts.isEmpty) {
            SqliteTableBtree.insertRow(pager, table.rootPage!, rowId, [
              ..._storedValues(table, row),
            ]);
          } else {
            _rewriteTable(pager, table);
          }
          _rewriteIndexes(pager, table);
        }
      } catch (_) {
        _restoreRows(before);
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
          if (value != null && _columnEqual(column, old[column.name], value)) {
            conflicts.add(index);
          }
        }
      }
      for (final uniqueIndex in table.indexes) {
        if (uniqueIndex.unique && _sameIndexKey(uniqueIndex, old, row)) {
          conflicts.add(index);
        }
      }
    }
    return conflicts.toList()..sort();
  }

  bool _isUniqueTarget(_Table table, List<String> target) {
    final wanted = target.map(_key).toList();
    final keys = <List<String>>[
      for (final column in table.columns)
        if (column.unique || column.primaryKey) [column.name],
      if (table.primaryKeyColumns.isNotEmpty) table.primaryKeyColumns,
      ...table.uniqueConstraints,
      for (final index in table.indexes)
        if (index.unique) index.columns,
    ];
    return keys.any(
      (key) =>
          key.length == wanted.length &&
          key
              .map(_key)
              .toList()
              .asMap()
              .entries
              .every((entry) => entry.value == wanted[entry.key]),
    );
  }

  bool _matchesConflictTarget(
    _Table table,
    SqlRow attempted,
    SqlRow existing,
    List<String> target,
  ) => target.every((name) {
    final column = table.column(name);
    final value = attempted[column.name];
    return value != null && _columnEqual(column, existing[column.name], value);
  });

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
      if (schemaRow.values.length < 5 ||
          schemaRow.values[0] != 'view' ||
          schemaRow.values[4] is! String) {
        continue;
      }
      final statement = _Parser(schemaRow.values[4] as String).parse();
      if (statement is _CreateView) {
        statement.schemaSql = schemaRow.values[4] as String;
        _views[_key(statement.name)] = statement;
      }
    }
    for (final schemaRow in schemaRows) {
      if (schemaRow.values.length < 5 || schemaRow.values[0] != 'table') {
        continue;
      }
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
        uniqueConstraints: statement.uniqueConstraints,
        foreignKeyConstraints: statement.foreignKeyConstraints,
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
      if (rootPage is! int || tableName is! String || indexName is! String) {
        continue;
      }
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
          ...table.uniqueConstraints,
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

  /// Rolls back any active transaction and releases the database resources.
  void close() {
    if (_inTransaction) _rollback();
    _pager?.close();
  }

  int _update(_Update statement, List<Object?> parameters) {
    final table = _table(statement.table);
    final rowIds = [
      for (var index = 0; index < table.rows.length; index++)
        if (_matches(statement.where, table.rows[index], parameters))
          table.rowIds[index],
    ];
    if (rowIds.isEmpty) return 0;
    final before = _snapshotRows();
    final changedTables = <_Table>{table};
    var count = 0;
    try {
      for (final rowId in rowIds) {
        final rowIndex = table.rowIds.indexOf(rowId);
        if (rowIndex < 0) continue;
        final row = table.rows[rowIndex];
        final next = Map<String, Object?>.from(row);
        for (final entry in statement.assignments.entries) {
          next[table.column(entry.key).name] = _eval(
            entry.value,
            next,
            parameters,
          );
        }
        final rowIdColumn = table.rowIdColumn;
        final replacementRowId = rowIdColumn == null
            ? rowId
            : _asInt(next[rowIdColumn.name]);
        final conflicts = [
          for (final index in _conflictingRows(table, next, replacementRowId))
            if (table.rowIds[index] != rowId) table.rowIds[index],
        ];
        if (statement.conflict == 'ignore' && conflicts.isNotEmpty) continue;
        if (statement.conflict == 'replace') {
          for (final conflictRowId in conflicts.reversed) {
            final conflictIndex = table.rowIds.indexOf(conflictRowId);
            if (conflictIndex < 0) continue;
            if (_foreignKeys) {
              _deleteRowWithActions(table, conflictRowId, changedTables, {});
            } else {
              table.rows.removeAt(conflictIndex);
              table.rowIds.removeAt(conflictIndex);
              changedTables.add(table);
            }
          }
        }
        final rowBefore =
            statement.conflict == 'ignore' || statement.conflict == 'fail'
            ? _snapshotRows()
            : null;
        final changedBefore = Set<_Table>.from(changedTables);
        try {
          _updateRowWithActions(table, rowId, next, changedTables, {});
          for (final changed in changedTables) {
            for (final index in changed.indexes) {
              _validateIndexRows(index, changed.rows);
            }
          }
        } catch (error, stackTrace) {
          if (rowBefore != null && _isIgnorableUpdateError(error, table)) {
            _restoreRows(rowBefore);
            changedTables.retainAll(changedBefore);
            if (statement.conflict == 'ignore') continue;
            _rewriteChangedTables(changedTables);
            throw _ConflictFailException(error, stackTrace, count);
          }
          rethrow;
        }
        count++;
      }
      if (count > 0) {
        for (final changed in changedTables) {
          for (final row in changed.rows) {
            _validate(changed, row, ignore: row);
          }
          for (final index in changed.indexes) {
            _validateIndexRows(index, changed.rows);
          }
        }
        _rewriteChangedTables(changedTables);
      }
    } catch (error) {
      if (error is _ConflictFailException) rethrow;
      _restoreRows(before);
      if (statement.conflict == 'rollback' &&
          _inTransaction &&
          _isIgnorableUpdateError(error, table)) {
        _rollback();
      }
      rethrow;
    }
    return count;
  }

  bool _isIgnorableUpdateError(Object error, _Table table) {
    if (error is! SqliteException) return false;
    final message = error.message;
    return message == 'UNIQUE constraint failed: ${table.name}' ||
        message.startsWith('UNIQUE constraint failed: ${table.name}.') ||
        table.indexes.any(
          (index) => message == 'UNIQUE constraint failed: ${index.name}',
        ) ||
        message.startsWith('NOT NULL constraint failed: ${table.name}.') ||
        message == 'CHECK constraint failed: ${table.name}' ||
        message.startsWith('CHECK constraint failed: ${table.name}.');
  }

  int _delete(_Delete statement, List<Object?> parameters) {
    final table = _table(statement.table);
    final rowIds = [
      for (var index = table.rows.length - 1; index >= 0; index--)
        if (_matches(statement.where, table.rows[index], parameters))
          table.rowIds[index],
    ];
    if (rowIds.isEmpty) return 0;
    final before = _snapshotRows();
    final changedTables = <_Table>{};
    try {
      for (final rowId in rowIds) {
        if (_foreignKeys) {
          _deleteRowWithActions(table, rowId, changedTables, {});
        } else {
          final index = table.rowIds.indexOf(rowId);
          if (index >= 0) {
            table.rows.removeAt(index);
            table.rowIds.removeAt(index);
            changedTables.add(table);
          }
        }
      }
      _rewriteChangedTables(changedTables);
    } catch (_) {
      _restoreRows(before);
      rethrow;
    }
    return rowIds.length;
  }

  Map<_Table, (List<SqlRow>, List<int>, int)> _snapshotRows() => {
    for (final table in _tables.values)
      table: (
        table.rows.map((row) => Map<String, Object?>.from(row)).toList(),
        List<int>.from(table.rowIds),
        table.nextRowId,
      ),
  };

  void _restoreRows(Map<_Table, (List<SqlRow>, List<int>, int)> snapshot) {
    for (final entry in snapshot.entries) {
      entry.key.rows
        ..clear()
        ..addAll(entry.value.$1);
      entry.key.rowIds
        ..clear()
        ..addAll(entry.value.$2);
      entry.key.nextRowId = entry.value.$3;
    }
  }

  void _rewriteChangedTables(Set<_Table> tables) {
    final pager = _pager;
    if (pager == null) return;
    for (final table in tables) {
      _rewriteTable(pager, table);
      _rewriteIndexes(pager, table);
    }
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
    for (final foreignKey in _foreignKeysFor(table)) {
      final parent = _tables[_key(foreignKey.table)];
      if (parent == null) {
        throw PureSqlException('no such table: ${foreignKey.table}');
      }
      final parentColumns = _referencedColumns(foreignKey, parent);
      if (parentColumns.length != foreignKey.columns.length) {
        throw PureSqlException('foreign key column count mismatch');
      }
      final values = [
        for (final name in foreignKey.columns) row[table.column(name).name],
      ];
      if (values.any((value) => value == null)) continue;
      if (!parent.rows.any((parentRow) {
        for (var index = 0; index < values.length; index++) {
          if (!_equal(
            parentRow[parent.column(parentColumns[index]).name],
            values[index],
          )) {
            return false;
          }
        }
        return true;
      })) {
        throw PureSqlException('FOREIGN KEY constraint failed');
      }
    }
  }

  List<_ForeignKey> _foreignKeysFor(_Table table) => [
    ...table.foreignKeyConstraints,
    for (final column in table.columns)
      if (column.referencesTable != null)
        _ForeignKey(
          [column.name],
          column.referencesTable!,
          [if (column.referencesColumn != null) column.referencesColumn!],
          onDelete: column.onDelete,
          onUpdate: column.onUpdate,
        ),
  ];

  List<String> _referencedColumns(_ForeignKey foreignKey, _Table parent) {
    if (foreignKey.referencedColumns.isNotEmpty) {
      return foreignKey.referencedColumns;
    }
    return parent.primaryKeyColumns.isNotEmpty
        ? parent.primaryKeyColumns
        : [
            for (final column in parent.columns)
              if (column.primaryKey) column.name,
          ];
  }

  List<int> _matchingChildRowIds(
    _Table parent,
    SqlRow parentRow,
    _Table child,
    _ForeignKey foreignKey,
  ) {
    final parentColumns = _referencedColumns(foreignKey, parent);
    if (parentColumns.length != foreignKey.columns.length) {
      throw PureSqlException('foreign key column count mismatch');
    }
    final ids = <int>[];
    for (var row = 0; row < child.rows.length; row++) {
      var matches = true;
      for (var position = 0; position < parentColumns.length; position++) {
        final parentValue =
            parentRow[parent.column(parentColumns[position]).name];
        final childValue =
            child.rows[row][child.column(foreignKey.columns[position]).name];
        if (parentValue == null ||
            childValue == null ||
            !_equal(parentValue, childValue)) {
          matches = false;
          break;
        }
      }
      if (matches) ids.add(child.rowIds[row]);
    }
    return ids;
  }

  void _deleteRowWithActions(
    _Table parent,
    int parentRowId,
    Set<_Table> changedTables,
    Set<(_Table, int)> visiting,
  ) {
    final identity = (parent, parentRowId);
    if (!visiting.add(identity)) return;
    try {
      var parentIndex = parent.rowIds.indexOf(parentRowId);
      if (parentIndex < 0) return;
      final parentRow = Map<String, Object?>.from(parent.rows[parentIndex]);
      for (final child in _tables.values) {
        for (final foreignKey in _foreignKeysFor(child)) {
          if (_key(foreignKey.table) != _key(parent.name)) continue;
          final childRowIds = _matchingChildRowIds(
            parent,
            parentRow,
            child,
            foreignKey,
          );
          for (final childRowId in childRowIds) {
            if (identical(child, parent) && childRowId == parentRowId) continue;
            switch (foreignKey.onDelete) {
              case 'CASCADE':
                _deleteRowWithActions(
                  child,
                  childRowId,
                  changedTables,
                  visiting,
                );
              case 'SET NULL':
              case 'SET DEFAULT':
                _setChildForeignKeyValues(
                  child,
                  childRowId,
                  foreignKey,
                  foreignKey.onDelete,
                  const [],
                  changedTables,
                );
              default:
                throw PureSqlException('FOREIGN KEY constraint failed');
            }
          }
        }
      }
      parentIndex = parent.rowIds.indexOf(parentRowId);
      if (parentIndex >= 0) {
        parent.rows.removeAt(parentIndex);
        parent.rowIds.removeAt(parentIndex);
        changedTables.add(parent);
      }
    } finally {
      visiting.remove(identity);
    }
  }

  void _updateRowWithActions(
    _Table parent,
    int parentRowId,
    SqlRow nextParentRow,
    Set<_Table> changedTables,
    Set<(_Table, int)> visiting,
  ) {
    final identity = (parent, parentRowId);
    if (!visiting.add(identity)) return;
    try {
      final parentIndex = parent.rowIds.indexOf(parentRowId);
      if (parentIndex < 0) return;
      final oldParentRow = Map<String, Object?>.from(parent.rows[parentIndex]);
      final actions = <(_Table, _ForeignKey, List<int>)>[];
      if (_foreignKeys) {
        for (final child in _tables.values) {
          for (final foreignKey in _foreignKeysFor(child)) {
            if (_key(foreignKey.table) != _key(parent.name)) continue;
            final parentColumns = _referencedColumns(foreignKey, parent);
            if (!parentColumns.any(
              (name) => !_equal(
                oldParentRow[parent.column(name).name],
                nextParentRow[parent.column(name).name],
              ),
            )) {
              continue;
            }
            final childRowIds = _matchingChildRowIds(
              parent,
              oldParentRow,
              child,
              foreignKey,
            );
            if (childRowIds.isNotEmpty) {
              actions.add((child, foreignKey, childRowIds));
            }
          }
        }
      }
      final current = parent.rows[parentIndex]
        ..clear()
        ..addAll(nextParentRow);
      changedTables.add(parent);
      for (final (child, foreignKey, childRowIds) in actions) {
        for (final childRowId in childRowIds) {
          final childIndex = child.rowIds.indexOf(childRowId);
          if (childIndex < 0) continue;
          final childNext = Map<String, Object?>.from(child.rows[childIndex]);
          switch (foreignKey.onUpdate) {
            case 'CASCADE':
              final parentColumns = _referencedColumns(foreignKey, parent);
              for (
                var position = 0;
                position < foreignKey.columns.length;
                position++
              ) {
                final column = child.column(foreignKey.columns[position]);
                childNext[column.name] =
                    nextParentRow[parent.column(parentColumns[position]).name];
              }
            case 'SET NULL':
            case 'SET DEFAULT':
              for (final name in foreignKey.columns) {
                final column = child.column(name);
                childNext[column.name] = foreignKey.onUpdate == 'SET NULL'
                    ? null
                    : column.defaultExpression == null
                    ? null
                    : _eval(column.defaultExpression!, childNext, const []);
              }
            default:
              throw PureSqlException('FOREIGN KEY constraint failed');
          }
          _updateRowWithActions(
            child,
            childRowId,
            childNext,
            changedTables,
            visiting,
          );
        }
      }
      final index = parent.rows.indexOf(current);
      if (index >= 0) {
        _validate(parent, current, ignore: current);
        final rowIdColumn = parent.rowIdColumn;
        if (rowIdColumn != null) {
          final nextRowId = _asInt(current[rowIdColumn.name]);
          if (nextRowId < 1 ||
              parent.rowIds.asMap().entries.any(
                (entry) => entry.key != index && entry.value == nextRowId,
              )) {
            throw PureSqlException(
              'UNIQUE constraint failed: ${parent.name}.rowid',
            );
          }
          parent.rowIds[index] = nextRowId;
          parent.nextRowId = math.max(parent.nextRowId, nextRowId + 1);
        }
      }
    } finally {
      visiting.remove(identity);
    }
  }

  void _setChildForeignKeyValues(
    _Table child,
    int childRowId,
    _ForeignKey foreignKey,
    String action,
    List<Object?> parameters,
    Set<_Table> changedTables,
  ) {
    final rowIndex = child.rowIds.indexOf(childRowId);
    if (rowIndex < 0) return;
    final current = child.rows[rowIndex];
    final next = Map<String, Object?>.from(current);
    for (final name in foreignKey.columns) {
      final column = child.column(name);
      next[column.name] = action == 'SET NULL'
          ? null
          : column.defaultExpression == null
          ? null
          : _eval(column.defaultExpression!, next, parameters);
    }
    _validate(child, next, ignore: current);
    current
      ..clear()
      ..addAll(next);
    changedTables.add(child);
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
    if (statement.compoundTerms.isNotEmpty) {
      return _selectCompound(statement, parameters, outerRow);
    }
    final table = statement.fromQuery != null
        ? _materializeQuery(
            statement.alias ?? '(subquery)',
            _Cte(statement.fromQuery!, null),
            parameters,
          )
        : statement.table == null
        ? null
        : _selectTable(statement.table!, statement.ctes, parameters);
    if (table == null &&
        statement.fromQuery == null &&
        statement.items.any(
          (item) =>
              item.expression is _Column &&
              ((item.expression as _Column).name == '*' ||
                  (item.expression as _Column).name.endsWith('.*')),
        )) {
      throw PureSqlException('SELECT * requires a FROM clause');
    }
    final candidateRowIds = table == null || outerRow.isNotEmpty
        ? null
        : _indexCandidates(table, statement.where, parameters);
    var joinedRows = <SqlRow>[
      if (table == null) Map<String, Object?>.from(outerRow),
    ];
    if (table != null) {
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
    }
    final sourceTables = <(_Table, String?)>[
      if (table != null) (table, statement.alias),
    ];
    for (final join in statement.joins) {
      final joinedTable = join.query == null
          ? _selectTable(join.table!, statement.ctes, parameters)
          : _materializeQuery(
              join.alias ?? '(subquery)',
              _Cte(join.query!, null),
              parameters,
            );
      final leftColumnNames = {
        for (final (sourceTable, _) in sourceTables)
          for (final column in sourceTable.columns)
            _key(column.name): column.name,
      };
      final rightColumnNames = {
        for (final column in joinedTable.columns)
          _key(column.name): column.name,
      };
      final usingColumns = join.natural
          ? [
              for (final entry in leftColumnNames.entries)
                if (rightColumnNames.containsKey(entry.key)) entry.value,
            ]
          : join.usingColumns;
      for (final column in usingColumns) {
        if (!leftColumnNames.containsKey(_key(column)) ||
            !rightColumnNames.containsKey(_key(column))) {
          throw PureSqlException('USING column does not exist: $column');
        }
      }
      final matchedRightRows = List<bool>.filled(
        joinedTable.rows.length,
        false,
      );
      final next = <SqlRow>[];
      for (final leftRow in joinedRows) {
        var matched = false;
        for (var index = 0; index < joinedTable.rows.length; index++) {
          final rightRow = joinedTable.rows[index];
          final combined = Map<String, Object?>.from(leftRow)
            ..addAll(_qualifiedRow(joinedTable, rightRow, join.alias));
          final joinsByColumns = usingColumns.every((column) {
            final leftValue = _readColumn(leftRow, column);
            final rightValue = _readColumn(rightRow, column);
            return leftValue != null &&
                rightValue != null &&
                _equal(leftValue, rightValue);
          });
          if (join.on == null
              ? joinsByColumns
              : _truthy(_evalQueryExpression(join.on!, combined, parameters))) {
            for (final column in usingColumns) {
              combined[leftColumnNames[_key(column)]!] = _readColumn(
                leftRow,
                column,
              );
            }
            next.add(combined);
            matched = true;
            matchedRightRows[index] = true;
          }
        }
        if (!matched && (join.type == 'LEFT' || join.type == 'FULL')) {
          final combined = Map<String, Object?>.from(leftRow)
            ..addAll(_qualifiedRow(joinedTable, const {}, join.alias));
          for (final column in usingColumns) {
            combined[leftColumnNames[_key(column)]!] = _readColumn(
              leftRow,
              column,
            );
          }
          next.add(combined);
        }
      }
      if (join.type == 'RIGHT' || join.type == 'FULL') {
        final nullLeftRow = <String, Object?>{...outerRow};
        for (final (sourceTable, sourceAlias) in sourceTables) {
          nullLeftRow.addAll(_qualifiedRow(sourceTable, const {}, sourceAlias));
        }
        for (var index = 0; index < joinedTable.rows.length; index++) {
          if (matchedRightRows[index]) continue;
          final rightRow = joinedTable.rows[index];
          final combined = Map<String, Object?>.from(nullLeftRow)
            ..addAll(_qualifiedRow(joinedTable, rightRow, join.alias));
          for (final column in usingColumns) {
            combined[leftColumnNames[_key(column)] ?? column] = _readColumn(
              rightRow,
              column,
            );
          }
          next.add(combined);
        }
      }
      joinedRows = next;
      sourceTables.add((joinedTable, join.alias));
    }
    var rows = <SqlRow>[];
    for (final row in joinedRows) {
      if (_matches(statement.where, row, parameters)) rows.add(row);
    }

    if (statement.groupBy.isNotEmpty ||
        statement.having != null ||
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
      final selectedGroups = [
        for (final group in groups)
          if (statement.having == null ||
              _truthy(
                _evalGroup(
                  statement.having!,
                  group,
                  group.isEmpty ? const {} : group.first,
                  parameters,
                  selectSubquery: _runSubquery,
                ),
              ))
            group,
      ];
      var grouped = [
        for (final group in selectedGroups)
          _projectGroup(
            group,
            statement.items,
            parameters,
            selectSubquery: _runSubquery,
          ),
      ];
      if (statement.orderBy.isNotEmpty) {
        final positions = List<int>.generate(grouped.length, (index) => index);
        positions.sort((left, right) {
          for (final order in statement.orderBy) {
            final result = _compare(
              _orderValue(
                order.expression,
                selectedGroups[left].isEmpty
                    ? const {}
                    : selectedGroups[left].first,
                grouped[left],
                statement.items,
                parameters,
                group: selectedGroups[left],
              ),
              _orderValue(
                order.expression,
                selectedGroups[right].isEmpty
                    ? const {}
                    : selectedGroups[right].first,
                grouped[right],
                statement.items,
                parameters,
                group: selectedGroups[right],
              ),
              noCase: order.noCase,
            );
            if (result != 0) return order.descending ? -result : result;
          }
          return 0;
        });
        grouped = [for (final position in positions) grouped[position]];
      }
      if (statement.distinct) grouped = _distinctRows(grouped);
      if (statement.limit != null) {
        final offset = statement.offset == null
            ? 0
            : _asInt(_eval(statement.offset!, const {}, parameters));
        final limit = _asInt(_eval(statement.limit!, const {}, parameters));
        grouped = grouped
            .skip(math.max(0, offset).toInt())
            .take(limit < 0 ? grouped.length : limit)
            .toList();
      }
      return grouped;
    }

    if (statement.orderBy.isNotEmpty) {
      if (rows.isNotEmpty) {
        for (final order in statement.orderBy) {
          _orderValue(
            order.expression,
            rows.first,
            const {},
            statement.items,
            parameters,
          );
        }
      }
      rows.sort((a, b) {
        for (final order in statement.orderBy) {
          final result = _compare(
            _orderValue(
              order.expression,
              a,
              const {},
              statement.items,
              parameters,
            ),
            _orderValue(
              order.expression,
              b,
              const {},
              statement.items,
              parameters,
            ),
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
      rows = rows
          .skip(math.max(0, offset).toInt())
          .take(limit < 0 ? rows.length : limit)
          .toList();
    }

    final result = [
      for (final row in rows) _project(row, statement.items, parameters),
    ];
    return statement.distinct ? _distinctRows(result) : result;
  }

  List<SqlRow> _selectCompound(
    _Select statement,
    List<Object?> parameters,
    SqlRow outerRow,
  ) {
    _Select branch(_Select query) => _Select(
      query.items,
      query.table,
      query.alias,
      query.joins,
      query.where,
      query.groupBy,
      query.having,
      const [],
      null,
      null,
      query.distinct,
      ctes: query.ctes,
      fromQuery: query.fromQuery,
    );

    final first = branch(statement);
    final columns = _selectColumnNames(first, parameters);
    final groups = <List<_CompoundTerm>>[
      [_CompoundTerm('', first)],
    ];
    for (final term in statement.compoundTerms) {
      if (term.operator == 'INTERSECT') {
        groups.last.add(term);
      } else {
        groups.add([term]);
      }
    }

    List<SqlRow> evaluateGroup(List<_CompoundTerm> group) {
      final firstQuery = group.first.query;
      final firstColumns = _selectColumnNames(firstQuery, parameters);
      if (firstColumns.length != columns.length) {
        throw PureSqlException(
          'compound SELECTs must return the same number of columns',
        );
      }
      var rows = _relabelRows(
        _select(firstQuery, parameters, outerRow: outerRow),
        columns,
      );
      for (final term in group.skip(1)) {
        final termColumns = _selectColumnNames(term.query, parameters);
        if (termColumns.length != columns.length) {
          throw PureSqlException(
            'compound SELECTs must return the same number of columns',
          );
        }
        final right = _relabelRows(
          _select(term.query, parameters, outerRow: outerRow),
          columns,
        );
        rows = _uniqueRows([
          for (final row in rows)
            if (right.any(
              (candidate) => _compoundRowsEqual(row, candidate, columns),
            ))
              row,
        ]);
      }
      return rows;
    }

    var rows = evaluateGroup(groups.first);
    for (final group in groups.skip(1)) {
      final term = group.first;
      final right = evaluateGroup(group);
      if (term.operator == 'UNION') {
        rows = term.all
            ? [...rows, ...right]
            : _uniqueRows([...rows, ...right]);
      } else {
        rows = _uniqueRows([
          for (final row in rows)
            if (!right.any(
              (candidate) => _compoundRowsEqual(row, candidate, columns),
            ))
              row,
        ]);
      }
    }

    if (statement.orderBy.isNotEmpty) {
      rows.sort((left, right) {
        for (final order in statement.orderBy) {
          final leftValue = _compoundOrderValue(
            order.expression,
            left,
            columns,
            parameters,
          );
          final rightValue = _compoundOrderValue(
            order.expression,
            right,
            columns,
            parameters,
          );
          final comparison = _compare(
            leftValue,
            rightValue,
            noCase: order.noCase,
          );
          if (comparison != 0) {
            return order.descending ? -comparison : comparison;
          }
        }
        return 0;
      });
    }
    if (statement.limit != null) {
      final offset = statement.offset == null
          ? 0
          : _asInt(
              _evalQueryExpression(statement.offset!, const {}, parameters),
            );
      final limit = _asInt(
        _evalQueryExpression(statement.limit!, const {}, parameters),
      );
      rows = rows
          .skip(math.max(0, offset).toInt())
          .take(limit < 0 ? rows.length : limit)
          .toList();
    }
    return rows;
  }

  List<SqlRow> _relabelRows(List<SqlRow> rows, List<String> columns) {
    for (final row in rows) {
      if (row.length != columns.length) {
        throw PureSqlException(
          'compound SELECTs must return the same number of columns',
        );
      }
    }
    return [
      for (final row in rows)
        Map<String, Object?>.fromIterables(columns, row.values),
    ];
  }

  List<SqlRow> _uniqueRows(List<SqlRow> rows) {
    final unique = <SqlRow>[];
    for (final row in rows) {
      if (!unique.any(
        (candidate) => _compoundRowsEqual(row, candidate, row.keys.toList()),
      )) {
        unique.add(row);
      }
    }
    return unique;
  }

  bool _compoundRowsEqual(SqlRow left, SqlRow right, List<String> columns) =>
      columns.every((column) => _valueEqual(left[column], right[column]));

  Object? _compoundOrderValue(
    _Expr expression,
    SqlRow row,
    List<String> columns,
    List<Object?> parameters,
  ) {
    if (expression is _Literal && expression.value is int) {
      final index = expression.value as int;
      if (index > 0 && index <= columns.length) return row[columns[index - 1]];
    }
    return _evalQueryExpression(expression, row, parameters);
  }

  Object? _evalQueryExpression(
    _Expr expression,
    SqlRow row,
    List<Object?> parameters,
  ) => _eval(expression, row, parameters, selectSubquery: _runSubquery);

  List<SqlRow> _runSubquery(
    _Select query,
    SqlRow outerRow,
    List<Object?> parameters,
  ) => _select(query, parameters, outerRow: outerRow);

  _Table _selectTable(
    String name,
    Map<String, _Cte> ctes,
    List<Object?> parameters,
  ) {
    final key = _key(name);
    final cte = ctes[key];
    if (cte != null) return _materializeQuery(name, cte, parameters);
    final view = _views[key];
    if (view == null) return _table(name);
    if (!_viewStack.add(key)) {
      throw PureSqlException('circular view reference: ${view.name}');
    }
    try {
      return _materializeQuery(
        name,
        _Cte(view.query, view.columns),
        parameters,
      );
    } finally {
      _viewStack.remove(key);
    }
  }

  _Table _materializeQuery(String name, _Cte query, List<Object?> parameters) {
    final rows = _select(query.query, parameters);
    final resultNames = _materializedColumnNames(query.query, rows, parameters);
    final names = query.columns ?? resultNames;
    if (resultNames.length != names.length) {
      throw PureSqlException('CTE column count does not match its query');
    }
    return _Table(name, [for (final column in names) _ColumnDef(column)])
      ..rows.addAll([
        for (final row in rows)
          {
            for (var index = 0; index < names.length; index++)
              names[index]: row.values.elementAt(index),
          },
      ])
      ..rowIds.addAll(List<int>.generate(rows.length, (index) => index + 1));
  }

  List<String> _materializedColumnNames(
    _Select query,
    List<SqlRow> rows,
    List<Object?> parameters,
  ) {
    final sourceNames = rows.isEmpty
        ? _selectColumnNames(query, parameters)
        : rows.first.keys.toList();
    if (query.items.length == 1) {
      final expression = query.items.single.expression;
      if (expression is _Column &&
          (expression.name == '*' || expression.name.endsWith('.*'))) {
        return sourceNames;
      }
    }
    if (sourceNames.length != query.items.length) return sourceNames;
    return [
      for (var index = 0; index < sourceNames.length; index++)
        if (query.items[index].expression case _Column(
          :final name,
        ) when query.items[index].outputName == name && name.contains('.'))
          name.substring(name.lastIndexOf('.') + 1)
        else
          query.items[index].outputName,
    ];
  }

  List<String> _selectColumnNames(
    _Select query, [
    List<Object?> parameters = const [],
  ]) {
    if (query.items.length == 1 && query.items.single.expression is _Column) {
      final expression = query.items.single.expression as _Column;
      if (expression.name == '*' || expression.name.endsWith('.*')) {
        if (query.fromQuery != null) {
          return _selectColumnNames(query.fromQuery!, parameters);
        }
        if (query.table == null) {
          throw PureSqlException('SELECT * requires a FROM clause');
        }
        return _selectTable(
          query.table!,
          query.ctes,
          parameters,
        ).columns.map((column) => column.name).toList();
      }
    }
    return query.items.map((item) => item.outputName).toList();
  }

  Object? _orderValue(
    _Expr expression,
    SqlRow source,
    SqlRow projected,
    List<_SelectItem> items,
    List<Object?> parameters, {
    List<SqlRow>? group,
  }) {
    if (expression is _Literal && expression.value is int) {
      final index = expression.value as int;
      if (index > 0 && index <= items.length) {
        final selected = items[index - 1].expression;
        return group == null
            ? selected is _ScalarSubquery
                  ? _selectScalar(selected, source, parameters)
                  : _evalQueryExpression(selected, source, parameters)
            : _evalGroup(
                selected,
                group,
                group.isEmpty ? const {} : group.first,
                parameters,
                selectSubquery: _runSubquery,
              );
      }
    }
    if (expression is _Column) {
      final alias = items.where(
        (item) => _key(item.outputName) == _key(expression.name),
      );
      final sourceHasColumn = source.keys.any(
        (key) => !key.startsWith('@') && _key(key) == _key(expression.name),
      );
      if (!sourceHasColumn && alias.isNotEmpty) {
        final selected = alias.first.expression;
        return group == null
            ? selected is _ScalarSubquery
                  ? _selectScalar(selected, source, parameters)
                  : _evalQueryExpression(selected, source, parameters)
            : _evalGroup(
                selected,
                group,
                group.isEmpty ? const {} : group.first,
                parameters,
                selectSubquery: _runSubquery,
              );
      }
    }
    if (group != null) {
      return _evalGroup(
        expression,
        group,
        group.isEmpty ? const {} : group.first,
        parameters,
        selectSubquery: _runSubquery,
      );
    }
    return _evalQueryExpression(expression, source, parameters);
  }

  SqlRow _projectGroup(
    List<SqlRow> group,
    List<_SelectItem> items,
    List<Object?> parameters, {
    List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
  }) {
    final row = group.isEmpty ? <String, Object?>{} : group.first;
    return <String, Object?>{
      for (final item in items)
        item.outputName: item.expression is _ScalarSubquery
            ? _selectScalar(item.expression as _ScalarSubquery, row, parameters)
            : _evalGroup(
                item.expression,
                group,
                row,
                parameters,
                selectSubquery: selectSubquery,
              ),
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
            : _evalQueryExpression(expression, row, parameters);
      }
    }
    return result;
  }

  bool _matches(_Expr? expression, SqlRow row, List<Object?> parameters) {
    if (expression == null) return true;
    return _truthy(_evalQueryExpression(expression, row, parameters));
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

/// A row returned by the `sqlite3` compatibility facade.
typedef Row = Map<String, Object?>;

/// Rows returned by [Database.select].
typedef ResultSet = List<Row>;

/// Compatibility entry point for applications migrating from package:sqlite3.
final sqlite3 = Sqlite();

/// Opens databases through the `sqlite3.open` compatibility API.
class Sqlite {
  /// Opens or creates a persistent database at [path].
  Database open(String path) => Database._(PureDatabase.open(path));
}

/// Small synchronous compatibility facade for `package:sqlite3` call sites.
class Database {
  Database._(this._database);

  final PureDatabase _database;

  /// Number of rows changed by the most recent call to [execute].
  int updatedRows = 0;

  /// Executes one supported SQL statement with positional or named [parameters].
  void execute(String sql, [Object? parameters = const []]) {
    updatedRows = _database.execute(sql, parameters);
  }

  /// Runs a `SELECT` or read-only `PRAGMA` and returns its rows.
  ResultSet select(String sql, [Object? parameters = const []]) => [
    for (final row in _database.select(sql, parameters))
      {
        for (final entry in row.entries)
          if (!entry.key.startsWith('@'))
            entry.key.split('.').last: entry.value,
      },
  ];

  /// Closes the database and releases its resources.
  void dispose() => _database.close();
}

Object? _value(Object? value) {
  if (value == null || value is String || value is num) return value;
  if (value is bool) return value ? 1 : 0;
  if (value is List<int>) return List<int>.from(value);
  throw PureSqlException('unsupported value: ${value.runtimeType}');
}

bool _hasBoundParameters(Object? parameters) => switch (parameters) {
  null => false,
  List values => values.isNotEmpty,
  Map values => values.isNotEmpty,
  _ => true,
};

List<Object?> _bindParameters(_Parser parser, Object? parameters) {
  if (parameters == null) parameters = const <Object?>[];
  if (parameters is List) {
    return parameters.map(_value).toList(growable: false);
  }
  if (parameters is! Map) {
    throw PureSqlException('parameters must be a list or a named map');
  }
  if (parser.hasPositionalParameters) {
    throw PureSqlException('named maps cannot bind positional parameters');
  }

  final namedValues = <String, Object?>{};
  for (final entry in parameters.entries) {
    if (entry.key is! String) {
      throw PureSqlException('named parameter keys must be strings');
    }
    final name = _parameterName(entry.key as String);
    if (name.isEmpty || namedValues.containsKey(name)) {
      throw PureSqlException('duplicate or empty named parameter: $name');
    }
    namedValues[name] = entry.value;
  }

  final usedNames = <String>{};
  final values = List<Object?>.filled(parser.parameterCount, null);
  for (final entry in parser.namedParameters.entries) {
    final name = _parameterName(entry.key);
    if (!namedValues.containsKey(name)) {
      throw PureSqlException('missing named parameter: $name');
    }
    usedNames.add(name);
    values[entry.value] = _value(namedValues[name]);
  }
  final unused = namedValues.keys.where((name) => !usedNames.contains(name));
  if (unused.isNotEmpty) {
    throw PureSqlException('unknown named parameter: ${unused.first}');
  }
  return values;
}

String _parameterName(String name) => name.replaceFirst(RegExp(r'^[:@$]'), '');

Object? _pragmaInput(_Expr expression, List<Object?> parameters) =>
    expression is _Column && !expression.name.contains('.')
    ? expression.name
    : _eval(expression, const {}, parameters);

String _key(String name) => name.toLowerCase();

String _renameSqlIdentifiersAfter(
  String sql,
  String oldName,
  String newName,
  String context,
) {
  final tokens = _Tokenizer(sql).tokenize();
  final targets = <_Token>[];
  for (var index = 0; index < tokens.length - 1; index++) {
    final token = tokens[index];
    if (token.type != _TokenType.word || token.quoted) continue;
    final keyword = token.text.toUpperCase();
    var targetIndex = index + 1;
    if (context == 'table') {
      if (keyword != 'TABLE' ||
          index == 0 ||
          tokens[index - 1].text.toUpperCase() != 'CREATE') {
        continue;
      }
      if (tokens[targetIndex].text.toUpperCase() == 'IF') targetIndex += 3;
    } else if (context == 'index') {
      if (keyword != 'ON') continue;
    } else if (context == 'references') {
      if (keyword != 'REFERENCES') continue;
    } else if (context == 'source') {
      if (keyword != 'FROM' && keyword != 'JOIN') continue;
    }
    if (targetIndex >= tokens.length) continue;
    final target = tokens[targetIndex];
    if (target.type == _TokenType.word && _key(target.text) == _key(oldName)) {
      targets.add(target);
    }
    if (context == 'table' || context == 'index') break;
  }
  if (targets.isEmpty) return sql;
  final quotedName = '"${newName.replaceAll('"', '""')}"';
  final result = StringBuffer();
  var offset = 0;
  for (final target in targets) {
    result
      ..write(sql.substring(offset, target.start))
      ..write(quotedName);
    offset = target.end;
  }
  result.write(sql.substring(offset));
  return result.toString();
}

String _renameSingleColumnToken(
  String sql,
  String tableName,
  String oldName,
  String newName,
) {
  final tokens = _Tokenizer(sql).tokenize();
  var tableIndex = -1;
  for (var index = 0; index < tokens.length - 1; index++) {
    if (tokens[index].text.toUpperCase() != 'CREATE' ||
        tokens[index + 1].text.toUpperCase() != 'TABLE') {
      continue;
    }
    var nameIndex = index + 2;
    if (tokens[nameIndex].text.toUpperCase() == 'IF') nameIndex += 3;
    if (nameIndex < tokens.length &&
        _key(tokens[nameIndex].text) == _key(tableName)) {
      tableIndex = nameIndex;
      break;
    }
  }
  if (tableIndex < 0) throw SqliteFormatException('invalid CREATE TABLE SQL');
  var openIndex = tableIndex + 1;
  while (openIndex < tokens.length && tokens[openIndex].text != '(') {
    openIndex++;
  }
  if (openIndex == tokens.length) {
    throw SqliteFormatException('invalid CREATE TABLE SQL');
  }
  var depth = 0;
  var closeIndex = -1;
  final matches = <_Token>[];
  for (var index = openIndex; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.text == '(') depth++;
    if (token.text == ')') {
      depth--;
      if (depth == 0) {
        closeIndex = index;
        break;
      }
    }
    if (index > openIndex &&
        token.type == _TokenType.word &&
        _key(token.text) == _key(oldName)) {
      matches.add(token);
    }
  }
  if (closeIndex < 0 || matches.length != 1) {
    throw PureSqlException('cannot safely rename column: $oldName');
  }
  final target = matches.single;
  final quotedName = '"${newName.replaceAll('"', '""')}"';
  return '${sql.substring(0, target.start)}$quotedName${sql.substring(target.end)}';
}

String _dropSingleColumnDefinition(
  String sql,
  String tableName,
  String columnName,
) {
  final tokens = _Tokenizer(sql).tokenize();
  var tableIndex = -1;
  for (var index = 0; index < tokens.length - 1; index++) {
    if (tokens[index].text.toUpperCase() != 'CREATE' ||
        tokens[index + 1].text.toUpperCase() != 'TABLE') {
      continue;
    }
    var nameIndex = index + 2;
    if (tokens[nameIndex].text.toUpperCase() == 'IF') nameIndex += 3;
    if (nameIndex < tokens.length &&
        _key(tokens[nameIndex].text) == _key(tableName)) {
      tableIndex = nameIndex;
      break;
    }
  }
  if (tableIndex < 0) throw SqliteFormatException('invalid CREATE TABLE SQL');
  var openIndex = tableIndex + 1;
  while (openIndex < tokens.length && tokens[openIndex].text != '(') {
    openIndex++;
  }
  if (openIndex == tokens.length) {
    throw SqliteFormatException('invalid CREATE TABLE SQL');
  }
  var depth = 1;
  var closeIndex = -1;
  final commas = <_Token>[];
  for (var index = openIndex + 1; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.text == '(') depth++;
    if (token.text == ')') {
      depth--;
      if (depth == 0) {
        closeIndex = index;
        break;
      }
    } else if (token.text == ',' && depth == 1) {
      commas.add(token);
    }
  }
  if (closeIndex < 0 || commas.length == 0) {
    throw PureSqlException('cannot drop the last column');
  }
  final starts = [tokens[openIndex].end, for (final comma in commas) comma.end];
  final ends = [
    for (final comma in commas) comma.start,
    tokens[closeIndex].start,
  ];
  final matches = <int>[];
  for (var segment = 0; segment < starts.length; segment++) {
    final first = tokens.firstWhere(
      (token) => token.start >= starts[segment] && token.end <= ends[segment],
      orElse: () => tokens.last,
    );
    if (first.type == _TokenType.word && _key(first.text) == _key(columnName)) {
      matches.add(segment);
    }
  }
  if (matches.length != 1) {
    throw PureSqlException('cannot safely drop column: $columnName');
  }
  final segment = matches.single;
  final start = segment < commas.length
      ? starts[segment]
      : commas[segment - 1].start;
  final end = segment < commas.length ? commas[segment].end : ends[segment];
  return '${sql.substring(0, start)}${sql.substring(end)}';
}

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

// ponytail: O(n^2) distinct pass; replace with hashed SQLite-value keys if result sets grow.
List<SqlRow> _distinctRows(List<SqlRow> rows) {
  final distinct = <SqlRow>[];
  for (final row in rows) {
    final duplicate = distinct.any((candidate) {
      if (candidate.length != row.length ||
          !candidate.keys.every(row.containsKey)) {
        return false;
      }
      return candidate.entries.every(
        (entry) => _valueEqual(entry.value, row[entry.key]),
      );
    });
    if (!duplicate) distinct.add(row);
  }
  return distinct;
}

bool _valueEqual(Object? left, Object? right) {
  if (left is List<int> && right is List<int>) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
  return left == right;
}

Object? _eval(
  _Expr expression,
  SqlRow row,
  List<Object?> parameters, {
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) => switch (expression) {
  _Literal(:final value) => value,
  _Param(:final index) =>
    index < parameters.length
        ? parameters[index]
        : throw PureSqlException('missing parameter ${index + 1}'),
  _Column(:final name) => _readColumn(row, name),
  _Function(:final name, :final arguments) when name.toUpperCase() == 'IIF' =>
    _evalIif(arguments, row, parameters, selectSubquery: selectSubquery),
  _Function(:final name, :final arguments) => _evalFunction(
    name,
    arguments,
    row,
    parameters,
    selectSubquery: selectSubquery,
  ),
  _Binary(:final left, :final operator, :final right) => _evalBinary(
    left,
    operator,
    right,
    row,
    parameters,
    selectSubquery: selectSubquery,
  ),
  _In(:final expression, :final values, :final negated, :final query) =>
    _evalIn(
      expression,
      values,
      negated,
      row,
      parameters,
      query: query,
      selectSubquery: selectSubquery,
    ),
  _Exists(:final query) =>
    selectSubquery == null
        ? throw PureSqlException('EXISTS requires a database query context')
        : selectSubquery(query, row, parameters).isNotEmpty,
  _Unary(:final operator, :final expression) => _evalUnary(
    operator,
    _eval(expression, row, parameters, selectSubquery: selectSubquery),
  ),
  _Cast(:final expression, :final type) => _castSqlValue(
    _eval(expression, row, parameters, selectSubquery: selectSubquery),
    type,
  ),
  _Between(:final expression, :final lower, :final upper, :final negated) =>
    _evalBetween(
      _eval(expression, row, parameters, selectSubquery: selectSubquery),
      _eval(lower, row, parameters, selectSubquery: selectSubquery),
      _eval(upper, row, parameters, selectSubquery: selectSubquery),
      negated,
    ),
  _PatternMatch(
    :final expression,
    :final pattern,
    :final operator,
    :final negated,
    :final escape,
  ) =>
    _evalPatternMatch(
      _eval(expression, row, parameters, selectSubquery: selectSubquery),
      _eval(pattern, row, parameters, selectSubquery: selectSubquery),
      operator,
      negated,
      escape == null
          ? null
          : _eval(escape, row, parameters, selectSubquery: selectSubquery),
    ),
  _Case(:final branches, :final otherwise) => _evalCase(
    branches,
    otherwise,
    row,
    parameters,
    selectSubquery: selectSubquery,
  ),
  _ScalarSubquery(:final query) =>
    selectSubquery == null
        ? throw PureSqlException(
            'scalar subquery must be projected by the database',
          )
        : _scalarSubqueryValue(selectSubquery(query, row, parameters)),
};

Object? _scalarSubqueryValue(List<SqlRow> rows) {
  if (rows.isEmpty) return null;
  if (rows.first.length != 1) {
    throw PureSqlException('scalar subquery must return one column');
  }
  return rows.first.values.first;
}

Object? _evalUnary(String operator, Object? value) {
  if (operator == 'NOT') return value == null ? null : !_truthy(value);
  if (value == null) return null;
  if (operator == '+' || operator == '-') {
    if (value is! num) throw PureSqlException('unary operand must be numeric');
    return operator == '+' ? value : -value;
  }
  if (operator == '~') {
    if (value is! int)
      throw PureSqlException('bitwise operand must be integer');
    return ~value;
  }
  throw PureSqlException('unsupported unary operator: $operator');
}

Object? _castSqlValue(Object? value, String type) {
  if (value == null) return null;
  final affinity = type.toUpperCase();
  if (affinity.contains('INT')) {
    if (value is num) return value.toInt();
    final match = RegExp(r'^\s*[+-]?\d+').firstMatch(value.toString());
    return match == null ? 0 : int.tryParse(match.group(0)!.trim()) ?? 0;
  }
  if (affinity.contains('CHAR') ||
      affinity.contains('CLOB') ||
      affinity.contains('TEXT')) {
    return value is List<int>
        ? utf8.decode(value, allowMalformed: true)
        : value.toString();
  }
  if (affinity.contains('BLOB') || affinity.isEmpty) {
    return value is List<int>
        ? List<int>.from(value)
        : utf8.encode(value.toString());
  }
  if (affinity.contains('REAL') ||
      affinity.contains('FLOA') ||
      affinity.contains('DOUB')) {
    if (value is num) return value.toDouble();
    final match = RegExp(
      r'^\s*[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?',
    ).firstMatch(value.toString());
    return match == null ? 0.0 : double.tryParse(match.group(0)!.trim()) ?? 0.0;
  }
  if (value is num || value is List<int>) return value;
  final text = value.toString().trim();
  return int.tryParse(text) ?? double.tryParse(text) ?? value;
}

Object? _evalBetween(
  Object? value,
  Object? lower,
  Object? upper,
  bool negated,
) {
  if (value == null || lower == null || upper == null) return null;
  final result = _compare(value, lower) >= 0 && _compare(value, upper) <= 0;
  return negated ? !result : result;
}

Object? _evalPatternMatch(
  Object? value,
  Object? pattern,
  String operator,
  bool negated,
  Object? escape,
) {
  if (value == null || pattern == null) return null;
  final text = value.toString();
  final source = pattern.toString();
  final matched = switch (operator) {
    'LIKE' => _like(text, source, escape: escape?.toString()),
    'GLOB' => _glob(text, source),
    'REGEXP' => _matchesRegexp(text, source),
    _ => throw PureSqlException('unsupported pattern operator: $operator'),
  };
  return negated ? !matched : matched;
}

Object? _evalCase(
  List<(_Expr, _Expr)> branches,
  _Expr? otherwise,
  SqlRow row,
  List<Object?> parameters, {
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  for (final (condition, value) in branches) {
    if (_truthy(
      _eval(condition, row, parameters, selectSubquery: selectSubquery),
    )) {
      return _eval(value, row, parameters, selectSubquery: selectSubquery);
    }
  }
  return otherwise == null
      ? null
      : _eval(otherwise, row, parameters, selectSubquery: selectSubquery);
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
  List<Object?> parameters, {
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  final left = _eval(
    leftExpression,
    row,
    parameters,
    selectSubquery: selectSubquery,
  );
  final right = _eval(
    rightExpression,
    row,
    parameters,
    selectSubquery: selectSubquery,
  );
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
  List<Object?> parameters, {
  _Select? query,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  final evaluatedValues = query == null
      ? values
            .map(
              (item) =>
                  _eval(item, row, parameters, selectSubquery: selectSubquery),
            )
            .toList()
      : () {
          if (selectSubquery == null) {
            throw PureSqlException(
              'IN subquery requires a database query context',
            );
          }
          final rows = selectSubquery(query, row, parameters);
          if (query.items.length != 1 ||
              rows.any((result) => result.length != 1)) {
            throw PureSqlException('IN subquery must return one column');
          }
          return [for (final result in rows) result.values.first];
        }();
  if (evaluatedValues.isEmpty) return negated;
  final value = _eval(
    expression,
    row,
    parameters,
    selectSubquery: selectSubquery,
  );
  if (value == null) return null;
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
  List<Object?> parameters, {
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  return _applyFunction(
    name,
    arguments
        .map(
          (argument) =>
              _eval(argument, row, parameters, selectSubquery: selectSubquery),
        )
        .toList(),
  );
}

Object? _evalIif(
  List<_Expr> arguments,
  SqlRow row,
  List<Object?> parameters, {
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  if (arguments.length != 3) {
    throw PureSqlException('IIF expects three arguments');
  }
  return _truthy(
        _eval(arguments.first, row, parameters, selectSubquery: selectSubquery),
      )
      ? _eval(arguments[1], row, parameters, selectSubquery: selectSubquery)
      : _eval(arguments[2], row, parameters, selectSubquery: selectSubquery);
}

Object? _applyFunction(String name, List<Object?> values) {
  switch (name.toUpperCase()) {
    case 'ACOS':
    case 'ACOSH':
    case 'ASIN':
    case 'ASINH':
    case 'ATAN':
    case 'ATAN2':
    case 'ATANH':
    case 'CEIL':
    case 'CEILING':
    case 'COS':
    case 'COSH':
    case 'DEGREES':
    case 'EXP':
    case 'FLOOR':
    case 'LN':
    case 'LOG':
    case 'LOG10':
    case 'LOG2':
    case 'MOD':
    case 'PI':
    case 'POW':
    case 'POWER':
    case 'RADIANS':
    case 'SIGN':
    case 'SIN':
    case 'SINH':
    case 'SQRT':
    case 'TAN':
    case 'TANH':
    case 'TRUNC':
      return _applyMathFunction(name.toUpperCase(), values);
    case 'COALESCE':
      if (values.isEmpty) throw PureSqlException('COALESCE requires arguments');
      for (final value in values) {
        if (value != null) return value;
      }
      return null;
    case 'IFNULL':
      _requireArity(name, values, 2);
      return values.first ?? values.last;
    case 'LIKELY':
    case 'UNLIKELY':
      _requireArity(name, values, 1);
      return values.single;
    case 'LIKELIHOOD':
      _requireArity(name, values, 2);
      return values.first;
    case 'NULLIF':
      _requireArity(name, values, 2);
      return _valueEqual(values.first, values.last) ? null : values.first;
    case 'LOWER':
      _requireArity(name, values, 1);
      return values.single?.toString().toLowerCase();
    case 'UPPER':
      _requireArity(name, values, 1);
      return values.single?.toString().toUpperCase();
    case 'ABS':
      _requireArity(name, values, 1);
      return values.single == null
          ? null
          : values.single is num
          ? (values.single as num).abs()
          : throw PureSqlException('ABS requires a numeric value');
    case 'ROUND':
      if (values.isEmpty || values.length > 2) {
        throw PureSqlException('ROUND expects one or two arguments');
      }
      if (values.first == null) return null;
      if (values.first is! num || values.length == 2 && values[1] is! num) {
        throw PureSqlException('ROUND requires numeric arguments');
      }
      final digits = values.length == 1 ? 0 : (values[1] as num).toInt();
      if (digits.abs() > 100) return values.first;
      final scale = math.pow(10, digits).toDouble();
      return ((values.first! as num) * scale).roundToDouble() / scale;
    case 'LENGTH':
      _requireArity(name, values, 1);
      final value = values.single;
      return value == null
          ? null
          : value is List<int>
          ? value.length
          : value.toString().runes.length;
    case 'SUBSTR':
    case 'SUBSTRING':
      if (values.length < 2 || values.length > 3) {
        throw PureSqlException('$name expects two or three arguments');
      }
      if (values[0] == null || values[1] == null) return null;
      final runes = values[0].toString().runes.toList();
      final start = (values[1] as num).toInt();
      final offset = start < 0 ? runes.length + start : start - 1;
      if (values.length == 2) {
        return String.fromCharCodes(runes.skip(offset.clamp(0, runes.length)));
      }
      final length = (values[2] as num).toInt();
      final from = length < 0
          ? (offset + length).clamp(0, runes.length)
          : offset.clamp(0, runes.length);
      final to = length < 0
          ? offset.clamp(0, runes.length)
          : (offset + length).clamp(0, runes.length);
      return String.fromCharCodes(runes.sublist(from, to));
    case 'TRIM':
    case 'LTRIM':
    case 'RTRIM':
      if (values.isEmpty || values.length > 2) {
        throw PureSqlException('$name expects one or two arguments');
      }
      if (values.first == null) return null;
      return _trimSqlText(
        values.first.toString(),
        values.length == 1 ? ' ' : values[1]?.toString() ?? '',
        left: name.toUpperCase() != 'RTRIM',
        right: name.toUpperCase() != 'LTRIM',
      );
    case 'REPLACE':
      _requireArity(name, values, 3);
      if (values.any((value) => value == null)) return null;
      return values[0].toString().replaceAll(
        values[1].toString(),
        values[2].toString(),
      );
    case 'INSTR':
      _requireArity(name, values, 2);
      if (values.any((value) => value == null)) return null;
      final haystack = values[0].toString();
      final needle = values[1].toString();
      final position = haystack.indexOf(needle);
      return position < 0
          ? 0
          : haystack.substring(0, position).runes.length + 1;
    case 'TYPEOF':
      _requireArity(name, values, 1);
      final value = values.single;
      if (value == null) return 'null';
      if (value is int || value is bool) return 'integer';
      if (value is num) return 'real';
      if (value is List<int>) return 'blob';
      return 'text';
    case 'ZEROBLOB':
    case 'RANDOMBLOB':
      _requireArity(name, values, 1);
      if (values.single is! num) {
        throw PureSqlException('$name requires an integer length');
      }
      final length = (values.single as num).toInt();
      if (length > 16 * 1024 * 1024) {
        throw PureSqlException('$name length exceeds the 16 MiB limit');
      }
      if (name.toUpperCase() == 'ZEROBLOB') {
        return List<int>.filled(math.max(0, length), 0);
      }
      final random = math.Random.secure();
      return List<int>.generate(
        math.max(1, length),
        (_) => random.nextInt(256),
      );
    case 'RANDOM':
      _requireArity(name, values, 0);
      final random = math.Random.secure();
      final value = (random.nextInt(1 << 31) << 32) | random.nextInt(1 << 32);
      return random.nextBool() ? value : -value;
    case 'HEX':
      _requireArity(name, values, 1);
      if (values.single == null) return '';
      final bytes = values.single is List<int>
          ? values.single as List<int>
          : utf8.encode(values.single.toString());
      return bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
    case 'QUOTE':
      _requireArity(name, values, 1);
      final value = values.single;
      if (value == null) return 'NULL';
      if (value is List<int>) return "X'${_applyFunction('HEX', [value])}'";
      if (value is num) return value.toString();
      return "'${value.toString().replaceAll("'", "''")}'";
    case 'CHAR':
      return String.fromCharCodes(
        values.whereType<num>().map((v) => v.toInt().clamp(0, 0x10ffff)),
      );
    case 'UNICODE':
      _requireArity(name, values, 1);
      final runes = values.single?.toString().runes;
      return runes == null || runes.isEmpty ? null : runes.first;
    case 'CONCAT':
      return values
          .where((value) => value != null)
          .map((value) => value.toString())
          .join();
    case 'CONCAT_WS':
      if (values.isEmpty)
        throw PureSqlException('CONCAT_WS requires a separator');
      if (values.first == null) return null;
      return values
          .skip(1)
          .where((value) => value != null)
          .map((value) => value.toString())
          .join(values.first.toString());
    case 'DATE':
    case 'TIME':
    case 'DATETIME':
      return _applyDateFunction(name.toUpperCase(), values);
    case 'JULIANDAY':
      final date = _dateTimeFromValues(values);
      return date == null
          ? null
          : date.millisecondsSinceEpoch / Duration.millisecondsPerDay +
                2440587.5;
    case 'UNIXEPOCH':
      final date = _dateTimeFromValues(values);
      return date == null ? null : date.millisecondsSinceEpoch ~/ 1000;
    case 'STRFTIME':
      if (values.length < 2 || values.first is! String) return null;
      final date = _dateTimeFromValues(values.skip(1).toList());
      return date == null
          ? null
          : _formatSqlDate(values.first! as String, date);
    case 'MIN':
    case 'MAX':
      if (values.isEmpty) throw PureSqlException('$name requires arguments');
      if (values.length == 1) return values.single;
      final present = values.where((value) => value != null).toList();
      if (present.isEmpty) return null;
      return present.reduce((left, right) {
        final comparison = _compare(left, right);
        return name.toUpperCase() == 'MIN'
            ? comparison <= 0
                  ? left
                  : right
            : comparison >= 0
            ? left
            : right;
      });
    case 'COUNT':
      _requireArity(name, values, 1);
      return values.single == '*'
          ? 1
          : values.single == null
          ? 0
          : 1;
    default:
      throw PureSqlException('unsupported function: $name');
  }
}

Object? _applyMathFunction(String name, List<Object?> values) {
  final arity = switch (name) {
    'PI' => 0,
    'ATAN2' || 'MOD' || 'POW' || 'POWER' => 2,
    'LOG' => values.length,
    _ => 1,
  };
  if (name == 'LOG') {
    if (values.length < 1 || values.length > 2) {
      throw PureSqlException('LOG expects one or two arguments');
    }
  } else {
    _requireArity(name, values, arity);
  }
  if (values.any((value) => value == null)) return null;
  final numbers = <double>[];
  for (final value in values) {
    final number = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value.trim())
        : null;
    if (number == null) return null;
    numbers.add(number);
  }
  final result = switch (name) {
    'PI' => math.pi,
    'ACOS' => numbers[0].abs() > 1 ? double.nan : math.acos(numbers[0]),
    'ACOSH' =>
      numbers[0] < 1
          ? double.nan
          : math.log(numbers[0] + math.sqrt(numbers[0] * numbers[0] - 1)),
    'ASIN' => numbers[0].abs() > 1 ? double.nan : math.asin(numbers[0]),
    'ASINH' =>
      numbers[0].isNegative
          ? -math.log(-numbers[0] + math.sqrt(numbers[0] * numbers[0] + 1))
          : math.log(numbers[0] + math.sqrt(numbers[0] * numbers[0] + 1)),
    'ATAN' => math.atan(numbers[0]),
    'ATAN2' => math.atan2(numbers[0], numbers[1]),
    'ATANH' =>
      numbers[0].abs() >= 1
          ? double.nan
          : math.log((1 + numbers[0]) / (1 - numbers[0])) / 2,
    'CEIL' || 'CEILING' => numbers[0].ceilToDouble(),
    'COS' => math.cos(numbers[0]),
    'COSH' => (math.exp(numbers[0]) + math.exp(-numbers[0])) / 2,
    'DEGREES' => numbers[0] * 180 / math.pi,
    'EXP' => math.exp(numbers[0]),
    'FLOOR' => numbers[0].floorToDouble(),
    'LN' => numbers[0] <= 0 ? double.nan : math.log(numbers[0]),
    'LOG' =>
      numbers[0] <= 0 ||
              values.length == 2 && (numbers[0] == 1 || numbers[1] <= 0)
          ? double.nan
          : math.log(values.length == 1 ? numbers[0] : numbers[1]) /
                (values.length == 1 ? math.ln10 : math.log(numbers[0])),
    'LOG10' => numbers[0] <= 0 ? double.nan : math.log(numbers[0]) / math.ln10,
    'LOG2' => numbers[0] <= 0 ? double.nan : math.log(numbers[0]) / math.ln2,
    'MOD' => numbers[1] == 0 ? double.nan : numbers[0] % numbers[1],
    'POW' || 'POWER' => math.pow(numbers[0], numbers[1]).toDouble(),
    'RADIANS' => numbers[0] * math.pi / 180,
    'SIGN' => numbers[0].compareTo(0).toDouble(),
    'SIN' => math.sin(numbers[0]),
    'SINH' => (math.exp(numbers[0]) - math.exp(-numbers[0])) / 2,
    'SQRT' => numbers[0] < 0 ? double.nan : math.sqrt(numbers[0]),
    'TAN' => math.tan(numbers[0]),
    'TANH' => _sqlTanh(numbers[0]),
    'TRUNC' => numbers[0].truncateToDouble(),
    _ => throw PureSqlException('unsupported function: $name'),
  };
  return result.isFinite ? result : null;
}

double _sqlTanh(double value) {
  if (value > 20) return 1;
  if (value < -20) return -1;
  final positive = math.exp(value);
  final negative = math.exp(-value);
  return (positive - negative) / (positive + negative);
}

void _requireArity(String name, List<Object?> values, int count) {
  if (values.length != count) {
    throw PureSqlException('$name expects $count argument(s)');
  }
}

String _trimSqlText(
  String value,
  String trimCharacters, {
  required bool left,
  required bool right,
}) {
  final runes = value.runes.toList();
  final trimSet = trimCharacters.runes.toSet();
  var start = 0;
  var end = runes.length;
  if (left) {
    while (start < end && trimSet.contains(runes[start])) {
      start++;
    }
  }
  if (right) {
    while (end > start && trimSet.contains(runes[end - 1])) {
      end--;
    }
  }
  return String.fromCharCodes(runes.sublist(start, end));
}

DateTime? _dateTimeFromValues(List<Object?> values) {
  if (values.isEmpty) return DateTime.now().toUtc();
  final value = values.first;
  if (value == null) return null;
  final modifiers = values.skip(1).map((value) => value?.toString()).toList();
  DateTime? result;
  if (value is num) {
    if (modifiers.contains('unixepoch')) {
      result = DateTime.fromMillisecondsSinceEpoch(
        (value * 1000).round(),
        isUtc: true,
      );
    } else {
      final milliseconds = ((value - 2440587.5) * 86400000).round();
      result = DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    }
  } else {
    final text = value.toString();
    result = DateTime.tryParse(
      text.contains(' ') && !text.contains('T')
          ? text.replaceFirst(' ', 'T')
          : text,
    )?.toUtc();
  }
  if (result == null) return null;
  for (final modifier in modifiers) {
    if (modifier == null || modifier == 'unixepoch' || modifier == 'utc') {
      continue;
    }
    if (modifier == 'localtime') continue;
    if (modifier.startsWith('start of ')) {
      final current = result!;
      result = switch (modifier.substring(9)) {
        'day' => DateTime.utc(current.year, current.month, current.day),
        'month' => DateTime.utc(current.year, current.month),
        'year' => DateTime.utc(current.year),
        _ => null,
      };
      if (result == null) return null;
      continue;
    }
    final shift = RegExp(
      r'^([+-]?\d+(?:\.\d+)?)\s+(seconds?|minutes?|hours?|days?|weeks?)$',
    ).firstMatch(modifier);
    if (shift == null) return null;
    final amount = double.parse(shift.group(1)!);
    final unit = shift.group(2)!.toLowerCase();
    final factor = switch (unit) {
      'second' || 'seconds' => 1000.0,
      'minute' || 'minutes' => 60000.0,
      'hour' || 'hours' => 3600000.0,
      'day' || 'days' => 86400000.0,
      'week' || 'weeks' => 604800000.0,
      _ => 0.0,
    };
    result = result!.add(Duration(milliseconds: (amount * factor).round()));
  }
  return result;
}

String? _applyDateFunction(String name, List<Object?> values) {
  if (values.length > 4) return null;
  final date = _dateTimeFromValues(values);
  if (date == null) return null;
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final time =
      '${date.hour.toString().padLeft(2, '0')}'
      ':${date.minute.toString().padLeft(2, '0')}'
      ':${date.second.toString().padLeft(2, '0')}';
  return switch (name) {
    'DATE' => '$year-$month-$day',
    'TIME' => time,
    _ => '$year-$month-$day $time',
  };
}

String? _formatSqlDate(String format, DateTime date) {
  final output = StringBuffer();
  for (var index = 0; index < format.length; index++) {
    final char = format[index];
    if (char != '%') {
      output.write(char);
      continue;
    }
    if (++index >= format.length) return null;
    final dayOfYear = date.difference(DateTime.utc(date.year)).inDays + 1;
    final value = switch (format[index]) {
      '%' => '%',
      'Y' => date.year.toString().padLeft(4, '0'),
      'm' => date.month.toString().padLeft(2, '0'),
      'd' => date.day.toString().padLeft(2, '0'),
      'e' => date.day.toString().padLeft(2, ' '),
      'H' => date.hour.toString().padLeft(2, '0'),
      'M' => date.minute.toString().padLeft(2, '0'),
      'S' => date.second.toString().padLeft(2, '0'),
      'f' =>
        '${date.second.toString().padLeft(2, '0')}.${date.millisecond.toString().padLeft(3, '0')}',
      'j' => dayOfYear.toString().padLeft(3, '0'),
      'w' => (date.weekday % 7).toString(),
      's' => (date.millisecondsSinceEpoch ~/ 1000).toString(),
      'J' => (date.millisecondsSinceEpoch / 86400000 + 2440587.5).toString(),
      'W' => _weekOfYear(date).toString().padLeft(2, '0'),
      _ => null,
    };
    if (value == null) return null;
    output.write(value);
  }
  return output.toString();
}

int _weekOfYear(DateTime date) {
  final firstMonday = DateTime.utc(date.year, 1, 1);
  return (date.difference(firstMonday).inDays + firstMonday.weekday - 1) ~/ 7;
}

bool _containsAggregate(_Expr expression) => switch (expression) {
  _Function(:final name, :final arguments) =>
    _isAggregateFunction(name, arguments.length) ||
        arguments.any(_containsAggregate),
  _Binary(:final left, :final right) =>
    _containsAggregate(left) || _containsAggregate(right),
  _Unary(:final expression) => _containsAggregate(expression),
  _Cast(:final expression) => _containsAggregate(expression),
  _Between(:final expression, :final lower, :final upper) =>
    _containsAggregate(expression) ||
        _containsAggregate(lower) ||
        _containsAggregate(upper),
  _PatternMatch(:final expression, :final pattern, :final escape) =>
    _containsAggregate(expression) ||
        _containsAggregate(pattern) ||
        (escape != null && _containsAggregate(escape)),
  _Case(:final branches, :final otherwise) =>
    branches.any(
          (branch) =>
              _containsAggregate(branch.$1) || _containsAggregate(branch.$2),
        ) ||
        (otherwise != null && _containsAggregate(otherwise)),
  _ => false,
};

bool _isAggregateFunction(String name, int argumentCount) =>
    switch (name.toUpperCase()) {
      'COUNT' || 'SUM' || 'AVG' || 'TOTAL' || 'GROUP_CONCAT' => true,
      'MIN' || 'MAX' => argumentCount == 1,
      _ => false,
    };

Object? _evalGroup(
  _Expr expression,
  List<SqlRow> group,
  SqlRow row,
  List<Object?> parameters, {
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) => _evalGroupWithSubqueries(
  expression,
  group,
  row,
  parameters,
  selectSubquery,
);

Object? _evalGroupWithSubqueries(
  _Expr expression,
  List<SqlRow> group,
  SqlRow row,
  List<Object?> parameters,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
) {
  Object? evaluate(_Expr value) =>
      _evalGroupWithSubqueries(value, group, row, parameters, selectSubquery);

  return switch (expression) {
    _Function(:final name, :final arguments, :final distinct)
        when name.toUpperCase() == 'COUNT' && arguments.length == 1 =>
      _countGroup(
        arguments.single,
        group,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
      ),
    _Function(:final name, :final arguments, :final distinct)
        when name.toUpperCase() == 'MIN' && arguments.length == 1 =>
      _minGroup(
        arguments.single,
        group,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
      ),
    _Function(:final name, :final arguments, :final distinct)
        when name.toUpperCase() == 'SUM' && arguments.length == 1 =>
      _sumGroup(
        arguments.single,
        group,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
      ),
    _Function(:final name, :final arguments, :final distinct)
        when name.toUpperCase() == 'MAX' && arguments.length == 1 =>
      _maxGroup(
        arguments.single,
        group,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
      ),
    _Function(:final name, :final arguments, :final distinct)
        when name.toUpperCase() == 'AVG' && arguments.length == 1 =>
      _avgGroup(
        arguments.single,
        group,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
      ),
    _Function(:final name, :final arguments, :final distinct)
        when name.toUpperCase() == 'TOTAL' && arguments.length == 1 =>
      _totalGroup(
        arguments.single,
        group,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
      ),
    _Function(:final name, :final arguments, :final distinct)
        when name.toUpperCase() == 'GROUP_CONCAT' =>
      _groupConcat(
        arguments,
        group,
        row,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
      ),
    _Function(:final name, :final arguments) when name.toUpperCase() == 'IIF' =>
      arguments.length != 3
          ? throw PureSqlException('IIF expects three arguments')
          : _truthy(evaluate(arguments[0]))
          ? evaluate(arguments[1])
          : evaluate(arguments[2]),
    _Function(:final name, :final arguments) => _applyFunction(
      name,
      arguments.map(evaluate).toList(),
    ),
    _Binary(:final left, :final operator, :final right) => _binary(
      operator,
      evaluate(left),
      evaluate(right),
    ),
    _Unary(:final operator, :final expression) => _evalUnary(
      operator,
      evaluate(expression),
    ),
    _Cast(:final expression, :final type) => _castSqlValue(
      evaluate(expression),
      type,
    ),
    _Between(:final expression, :final lower, :final upper, :final negated) =>
      _evalBetween(
        evaluate(expression),
        evaluate(lower),
        evaluate(upper),
        negated,
      ),
    _PatternMatch(
      :final expression,
      :final pattern,
      :final operator,
      :final negated,
      :final escape,
    ) =>
      _evalPatternMatch(
        evaluate(expression),
        evaluate(pattern),
        operator,
        negated,
        escape == null ? null : evaluate(escape),
      ),
    _Case(:final branches, :final otherwise) => _evalCase(
      branches,
      otherwise,
      row,
      parameters,
      selectSubquery: selectSubquery,
    ),
    _ => _eval(expression, row, parameters, selectSubquery: selectSubquery),
  };
}

int _countGroup(
  _Expr expression,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  if (expression is _Column && expression.name == '*') return group.length;
  final values = <Object?>{};
  var count = 0;
  for (final row in group) {
    final value = _eval(
      expression,
      row,
      parameters,
      selectSubquery: selectSubquery,
    );
    if (value != null && (!distinct || values.add(value))) count++;
  }
  return count;
}

Object? _sumGroup(
  _Expr expression,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  num? sum;
  final seen = <Object?>{};
  for (final row in group) {
    final value = _eval(
      expression,
      row,
      parameters,
      selectSubquery: selectSubquery,
    );
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
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  Object? maximum;
  final seen = <Object?>{};
  for (final row in group) {
    final value = _eval(
      expression,
      row,
      parameters,
      selectSubquery: selectSubquery,
    );
    if (value == null || distinct && !seen.add(value)) continue;
    if (maximum == null || _compare(value, maximum) > 0) maximum = value;
  }
  return maximum;
}

Object? _minGroup(
  _Expr expression,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  Object? minimum;
  final seen = <Object?>{};
  for (final row in group) {
    final value = _eval(
      expression,
      row,
      parameters,
      selectSubquery: selectSubquery,
    );
    if (value == null || distinct && !seen.add(value)) continue;
    if (minimum == null || _compare(value, minimum) < 0) minimum = value;
  }
  return minimum;
}

Object? _avgGroup(
  _Expr expression,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  num sum = 0;
  var count = 0;
  final seen = <Object?>{};
  for (final row in group) {
    final value = _eval(
      expression,
      row,
      parameters,
      selectSubquery: selectSubquery,
    );
    if (value is num && (!distinct || seen.add(value))) {
      sum += value;
      count++;
    }
  }
  return count == 0 ? null : sum / count;
}

double _totalGroup(
  _Expr expression,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  num total = 0;
  final seen = <Object?>{};
  for (final row in group) {
    final value = _eval(
      expression,
      row,
      parameters,
      selectSubquery: selectSubquery,
    );
    if (value is num && (!distinct || seen.add(value))) total += value;
  }
  return total.toDouble();
}

Object? _groupConcat(
  List<_Expr> arguments,
  List<SqlRow> group,
  SqlRow row,
  List<Object?> parameters, {
  required bool distinct,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  if (arguments.isEmpty || arguments.length > 2) {
    throw PureSqlException('group_concat expects one or two arguments');
  }
  final separator = arguments.length == 1
      ? ','
      : _evalGroup(
              arguments[1],
              group,
              row,
              parameters,
              selectSubquery: selectSubquery,
            )?.toString() ??
            '';
  final seen = <Object?>{};
  final values = <String>[];
  for (final source in group) {
    final value = _eval(
      arguments.first,
      source,
      parameters,
      selectSubquery: selectSubquery,
    );
    if (value != null && (!distinct || seen.add(value))) {
      values.add(value.toString());
    }
  }
  return values.isEmpty ? null : values.join(separator);
}

Object? _readColumn(SqlRow row, String name) {
  final qualified = row['@$name'];
  if (qualified != null || row.containsKey('@$name')) return qualified;
  for (final entry in row.entries) {
    if (entry.key.startsWith('@') &&
        _key(entry.key.substring(1)) == _key(name)) {
      return entry.value;
    }
  }
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
    case '%':
      if (left == null || right == null) return null;
      if (left is! num || right is! num) {
        throw PureSqlException('arithmetic operands must be numeric');
      }
      if (operator == '+') return left + right;
      if (operator == '-') return left - right;
      if (operator == '*') return left * right;
      if (right == 0) return null;
      if (operator == '%') return left.toInt().remainder(right.toInt());
      return left is int && right is int ? left ~/ right : left / right;
    case '||':
      return left == null || right == null
          ? null
          : '${left.toString()}${right.toString()}';
    case '&':
    case '|':
    case '^':
    case '<<':
    case '>>':
      if (left == null || right == null) return null;
      if (left is! num || right is! num) {
        throw PureSqlException('bitwise operands must be numeric');
      }
      final a = left.toInt();
      final b = right.toInt();
      return switch (operator) {
        '&' => a & b,
        '|' => a | b,
        '^' => a ^ b,
        '<<' => a << b,
        _ => a >> b,
      };
    case 'AND':
      if (left != null && !_truthy(left) || right != null && !_truthy(right)) {
        return false;
      }
      return left == null || right == null ? null : true;
    case 'OR':
      if (left != null && _truthy(left) || right != null && _truthy(right)) {
        return true;
      }
      return left == null || right == null ? null : false;
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

bool _like(String value, String pattern, {String? escape}) {
  value = _sqliteNoCase(value);
  pattern = _sqliteNoCase(pattern);
  escape = escape == null ? null : _sqliteNoCase(escape);
  final escapeRunes = escape?.runes.toList();
  if (escapeRunes != null && escapeRunes.length != 1) {
    throw PureSqlException('LIKE ESCAPE must be one character');
  }
  final runes = pattern.runes.toList();
  final expression = StringBuffer('^');
  var escaped = false;
  for (final rune in runes) {
    final char = String.fromCharCode(rune);
    if (escaped) {
      expression.write(RegExp.escape(char));
      escaped = false;
    } else if (escapeRunes != null && rune == escapeRunes.single) {
      escaped = true;
    } else if (char == '%') {
      expression.write('.*');
    } else if (char == '_') {
      expression.write('.');
    } else {
      expression.write(RegExp.escape(char));
    }
  }
  if (escaped)
    throw PureSqlException('LIKE pattern ends with ESCAPE character');
  expression.write(r'$');
  return RegExp(expression.toString(), dotAll: true).hasMatch(value);
}

bool _matchesRegexp(String value, String pattern) {
  try {
    return RegExp(pattern).hasMatch(value);
  } on FormatException catch (error) {
    throw PureSqlException('invalid REGEXP pattern: ${error.message}');
  }
}

bool _glob(String value, String pattern) {
  final runes = pattern.runes.toList();
  final expression = StringBuffer('^');
  for (var index = 0; index < runes.length; index++) {
    final char = String.fromCharCode(runes[index]);
    if (char == '*') {
      expression.write('.*');
    } else if (char == '?') {
      expression.write('.');
    } else if (char == '[') {
      final close = runes.indexOf(']'.codeUnitAt(0), index + 1);
      if (close < 0) {
        expression.write(r'\[');
      } else {
        final contents = String.fromCharCodes(runes.sublist(index + 1, close));
        expression.write('[');
        expression.write(
          contents.startsWith('!') ? '^${contents.substring(1)}' : contents,
        );
        expression.write(']');
        index = close;
      }
    } else {
      expression.write(RegExp.escape(char));
    }
  }
  expression.write(r'$');
  return RegExp(expression.toString(), dotAll: true).hasMatch(value);
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
    this.uniqueConstraints = const [],
    this.foreignKeyConstraints = const [],
  });

  String name;
  final List<_ColumnDef> columns;
  final int? rootPage;
  final List<String> primaryKeyColumns;
  final List<_Expr> checkExpressions;
  final List<List<String>> uniqueConstraints;
  final List<_ForeignKey> foreignKeyConstraints;
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
      [for (final column in columns) column.copy()],
      rootPage: rootPage,
      schemaSql: schemaSql,
      primaryKeyColumns: List<String>.from(primaryKeyColumns),
      checkExpressions: List<_Expr>.from(checkExpressions),
      uniqueConstraints: [
        for (final constraint in uniqueConstraints)
          List<String>.from(constraint),
      ],
      foreignKeyConstraints: [
        for (final foreignKey in foreignKeyConstraints) foreignKey.copy(),
      ],
    );
    result.indexes.addAll([for (final index in indexes) index.copy(result)]);
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
    this.onDelete = 'NO ACTION',
    this.onUpdate = 'NO ACTION',
    this.collation,
    this.checkExpressions = const [],
  });

  String name;
  final String? typeName;
  final bool notNull;
  final bool primaryKey;
  final bool unique;
  final _Expr? defaultExpression;
  String? referencesTable;
  final String? referencesColumn;
  final String onDelete;
  final String onUpdate;
  final String? collation;
  final List<_Expr> checkExpressions;

  _ColumnDef copy() => _ColumnDef(
    name,
    typeName: typeName,
    notNull: notNull,
    primaryKey: primaryKey,
    unique: unique,
    defaultExpression: defaultExpression,
    referencesTable: referencesTable,
    referencesColumn: referencesColumn,
    onDelete: onDelete,
    onUpdate: onUpdate,
    collation: collation,
    checkExpressions: List<_Expr>.from(checkExpressions),
  );
}

class _ForeignKey {
  _ForeignKey(
    this.columns,
    this.table,
    this.referencedColumns, {
    this.onDelete = 'NO ACTION',
    this.onUpdate = 'NO ACTION',
  });
  final List<String> columns;
  String table;
  final List<String> referencedColumns;
  final String onDelete;
  final String onUpdate;

  _ForeignKey copy() => _ForeignKey(
    List<String>.from(columns),
    table,
    List<String>.from(referencedColumns),
    onDelete: onDelete,
    onUpdate: onUpdate,
  );
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

  String name;
  final _Table table;
  final List<String> columns;
  int? rootPage;
  final bool unique;
  final List<bool> descending;
  final _Expr? where;

  _Index copy(_Table table) => _Index(
    name,
    table,
    List<String>.from(columns),
    rootPage: rootPage,
    unique: unique,
    descending: List<bool>.from(descending),
    where: where,
  );
}

sealed class _Statement {}

class _Drop extends _Statement {
  _Drop(this.type, this.name, this.ifExists);
  final String type;
  final String name;
  final bool ifExists;
}

class _CreateTable extends _Statement {
  _CreateTable(
    this.name,
    this.columns,
    this.ifNotExists, {
    this.primaryKeyColumns = const [],
    this.checkExpressions = const [],
    this.uniqueConstraints = const [],
    this.foreignKeyConstraints = const [],
  });

  final String name;
  final List<_ColumnDef> columns;
  final bool ifNotExists;
  final List<String> primaryKeyColumns;
  final List<_Expr> checkExpressions;
  final List<List<String>> uniqueConstraints;
  final List<_ForeignKey> foreignKeyConstraints;
}

class _CreateView extends _Statement {
  _CreateView(this.name, this.query, this.ifNotExists, this.columns);
  final String name;
  final _Select query;
  final bool ifNotExists;
  final List<String>? columns;
  String? schemaSql;
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

class _RenameTable extends _Statement {
  _RenameTable(this.table, this.newName);

  final String table;
  final String newName;
}

class _RenameColumn extends _Statement {
  _RenameColumn(this.table, this.oldName, this.newName);

  final String table;
  final String oldName;
  final String newName;
}

class _DropColumn extends _Statement {
  _DropColumn(this.table, this.name);

  final String table;
  final String name;
}

class _Begin extends _Statement {}

class _Commit extends _Statement {}

class _Rollback extends _Statement {}

class _Pragma extends _Statement {
  _Pragma(this.name, this.value, {this.argument});

  String name;
  final _Expr? value;
  final _Expr? argument;
}

class _Insert extends _Statement {
  _Insert(
    this.table,
    this.columns,
    this.rows, {
    this.conflict = 'abort',
    this.defaultValues = false,
    this.select,
    this.upsertTarget,
    this.upsertNothing = false,
    this.upsertAssignments,
    this.upsertWhere,
  });
  final String table;
  final List<String>? columns;
  final List<List<_Expr>> rows;
  final String conflict;
  final bool defaultValues;
  final _Select? select;
  final List<String>? upsertTarget;
  final bool upsertNothing;
  final Map<String, _Expr>? upsertAssignments;
  final _Expr? upsertWhere;
}

class _Select extends _Statement {
  _Select(
    this.items,
    this.table,
    this.alias,
    this.joins,
    this.where,
    this.groupBy,
    this.having,
    this.orderBy,
    this.limit,
    this.offset,
    this.distinct, {
    this.ctes = const {},
    this.compoundTerms = const [],
    this.fromQuery,
  });
  final List<_SelectItem> items;
  final String? table;
  final String? alias;
  final List<_Join> joins;
  final _Expr? where;
  final List<_Expr> groupBy;
  final _Expr? having;
  final List<_Order> orderBy;
  final _Expr? limit;
  final _Expr? offset;
  final bool distinct;
  final Map<String, _Cte> ctes;
  final List<_CompoundTerm> compoundTerms;
  final _Select? fromQuery;
}

class _CompoundTerm {
  _CompoundTerm(this.operator, this.query, {this.all = false});

  final String operator;
  final _Select query;
  final bool all;
}

class _Cte {
  _Cte(this.query, this.columns);
  final _Select query;
  final List<String>? columns;
}

class _Join {
  _Join(
    this.table,
    this.alias, {
    this.query,
    required this.type,
    this.on,
    this.usingColumns = const [],
    this.natural = false,
  });

  final String? table;
  final String? alias;
  final _Select? query;
  final String type;
  final _Expr? on;
  final List<String> usingColumns;
  final bool natural;
}

class _Update extends _Statement {
  _Update(this.table, this.assignments, this.where, {this.conflict = 'abort'});
  final String table;
  final Map<String, _Expr> assignments;
  final _Expr? where;
  final String conflict;
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

class _Exists extends _Expr {
  _Exists(this.query);

  final _Select query;
}

class _In extends _Expr {
  _In(this.expression, this.values, this.negated, {this.query});

  final _Expr expression;
  final List<_Expr> values;
  final bool negated;
  final _Select? query;
}

class _Order {
  _Order(this.expression, this.descending, this.noCase);
  final _Expr expression;
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

class _Unary extends _Expr {
  _Unary(this.operator, this.expression);
  final String operator;
  final _Expr expression;
}

class _Cast extends _Expr {
  _Cast(this.expression, this.type);
  final _Expr expression;
  final String type;
}

class _Between extends _Expr {
  _Between(this.expression, this.lower, this.upper, this.negated);
  final _Expr expression;
  final _Expr lower;
  final _Expr upper;
  final bool negated;
}

class _PatternMatch extends _Expr {
  _PatternMatch(
    this.expression,
    this.pattern,
    this.operator,
    this.negated,
    this.escape,
  );
  final _Expr expression;
  final _Expr pattern;
  final String operator;
  final bool negated;
  final _Expr? escape;
}

enum _TokenType { word, number, string, parameter, symbol, eof }

List<String> _splitSqlStatements(String sql) {
  final result = <String>[];
  var statementStart = 0;
  var index = 0;
  while (index < sql.length) {
    if (sql.startsWith('--', index)) {
      final newline = sql.indexOf('\n', index + 2);
      index = newline < 0 ? sql.length : newline + 1;
      continue;
    }
    if (sql.startsWith('/*', index)) {
      final close = sql.indexOf('*/', index + 2);
      if (close < 0) throw PureSqlException('unterminated block comment');
      index = close + 2;
      continue;
    }
    final opening = sql[index];
    if (opening == "'" || opening == '"' || opening == '`' || opening == '[') {
      final closing = opening == '[' ? ']' : opening;
      index++;
      var closed = false;
      while (index < sql.length) {
        if (sql[index] != closing) {
          index++;
        } else if (index + 1 < sql.length && sql[index + 1] == closing) {
          index += 2;
        } else {
          index++;
          closed = true;
          break;
        }
      }
      if (!closed) {
        throw PureSqlException(
          opening == "'"
              ? 'unterminated string'
              : 'unterminated quoted identifier',
        );
      }
      continue;
    }
    if (opening == ';') {
      final candidate = sql.substring(statementStart, index).trim();
      if (candidate.isNotEmpty &&
          _Tokenizer(candidate).tokenize().first.type != _TokenType.eof) {
        result.add(candidate);
      }
      statementStart = index + 1;
    }
    index++;
  }
  final candidate = sql.substring(statementStart).trim();
  if (candidate.isNotEmpty &&
      _Tokenizer(candidate).tokenize().first.type != _TokenType.eof) {
    result.add(candidate);
  }
  return result;
}

class _Token {
  _Token.positioned(
    this.type,
    this.text, {
    this.value,
    this.start = -1,
    this.end = -1,
  }) : quoted = false;
  _Token.quoted(this.type, this.text, {this.start = -1, this.end = -1})
    : value = null,
      quoted = true;
  final _TokenType type;
  final String text;
  final Object? value;
  final bool quoted;
  final int start;
  final int end;
}

class _Tokenizer {
  _Tokenizer(this.sql);
  final String sql;
  var _offset = 0;

  List<_Token> tokenize() {
    final result = <_Token>[];
    while (_offset < sql.length) {
      final start = _offset;
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
      if (sql.startsWith('/*', _offset)) {
        final end = sql.indexOf('*/', _offset + 2);
        if (end < 0) throw PureSqlException('unterminated block comment');
        _offset = end + 2;
        continue;
      }
      final char = sql[_offset];
      if (char == "'") {
        final value = _string();
        result.add(
          _Token.positioned(
            _TokenType.string,
            char,
            value: value,
            start: start,
            end: _offset,
          ),
        );
      } else if (char == '"' || char == '`' || char == '[') {
        final value = _quotedIdentifier(char);
        result.add(
          _Token.quoted(_TokenType.word, value, start: start, end: _offset),
        );
      } else if (_isLetter(_codePointAt(_offset)) || char == '_') {
        _offset += _codePointWidthAt(_offset);
        while (_offset < sql.length &&
            (_isLetterOrDigit(_codePointAt(_offset)) || sql[_offset] == '_')) {
          _offset += _codePointWidthAt(_offset);
        }
        result.add(
          _Token.positioned(
            _TokenType.word,
            sql.substring(start, _offset),
            start: start,
            end: _offset,
          ),
        );
      } else if (_isDigit(code)) {
        _offset++;
        while (_offset < sql.length &&
            (_isDigit(sql.codeUnitAt(_offset)) || sql[_offset] == '.')) {
          _offset++;
        }
        result.add(
          _Token.positioned(
            _TokenType.number,
            sql.substring(start, _offset),
            start: start,
            end: _offset,
          ),
        );
      } else if (char == '?' || char == ':' || char == '@' || char == r'$') {
        _offset++;
        while (_offset < sql.length &&
            (_isLetterOrDigit(_codePointAt(_offset)) || sql[_offset] == '_')) {
          _offset += _codePointWidthAt(_offset);
        }
        if (char == '?' || _offset > start + 1) {
          result.add(
            _Token.positioned(
              _TokenType.parameter,
              sql.substring(start, _offset),
              start: start,
              end: _offset,
            ),
          );
        } else {
          throw PureSqlException('parameter name is missing');
        }
      } else {
        final two = _offset + 1 < sql.length
            ? sql.substring(_offset, _offset + 2)
            : '';
        if (const ['<=', '>=', '<>', '!=', '||', '<<', '>>'].contains(two)) {
          result.add(
            _Token.positioned(
              _TokenType.symbol,
              two,
              start: start,
              end: start + 2,
            ),
          );
          _offset += 2;
        } else if ('(),=*<>+-/%|&~^;.'.contains(char)) {
          result.add(
            _Token.positioned(
              _TokenType.symbol,
              char,
              start: start,
              end: start + 1,
            ),
          );
          _offset++;
        } else {
          throw PureSqlException('unexpected character: $char');
        }
      }
    }
    result.add(
      _Token.positioned(_TokenType.eof, '', start: sql.length, end: sql.length),
    );
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

  String _quotedIdentifier(String opening) {
    final closing = opening == '[' ? ']' : opening;
    _offset++;
    final buffer = StringBuffer();
    while (_offset < sql.length) {
      final char = sql[_offset++];
      if (char != closing) {
        buffer.write(char);
      } else if (opening != '[' &&
          _offset < sql.length &&
          sql[_offset] == closing) {
        buffer.write(closing);
        _offset++;
      } else {
        return buffer.toString();
      }
    }
    throw PureSqlException('unterminated quoted identifier');
  }

  bool _isDigit(int code) => code >= 48 && code <= 57;
  static final _identifierStart = RegExp(r'^[\p{L}\p{Nl}]$', unicode: true);
  static final _identifierPart = RegExp(
    r'^[\p{L}\p{Nl}\p{M}\p{Nd}]$',
    unicode: true,
  );

  int _codePointAt(int offset) {
    final first = sql.codeUnitAt(offset);
    if (first < 0xd800 || first > 0xdbff || offset + 1 == sql.length) {
      return first;
    }
    final second = sql.codeUnitAt(offset + 1);
    if (second < 0xdc00 || second > 0xdfff) return first;
    return 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00;
  }

  int _codePointWidthAt(int offset) => _codePointAt(offset) > 0xffff ? 2 : 1;

  bool _isLetter(int code) =>
      _identifierStart.hasMatch(String.fromCharCode(code));
  bool _isLetterOrDigit(int code) =>
      _identifierPart.hasMatch(String.fromCharCode(code)) || _isDigit(code);
}

class _Parser {
  _Parser(String sql) : _tokens = _Tokenizer(sql).tokenize();
  final List<_Token> _tokens;
  Map<String, _Cte> _cteContext = const {};
  final Map<String, int> _namedParameters = {};
  var _index = 0;
  var _nextParameter = 0;
  var _hasPositionalParameters = false;

  Map<String, int> get namedParameters => _namedParameters;
  int get parameterCount => _nextParameter;
  bool get hasPositionalParameters => _hasPositionalParameters;

  _Statement parse() {
    final statement = switch (_word) {
      'CREATE' => _create(),
      'DROP' => _drop(),
      'ALTER' => _alterTable(),
      'BEGIN' => _begin(),
      'COMMIT' => _commit(),
      'END' => _commit(),
      'ROLLBACK' => _rollback(),
      'PRAGMA' => _pragma(),
      'INSERT' => _insert(),
      'WITH' => _withSelect(),
      'SELECT' => _select(),
      'UPDATE' => _update(),
      'DELETE' => _delete(),
      _ => throw PureSqlException('unsupported statement: ${_peek.text}'),
    };
    if (_accept(';')) {}
    _expectType(_TokenType.eof);
    return statement;
  }

  _Select _withSelect() {
    _expectWord('WITH');
    if (_acceptWord('RECURSIVE')) {
      throw PureSqlException('recursive CTEs are not supported');
    }
    final ctes = <String, _Cte>{};
    do {
      final name = _identifier();
      List<String>? columns;
      if (_accept('(')) {
        columns = [_identifier()];
        while (_accept(',')) {
          columns.add(_identifier());
        }
        _expect(')');
      }
      _expectWord('AS');
      _expect('(');
      _cteContext = Map.unmodifiable(ctes);
      final query = _select();
      _expect(')');
      ctes[_key(name)] = _Cte(query, columns);
    } while (_accept(','));
    _cteContext = Map.unmodifiable(ctes);
    final query = _select();
    _cteContext = const {};
    return query;
  }

  _Statement _create() {
    _expectWord('CREATE');
    final unique = _acceptWord('UNIQUE');
    if (_acceptWord('INDEX')) return _createIndex(unique);
    if (unique) throw PureSqlException('UNIQUE is valid only with INDEX');
    if (_acceptWord('VIEW')) return _createView();
    _expectWord('TABLE');
    final ifNotExists =
        _acceptWord('IF') && _acceptWord('NOT') && _acceptWord('EXISTS');
    final name = _identifier();
    _expect('(');
    final columns = <_ColumnDef>[];
    final primaryKeyColumns = <String>[];
    final checks = <_Expr>[];
    final uniqueConstraints = <List<String>>[];
    final foreignKeyConstraints = <_ForeignKey>[];
    do {
      if (_acceptWord('PRIMARY')) {
        _expectWord('KEY');
        _expect('(');
        primaryKeyColumns.add(_identifier());
        while (_accept(',')) {
          primaryKeyColumns.add(_identifier());
        }
        _expect(')');
      } else if (_acceptWord('CHECK')) {
        checks.add(_checkExpression());
      } else if (_acceptWord('UNIQUE')) {
        _expect('(');
        final uniqueColumns = <String>[_identifier()];
        while (_accept(',')) {
          uniqueColumns.add(_identifier());
        }
        _expect(')');
        uniqueConstraints.add(uniqueColumns);
      } else if (_acceptWord('FOREIGN')) {
        _expectWord('KEY');
        _expect('(');
        final childColumns = <String>[_identifier()];
        while (_accept(',')) {
          childColumns.add(_identifier());
        }
        _expect(')');
        _expectWord('REFERENCES');
        final parentTable = _identifier();
        final parentColumns = <String>[];
        if (_accept('(')) {
          parentColumns.add(_identifier());
          while (_accept(',')) {
            parentColumns.add(_identifier());
          }
          _expect(')');
        }
        var onDelete = 'NO ACTION';
        var onUpdate = 'NO ACTION';
        while (_acceptWord('ON')) {
          if (_acceptWord('DELETE')) {
            onDelete = _foreignKeyAction();
          } else if (_acceptWord('UPDATE')) {
            onUpdate = _foreignKeyAction();
          } else {
            throw PureSqlException('expected DELETE or UPDATE after ON');
          }
        }
        foreignKeyConstraints.add(
          _ForeignKey(
            childColumns,
            parentTable,
            parentColumns,
            onDelete: onDelete,
            onUpdate: onUpdate,
          ),
        );
      } else {
        final columnName = _identifier();
        final typeName = _declaredType();
        var notNull = false;
        var primaryKey = false;
        var unique = false;
        _Expr? defaultExpression;
        String? referencesTable;
        String? referencesColumn;
        var onDelete = 'NO ACTION';
        var onUpdate = 'NO ACTION';
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
          } else if (_acceptWord('ON')) {
            if (_acceptWord('DELETE')) {
              onDelete = _foreignKeyAction();
            } else if (_acceptWord('UPDATE')) {
              onUpdate = _foreignKeyAction();
            } else {
              throw PureSqlException('expected DELETE or UPDATE after ON');
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
            onDelete: onDelete,
            onUpdate: onUpdate,
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
      uniqueConstraints: uniqueConstraints,
      foreignKeyConstraints: foreignKeyConstraints,
    );
  }

  _Statement _drop() {
    _expectWord('DROP');
    final type = _acceptWord('TABLE')
        ? 'table'
        : _acceptWord('INDEX')
        ? 'index'
        : _acceptWord('VIEW')
        ? 'view'
        : throw PureSqlException('DROP supports TABLE, INDEX, or VIEW');
    final ifExists = _acceptWord('IF') && _acceptWord('EXISTS');
    return _Drop(type, _identifier(), ifExists);
  }

  _Statement _createView() {
    final ifNotExists =
        _acceptWord('IF') && _acceptWord('NOT') && _acceptWord('EXISTS');
    final name = _identifier();
    List<String>? columns;
    if (_accept('(')) {
      columns = [_identifier()];
      while (_accept(',')) {
        columns.add(_identifier());
      }
      _expect(')');
    }
    _expectWord('AS');
    final query = _select();
    return _CreateView(name, query, ifNotExists, columns);
  }

  String? _declaredType() {
    const constraints = {
      'NOT',
      'PRIMARY',
      'UNIQUE',
      'DEFAULT',
      'REFERENCES',
      'COLLATE',
      'CHECK',
      'CONSTRAINT',
    };
    if (_peek.text == ',' || _peek.text == ')' || constraints.contains(_word)) {
      return null;
    }
    final parts = <String>[];
    var depth = 0;
    while (_peek.type != _TokenType.eof) {
      if (depth == 0 &&
          (_peek.text == ',' ||
              _peek.text == ')' ||
              constraints.contains(_word))) {
        break;
      }
      final part = _advance().text;
      if (part == '(') depth++;
      if (part == ')') depth--;
      parts.add(part);
    }
    final type = StringBuffer();
    var previous = '';
    for (final part in parts) {
      if (type.isNotEmpty && part != ')' && part != '(' && previous != '(') {
        type.write(' ');
      }
      type.write(part);
      previous = part;
    }
    return type.toString();
  }

  _Expr _checkExpression() {
    _expect('(');
    final expression = _expression();
    _expect(')');
    return expression;
  }

  String _foreignKeyAction() {
    if (_acceptWord('NO')) {
      _expectWord('ACTION');
      return 'NO ACTION';
    }
    if (_acceptWord('RESTRICT')) return 'RESTRICT';
    if (_acceptWord('CASCADE')) return 'CASCADE';
    if (_acceptWord('SET')) {
      if (_acceptWord('NULL')) return 'SET NULL';
      if (_acceptWord('DEFAULT')) return 'SET DEFAULT';
    }
    throw PureSqlException('unsupported foreign key action: ${_peek.text}');
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
    _Expr? argument;
    if (_accept('(')) {
      argument = _expression();
      _expect(')');
    }
    final value = _accept('=') ? _expression() : null;
    if (argument != null && value != null) {
      throw PureSqlException('PRAGMA cannot take both an argument and a value');
    }
    return _Pragma(name, value, argument: argument);
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
    if (_acceptWord('RENAME')) {
      if (_acceptWord('COLUMN')) {
        final oldName = _identifier();
        _expectWord('TO');
        return _RenameColumn(table, oldName, _identifier());
      }
      _expectWord('TO');
      return _RenameTable(table, _identifier());
    }
    if (_acceptWord('DROP')) {
      _expectWord('COLUMN');
      return _DropColumn(table, _identifier());
    }
    _expectWord('ADD');
    _acceptWord('COLUMN');
    final name = _identifier();
    final typeName = _declaredType();
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
      } else if (_acceptWord('FAIL')) {
        conflict = 'fail';
      } else if (_acceptWord('ROLLBACK')) {
        conflict = 'rollback';
      } else if (_acceptWord('ABORT')) {
        conflict = 'abort';
      } else {
        throw PureSqlException('unsupported INSERT conflict action');
      }
    }
    _expectWord('INTO');
    final table = _identifier();
    List<String>? columns;
    if (_accept('(')) {
      columns = [_identifier()];
      while (_accept(',')) {
        columns.add(_identifier());
      }
      _expect(')');
    }
    if (_acceptWord('DEFAULT')) {
      _expectWord('VALUES');
      return _parseUpsert(
        _Insert(
          table,
          columns,
          const [[]],
          conflict: conflict,
          defaultValues: true,
        ),
      );
    }
    if (_word == 'SELECT') {
      return _parseUpsert(
        _Insert(
          table,
          columns,
          const [],
          conflict: conflict,
          select: _select(),
        ),
      );
    }
    _expectWord('VALUES');
    final rows = <List<_Expr>>[];
    do {
      _expect('(');
      final values = <_Expr>[];
      if (!_accept(')')) {
        values.add(_expression());
        while (_accept(',')) {
          values.add(_expression());
        }
        _expect(')');
      }
      rows.add(values);
    } while (_accept(','));
    return _parseUpsert(_Insert(table, columns, rows, conflict: conflict));
  }

  _Insert _parseUpsert(_Insert insert) {
    if (!_acceptWord('ON')) return insert;
    _expectWord('CONFLICT');
    List<String>? target;
    if (_accept('(')) {
      target = [_identifier()];
      while (_accept(',')) {
        target.add(_identifier());
      }
      _expect(')');
    }
    _expectWord('DO');
    if (_acceptWord('NOTHING')) {
      return _Insert(
        insert.table,
        insert.columns,
        insert.rows,
        conflict: insert.conflict,
        defaultValues: insert.defaultValues,
        select: insert.select,
        upsertTarget: target,
        upsertNothing: true,
      );
    }
    _expectWord('UPDATE');
    _expectWord('SET');
    final assignments = <String, _Expr>{};
    do {
      final name = _identifier();
      _expect('=');
      assignments[name] = _expression();
    } while (_accept(','));
    final where = _acceptWord('WHERE') ? _expression() : null;
    return _Insert(
      insert.table,
      insert.columns,
      insert.rows,
      conflict: insert.conflict,
      defaultValues: insert.defaultValues,
      select: insert.select,
      upsertTarget: target,
      upsertAssignments: assignments,
      upsertWhere: where,
    );
  }

  _Select _select() {
    final first = _selectCore();
    final terms = <_CompoundTerm>[];
    while (const ['UNION', 'INTERSECT', 'EXCEPT'].contains(_word)) {
      final operator = _advance().text.toUpperCase();
      final all = _acceptWord('ALL');
      if (operator != 'UNION' && all) {
        throw PureSqlException('$operator ALL is not supported');
      }
      if (operator == 'UNION' && !all) _acceptWord('DISTINCT');
      terms.add(_CompoundTerm(operator, _selectCore(), all: all));
    }
    final order = <_Order>[];
    if (_acceptWord('ORDER')) {
      _expectWord('BY');
      do {
        final expression = _expression();
        var noCase = false;
        if (_acceptWord('COLLATE')) {
          _expectWord('NOCASE');
          noCase = true;
        }
        final descending = _acceptWord('DESC');
        if (!descending) _acceptWord('ASC');
        order.add(_Order(expression, descending, noCase));
      } while (_accept(','));
    }
    _Expr? limit;
    _Expr? offset;
    if (_acceptWord('LIMIT')) {
      final firstLimit = _expression();
      if (_accept(',')) {
        offset = firstLimit;
        limit = _expression();
      } else {
        limit = firstLimit;
        offset = _acceptWord('OFFSET') ? _expression() : null;
      }
    }
    return _Select(
      first.items,
      first.table,
      first.alias,
      first.joins,
      first.where,
      first.groupBy,
      first.having,
      order,
      limit,
      offset,
      first.distinct,
      ctes: first.ctes,
      fromQuery: first.fromQuery,
      compoundTerms: terms,
    );
  }

  _Select _selectCore() {
    _expectWord('SELECT');
    final distinct = _acceptWord('DISTINCT');
    if (!distinct) _acceptWord('ALL');
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
    String? table;
    _Select? fromQuery;
    String? alias;
    if (_acceptWord('FROM')) {
      if (_accept('(')) {
        if (_word != 'SELECT' && _word != 'WITH') {
          throw PureSqlException('FROM subquery must be a SELECT');
        }
        fromQuery = _word == 'WITH' ? _withSelect() : _select();
        _expect(')');
        alias = _acceptWord('AS')
            ? _identifier()
            : _acceptAlias(_peek.text)
            ? _identifier()
            : null;
        if (alias == null) {
          throw PureSqlException('FROM subquery requires an alias');
        }
      } else {
        table = _identifier();
        alias = _acceptWord('AS')
            ? _identifier()
            : _acceptAlias(_peek.text)
            ? _identifier()
            : null;
      }
    }
    final joins = <_Join>[];
    while (true) {
      final natural = _acceptWord('NATURAL');
      var type = 'INNER';
      var joinModifier = natural;
      if (_acceptWord('LEFT')) {
        type = 'LEFT';
        joinModifier = true;
        _acceptWord('OUTER');
      } else if (_acceptWord('RIGHT')) {
        type = 'RIGHT';
        joinModifier = true;
        _acceptWord('OUTER');
      } else if (_acceptWord('FULL')) {
        type = 'FULL';
        joinModifier = true;
        _acceptWord('OUTER');
      } else if (_acceptWord('INNER')) {
        joinModifier = true;
      } else if (_acceptWord('CROSS')) {
        type = 'CROSS';
        joinModifier = true;
      }
      if (!_acceptWord('JOIN')) {
        if (joinModifier) throw PureSqlException('expected JOIN');
        break;
      }
      if (table == null && fromQuery == null) {
        throw PureSqlException('JOIN requires a FROM clause');
      }
      String? joinedTable;
      _Select? joinedQuery;
      String? joinedAlias;
      if (_accept('(')) {
        if (_word != 'SELECT' && _word != 'WITH') {
          throw PureSqlException('JOIN subquery must be a SELECT');
        }
        joinedQuery = _word == 'WITH' ? _withSelect() : _select();
        _expect(')');
        joinedAlias = _acceptWord('AS')
            ? _identifier()
            : _acceptAlias(_peek.text)
            ? _identifier()
            : null;
        if (joinedAlias == null) {
          throw PureSqlException('JOIN subquery requires an alias');
        }
      } else {
        joinedTable = _identifier();
        joinedAlias = _acceptWord('AS')
            ? _identifier()
            : _acceptAlias(_peek.text)
            ? _identifier()
            : null;
      }
      _Expr? on;
      final usingColumns = <String>[];
      if (_acceptWord('ON')) {
        on = _expression();
      } else if (_acceptWord('USING')) {
        _expect('(');
        usingColumns.add(_identifier());
        while (_accept(',')) {
          usingColumns.add(_identifier());
        }
        _expect(')');
      } else if (type != 'CROSS' && !natural) {
        throw PureSqlException('JOIN requires ON or USING');
      }
      if (natural && (on != null || usingColumns.isNotEmpty)) {
        throw PureSqlException('NATURAL JOIN cannot specify ON or USING');
      }
      joins.add(
        _Join(
          joinedTable,
          joinedAlias,
          query: joinedQuery,
          type: type,
          on: on,
          usingColumns: usingColumns,
          natural: natural,
        ),
      );
    }
    final where = _acceptWord('WHERE') ? _expression() : null;
    final groupBy = <_Expr>[];
    if (_acceptWord('GROUP')) {
      _expectWord('BY');
      groupBy.add(_expression());
      while (_accept(',')) {
        groupBy.add(_expression());
      }
    }
    final having = _acceptWord('HAVING') ? _expression() : null;
    return _Select(
      items,
      table,
      alias,
      joins,
      where,
      groupBy,
      having,
      const [],
      null,
      null,
      distinct,
      ctes: Map.of(_cteContext),
      fromQuery: fromQuery,
    );
  }

  bool _acceptAlias(String word) =>
      _peek.type == _TokenType.word &&
      (_peek.quoted ||
          !const [
            'WHERE',
            'ORDER',
            'LIMIT',
            'GROUP',
            'JOIN',
            'LEFT',
            'RIGHT',
            'FULL',
            'INNER',
            'CROSS',
            'NATURAL',
            'USING',
            'ON',
          ].contains(word.toUpperCase()));

  _Statement _update() {
    _expectWord('UPDATE');
    var conflict = 'abort';
    if (_acceptWord('OR')) {
      if (_acceptWord('ABORT')) {
        conflict = 'abort';
      } else if (_acceptWord('IGNORE')) {
        conflict = 'ignore';
      } else if (_acceptWord('REPLACE')) {
        conflict = 'replace';
      } else if (_acceptWord('FAIL')) {
        conflict = 'fail';
      } else if (_acceptWord('ROLLBACK')) {
        conflict = 'rollback';
      } else {
        throw PureSqlException('unsupported UPDATE conflict action');
      }
    }
    final table = _identifier();
    _expectWord('SET');
    final assignments = <String, _Expr>{};
    do {
      final name = _identifier();
      _expect('=');
      assignments[name] = _expression();
    } while (_accept(','));
    final where = _acceptWord('WHERE') ? _expression() : null;
    return _Update(table, assignments, where, conflict: conflict);
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
    while (_acceptWord('OR')) {
      result = _Binary(result, 'OR', _and());
    }
    return result;
  }

  _Expr _and() {
    var result = _not();
    while (_acceptWord('AND')) {
      result = _Binary(result, 'AND', _not());
    }
    return result;
  }

  _Expr _not() => _acceptWord('NOT') ? _Unary('NOT', _not()) : _comparison();

  _Expr _comparison() {
    var result = _bitwise();
    if (_peek.type == _TokenType.symbol &&
        const ['=', '!=', '<>', '<', '<=', '>', '>='].contains(_peek.text)) {
      final operator = _advance().text;
      result = _Binary(result, operator, _bitwise());
    } else if (_acceptWord('IS')) {
      final operator = _acceptWord('NOT') ? 'IS NOT' : 'IS';
      if (_acceptWord('DISTINCT')) {
        _expectWord('FROM');
        result = _Binary(
          result,
          operator == 'IS' ? 'IS NOT' : 'IS',
          _bitwise(),
        );
      } else {
        result = _Binary(result, operator, _bitwise());
      }
    } else if (_acceptWord('ISNULL')) {
      result = _Binary(result, 'IS', _Literal(null));
    } else if (_acceptWord('NOTNULL')) {
      result = _Binary(result, 'IS NOT', _Literal(null));
    } else if (_acceptWord('BETWEEN')) {
      final lower = _bitwise();
      _expectWord('AND');
      result = _Between(result, lower, _bitwise(), false);
    } else if (_acceptWord('NOT')) {
      if (_acceptWord('NULL')) {
        result = _Binary(result, 'IS NOT', _Literal(null));
      } else if (_acceptWord('IN')) {
        result = _inExpression(result, true);
      } else if (_acceptWord('BETWEEN')) {
        final lower = _bitwise();
        _expectWord('AND');
        result = _Between(result, lower, _bitwise(), true);
      } else if (_acceptWord('LIKE')) {
        result = _patternMatch(result, 'LIKE', true);
      } else if (_acceptWord('GLOB')) {
        result = _patternMatch(result, 'GLOB', true);
      } else if (_acceptWord('REGEXP')) {
        result = _patternMatch(result, 'REGEXP', true);
      } else {
        throw PureSqlException('expected IN, BETWEEN, LIKE, GLOB, or REGEXP');
      }
    } else if (_acceptWord('IN')) {
      result = _inExpression(result, false);
    } else if (_acceptWord('LIKE')) {
      result = _patternMatch(result, 'LIKE', false);
    } else if (_acceptWord('GLOB')) {
      result = _patternMatch(result, 'GLOB', false);
    } else if (_acceptWord('REGEXP')) {
      result = _patternMatch(result, 'REGEXP', false);
    }
    return result;
  }

  _Expr _patternMatch(_Expr expression, String operator, bool negated) {
    final pattern = _bitwise();
    final escape = operator == 'LIKE' && _acceptWord('ESCAPE')
        ? _bitwise()
        : null;
    return _PatternMatch(expression, pattern, operator, negated, escape);
  }

  _Expr _inExpression(_Expr expression, bool negated) {
    _expect('(');
    if (_word == 'SELECT' || _word == 'WITH') {
      final query = _word == 'WITH' ? _withSelect() : _select();
      _expect(')');
      return _In(expression, const [], negated, query: query);
    }
    final values = <_Expr>[];
    if (!_accept(')')) {
      values.add(_expression());
      while (_accept(',')) {
        values.add(_expression());
      }
      _expect(')');
    }
    return _In(expression, values, negated);
  }

  _Expr _bitwise() {
    var result = _additive();
    while (_peek.type == _TokenType.symbol &&
        const ['&', '|', '^', '<<', '>>'].contains(_peek.text)) {
      result = _Binary(result, _advance().text, _additive());
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
    var result = _concatenation();
    while (_peek.type == _TokenType.symbol &&
        const ['*', '/', '%'].contains(_peek.text)) {
      result = _Binary(result, _advance().text, _concatenation());
    }
    return result;
  }

  _Expr _concatenation() {
    var result = _unary();
    while (_accept('||')) {
      result = _Binary(result, '||', _unary());
    }
    return result;
  }

  _Expr _unary() {
    if (_peek.type == _TokenType.symbol &&
        const ['+', '-', '~'].contains(_peek.text)) {
      return _Unary(_advance().text, _unary());
    }
    return _primary();
  }

  _Expr _primary() {
    if (_accept('(')) {
      if (_word == 'SELECT' || _word == 'WITH') {
        final query = _word == 'WITH' ? _withSelect() : _select();
        _expect(')');
        return _ScalarSubquery(query);
      }
      final result = _expression();
      _expect(')');
      return result;
    }
    final token = _advance();
    if (token.type == _TokenType.parameter) {
      if (token.text.startsWith('?')) _hasPositionalParameters = true;
      if (token.text.startsWith('?') &&
          token.text.length > 1 &&
          int.parse(token.text.substring(1)) == 0) {
        throw PureSqlException('parameter numbers start at 1');
      }
      final index = switch (token.text[0]) {
        '?' when token.text.length > 1 =>
          int.parse(token.text.substring(1)) - 1,
        ':' || '@' || r'$' => _namedParameters.putIfAbsent(
          token.text,
          () => _nextParameter++,
        ),
        _ => _nextParameter++,
      };
      if (token.text.startsWith('?')) {
        _nextParameter = math.max(_nextParameter, index + 1);
      }
      return _Param(index);
    }
    if (token.type == _TokenType.string) return _Literal(token.value);
    if (token.type == _TokenType.number) {
      return _Literal(
        token.text.contains('.')
            ? double.parse(token.text)
            : int.parse(token.text),
      );
    }
    if (token.type == _TokenType.word) {
      final word = token.quoted ? '' : token.text.toUpperCase();
      if (word == 'EXISTS') {
        _expect('(');
        if (_word != 'SELECT' && _word != 'WITH') {
          throw PureSqlException('EXISTS requires a SELECT subquery');
        }
        final query = _word == 'WITH' ? _withSelect() : _select();
        _expect(')');
        return _Exists(query);
      }
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
      if (word == 'CAST') {
        _expect('(');
        final expression = _expression();
        _expectWord('AS');
        final type = StringBuffer();
        var depth = 0;
        while (_peek.type != _TokenType.eof &&
            !(_peek.text == ')' && depth == 0)) {
          final part = _advance().text;
          if (part == '(') depth++;
          if (part == ')') depth--;
          type.write(part);
          if (depth == 0 && _peek.type == _TokenType.word) type.write(' ');
        }
        if (type.isEmpty) throw PureSqlException('CAST requires a type name');
        _expect(')');
        return _Cast(expression, type.toString().trim());
      }
      if (_accept('(')) {
        final distinct = _acceptWord('DISTINCT');
        final arguments = <_Expr>[];
        if (!_accept(')')) {
          if (_accept('*')) {
            arguments.add(_Column('*'));
          } else {
            arguments.add(_expression());
            while (_accept(',')) {
              arguments.add(_expression());
            }
          }
          _expect(')');
        }
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

  String get _word => _peek.type == _TokenType.word && !_peek.quoted
      ? _peek.text.toUpperCase()
      : '';
  _Token get _peek => _tokens[_index];
  _Token _advance() => _tokens[_index++];

  String _identifier() {
    final token = _advance();
    if (token.type != _TokenType.word) {
      throw PureSqlException('expected identifier');
    }
    return token.text;
  }

  void _expect(String text) {
    if (!_accept(text)) {
      throw PureSqlException('expected "$text", got "${_peek.text}"');
    }
  }

  void _expectWord(String word) {
    if (!_acceptWord(word)) {
      throw PureSqlException('expected $word, got ${_peek.text}');
    }
  }

  void _expectType(_TokenType type) {
    if (_peek.type != type) {
      throw PureSqlException('unexpected token: ${_peek.text}');
    }
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
