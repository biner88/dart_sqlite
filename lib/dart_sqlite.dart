/// A deliberately small, dependency-free, SQLite-compatible subset.
///
/// It supports an in-memory SQL engine and a growing, partially compatible
/// SQLite 3 file format.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'src/sqlite_format.dart';
import 'src/table_btree.dart';
import 'src/index_btree.dart';

export 'src/sqlite_format.dart';
export 'src/table_btree.dart';
export 'src/index_btree.dart';

/// A SQL result row, keyed by the selected column names.
typedef SqlRow = Map<String, Object?>;

/// A row exposed by a registered virtual-table module.
class SqlVirtualTableRow {
  const SqlVirtualTableRow(this.rowId, this.values);

  final int rowId;
  final SqlRow values;
}

/// A pure-Dart virtual-table instance supplied by a registered module.
abstract class SqlVirtualTable {
  /// Visible column names in SQLite result order.
  List<String> get columns;

  /// Reads the current rows. Row IDs must be unique signed 64-bit integers.
  Iterable<SqlVirtualTableRow> scan();

  /// Atomically replaces all rows after SQL DML. Omit to make the table read-only.
  void replaceRows(List<SqlVirtualTableRow> rows) {
    throw SqliteException('virtual table is read-only');
  }

  /// Releases the connection to this table. [destroy] is used by DROP TABLE.
  void disconnect() {}
  void destroy() => disconnect();
}

/// Creates or reconnects a pure-Dart virtual table from CREATE arguments.
///
/// [arguments] contains the original SQL text for each module argument.
typedef SqlVirtualTableModule =
    SqlVirtualTable Function(
      PureDatabase database,
      String schema,
      String tableName,
      List<String> arguments, {
      required bool create,
    });
const _sqlFunctionsZoneKey = #pureSqliteFunctions;
const _sqlAggregateFunctionsZoneKey = #pureSqliteAggregateFunctions;
const _sqlWindowFunctionsZoneKey = #pureSqliteWindowFunctions;
const _sqlCaseSensitiveLikeZoneKey = #pureSqliteCaseSensitiveLike;
const _sqlChangesZoneKey = #pureSqliteChanges;
const _sqlTotalChangesZoneKey = #pureSqliteTotalChanges;
const _sqlLastInsertRowIdZoneKey = #pureSqliteLastInsertRowId;
const _sqlCurrentTimestampZoneKey = #pureSqliteCurrentTimestamp;
const _sqlLogZoneKey = #pureSqliteLog;
const _sqlTriggerExecutionDepthZoneKey = #pureSqliteTriggerExecutionDepth;
const _sqlTriggerTimingZoneKey = #pureSqliteTriggerTiming;
const _supportedPragmaNames = {
  'analysis_limit',
  'application_id',
  'automatic_index',
  'auto_vacuum',
  'busy_timeout',
  'cache_size',
  'case_sensitive_like',
  'mmap_size',
  'collation_list',
  'compile_options',
  'count_changes',
  'database_list',
  'default_cache_size',
  'defer_foreign_keys',
  'encoding',
  'foreign_key_check',
  'foreign_key_list',
  'foreign_keys',
  'full_column_names',
  'freelist_count',
  'function_list',
  'ignore_check_constraints',
  'index_info',
  'index_list',
  'index_xinfo',
  'integrity_check',
  'journal_mode',
  'journal_size_limit',
  'legacy_alter_table',
  'max_page_count',
  'module_list',
  'page_count',
  'page_size',
  'pragma_list',
  'query_only',
  'read_uncommitted',
  'quick_check',
  'recursive_triggers',
  'reverse_unordered_selects',
  'schema_version',
  'secure_delete',
  'short_column_names',
  'synchronous',
  'shrink_memory',
  'threads',
  'temp_store',
  'table_info',
  'table_list',
  'table_xinfo',
  'user_version',
  'wal_checkpoint',
  'wal_autocheckpoint',
};
const _pragmaTableFunctionColumns = {
  'auto_vacuum': ['auto_vacuum'],
  'collation_list': ['seq', 'name'],
  'compile_options': ['compile_options'],
  'database_list': ['seq', 'name', 'file'],
  'encoding': ['encoding'],
  'freelist_count': ['freelist_count'],
  'foreign_key_check': ['table', 'rowid', 'parent', 'fkid'],
  'foreign_key_list': [
    'id',
    'seq',
    'table',
    'from',
    'to',
    'on_update',
    'on_delete',
    'match',
  ],
  'function_list': ['name', 'builtin', 'type', 'enc', 'narg', 'flags'],
  'index_info': ['seqno', 'cid', 'name'],
  'index_list': ['seq', 'name', 'unique', 'origin', 'partial'],
  'index_xinfo': ['seqno', 'cid', 'name', 'desc', 'coll', 'key'],
  'integrity_check': ['integrity_check'],
  'module_list': ['name'],
  'page_count': ['page_count'],
  'pragma_list': ['name'],
  'quick_check': ['quick_check'],
  'table_info': ['cid', 'name', 'type', 'notnull', 'dflt_value', 'pk'],
  'table_list': ['schema', 'name', 'type', 'ncol', 'wr', 'strict'],
  'table_xinfo': [
    'cid',
    'name',
    'type',
    'notnull',
    'dflt_value',
    'pk',
    'hidden',
  ],
};
const _pragmaTableFunctionMaxArguments = {
  'foreign_key_check': 2,
  'foreign_key_list': 2,
  'integrity_check': 2,
  'index_info': 2,
  'index_list': 2,
  'index_xinfo': 2,
  'table_info': 2,
  'table_list': 1,
  'table_xinfo': 2,
  'quick_check': 2,
};
const _connectionPragmaNames = {
  'analysis_limit',
  'automatic_index',
  'busy_timeout',
  'case_sensitive_like',
  'collation_list',
  'compile_options',
  'count_changes',
  'database_list',
  'defer_foreign_keys',
  'foreign_keys',
  'full_column_names',
  'function_list',
  'ignore_check_constraints',
  'legacy_alter_table',
  'module_list',
  'pragma_list',
  'query_only',
  'read_uncommitted',
  'recursive_triggers',
  'reverse_unordered_selects',
  'shrink_memory',
  'short_column_names',
  'threads',
  'temp_store',
  'wal_autocheckpoint',
};
const _defaultTemporaryPragmaValues = <String, Object>{
  'application_id': 0,
  'cache_size': 2000,
  'default_cache_size': 2000,
  'journal_mode': 'delete',
  'journal_size_limit': 32768,
  'max_page_count': 1073741823,
  'page_size': 4096,
  'page_size_locked': false,
  'secure_delete': 0,
  'schema_version': 0,
  'synchronous': 0,
  'user_version': 0,
};
const _writablePragmaNames = {
  'analysis_limit',
  'application_id',
  'automatic_index',
  'busy_timeout',
  'cache_size',
  'case_sensitive_like',
  'count_changes',
  'default_cache_size',
  'defer_foreign_keys',
  'foreign_keys',
  'full_column_names',
  'ignore_check_constraints',
  'journal_mode',
  'journal_size_limit',
  'legacy_alter_table',
  'mmap_size',
  'max_page_count',
  'page_size',
  'query_only',
  'read_uncommitted',
  'recursive_triggers',
  'reverse_unordered_selects',
  'secure_delete',
  'short_column_names',
  'schema_version',
  'synchronous',
  'threads',
  'temp_store',
  'user_version',
  'wal_autocheckpoint',
};
const _sqliteCompatibilityVersion = '3.51.0';
const _sqliteCompatibilitySourceId =
    '2025-06-12 13:14:41 f0ca7bba1c5e232e5d279fad6338121ab55af0c8c68b84cdfb18ba5114dcaapl';

/// A scalar SQL function registered with [PureDatabase.registerFunction].
typedef SqlScalarFunction = Object? Function(List<Object?> arguments);

/// A SQLite log message raised by the built-in `sqlite_log()` function.
typedef SqlLogCallback = void Function(int code, String? message);

/// A SQL aggregate called once per group or window frame.
///
/// Each inner list contains the arguments for one input row. The outer list is
/// empty when the group has no input rows.
typedef SqlAggregateFunction = Object? Function(List<List<Object?>> rows);

/// A window-only SQL function over ordered partition and frame arguments.
///
/// [partitionRows] are ordered by the window's `ORDER BY` terms;
/// [currentRow] is the zero-based row index; [frameRows] contains the current
/// frame after any `EXCLUDE` rule is applied. The lists are immutable.
typedef SqlWindowFunction =
    Object? Function(
      List<List<Object?>> partitionRows,
      int currentRow,
      List<List<Object?>> frameRows,
    );

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

class _TriggerRaiseException implements Exception {
  _TriggerRaiseException(
    this.action,
    this.error,
    this.triggerDepth, {
    this.before = false,
  });

  final String action;
  final SqliteException error;
  final int triggerDepth;
  final bool before;
}

/// Compatibility name for [SqliteException].
typedef PureSqlException = SqliteException;

/// A synchronous SQLite-compatible database.
///
/// Use [memory] for a transient database or [open] for a persistent SQLite
/// file. The supported SQL syntax is a subset of SQLite; unsupported
/// statements throw [SqliteException].
class PureDatabase {
  PureDatabase._(
    Map<String, _Table> tables, [
    this._pager,
    this._onLog,
    Map<String, SqlVirtualTableModule> virtualTableModules = const {},
  ]) : _tables = tables,
       _virtualTableModules = {
         for (final entry in virtualTableModules.entries)
           _key(entry.key): entry.value,
       },
       _indexes = {},
       _temporaryTables = {},
       _temporaryIndexes = {},
       _views = {},
       _temporaryViews = {},
       _triggers = {},
       _temporaryTriggers = {},
       _viewStack = {};

  /// Creates an in-memory database that is discarded when closed.
  factory PureDatabase.memory({
    SqlLogCallback? onLog,
    Map<String, SqlVirtualTableModule> virtualTableModules = const {},
  }) =>
      PureDatabase._({}, null, onLog, virtualTableModules)
        .._journalMode = 'memory';

  /// Registers a pure-Dart module for subsequent `CREATE VIRTUAL TABLE` calls.
  ///
  /// Modules needed by existing persistent virtual tables must be supplied to
  /// [open] before the database schema is loaded.
  void registerVirtualTableModule(String name, SqlVirtualTableModule module) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'must be a simple SQL name');
    }
    _virtualTableModules[_key(name)] = module;
  }

  /// Registers or replaces a scalar SQL function.
  ///
  /// [argumentCount] is the exact arity, or -1 for a variadic function.
  /// Results must be null, a number, a string, a boolean, or a byte list.
  void registerFunction(
    String name,
    int argumentCount,
    SqlScalarFunction function,
  ) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'must be a simple SQL name');
    }
    if (argumentCount < -1) {
      throw ArgumentError.value(argumentCount, 'argumentCount');
    }
    _functions.putIfAbsent(_key(name), () => {})[argumentCount] = function;
  }

  /// Registers or replaces a SQL aggregate function.
  ///
  /// [argumentCount] is the exact arity, or -1 for a variadic function. The
  /// callback receives one argument list per input row and may also be used
  /// with `OVER` as a window aggregate.
  void registerAggregateFunction(
    String name,
    int argumentCount,
    SqlAggregateFunction function,
  ) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'must be a simple SQL name');
    }
    if (argumentCount < -1) {
      throw ArgumentError.value(argumentCount, 'argumentCount');
    }
    _aggregateFunctions.putIfAbsent(_key(name), () => {})[argumentCount] =
        function;
  }

  /// Registers or replaces a window-only SQL function.
  ///
  /// [argumentCount] is the exact arity, or -1 for a variadic function. The
  /// callback receives materialized arguments for its ordered partition, the
  /// zero-based current row, and the arguments in the current frame.
  void registerWindowFunction(
    String name,
    int argumentCount,
    SqlWindowFunction function,
  ) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'must be a simple SQL name');
    }
    if (argumentCount < -1) {
      throw ArgumentError.value(argumentCount, 'argumentCount');
    }
    _windowFunctionCallbacks.putIfAbsent(_key(name), () => {})[argumentCount] =
        function;
  }

  /// Removes a registered function overload, or every overload when omitted.
  void unregisterFunction(String name, {int? argumentCount}) {
    final overloads = _functions[_key(name)];
    if (overloads == null) return;
    if (argumentCount == null) {
      _functions.remove(_key(name));
    } else {
      overloads.remove(argumentCount);
      if (overloads.isEmpty) _functions.remove(_key(name));
    }
  }

  /// Removes a registered aggregate overload, or every overload when omitted.
  void unregisterAggregateFunction(String name, {int? argumentCount}) {
    final overloads = _aggregateFunctions[_key(name)];
    if (overloads == null) return;
    if (argumentCount == null) {
      _aggregateFunctions.remove(_key(name));
    } else {
      overloads.remove(argumentCount);
      if (overloads.isEmpty) _aggregateFunctions.remove(_key(name));
    }
  }

  /// Removes a registered window-function overload, or all overloads.
  void unregisterWindowFunction(String name, {int? argumentCount}) {
    final overloads = _windowFunctionCallbacks[_key(name)];
    if (overloads == null) return;
    if (argumentCount == null) {
      _windowFunctionCallbacks.remove(_key(name));
    } else {
      overloads.remove(argumentCount);
      if (overloads.isEmpty) _windowFunctionCallbacks.remove(_key(name));
    }
  }

  /// Opens or creates a persistent SQLite database at [path].
  ///
  /// [busyTimeout] controls how long lock acquisition waits before failing.
  factory PureDatabase.open(
    String path, {
    Duration busyTimeout = Duration.zero,
    SqlLogCallback? onLog,
    Map<String, SqlVirtualTableModule> virtualTableModules = const {},
  }) {
    final pager = SqlitePagerSync.open(path, busyTimeout: busyTimeout);
    final database = PureDatabase._({}, pager, onLog, virtualTableModules)
      .._journalMode = pager.isWalMode ? 'wal' : 'delete'
      .._busyTimeout = busyTimeout;
    try {
      final refresh = database._refreshFile;
      if (pager.isWalMode) {
        pager.withSharedLock(refresh);
      } else {
        pager.withExclusiveLock(refresh);
      }
      if (pager.header.defaultCacheSize != 0) {
        database._cacheSize = pager.header.defaultCacheSize;
      }
    } catch (_) {
      database.close();
      rethrow;
    }
    return database;
  }

  Map<String, _Table> _tables;
  final Map<String, SqlVirtualTableModule> _virtualTableModules;
  Map<String, _Index> _indexes;
  Map<String, _Table> _temporaryTables;
  Map<String, _Index> _temporaryIndexes;
  Map<String, _CreateView> _views;
  Map<String, _CreateView> _temporaryViews;
  Map<String, _CreateTrigger> _triggers;
  final Map<String, _CreateTrigger> _temporaryTriggers;
  final List<SqlVirtualTable> _pendingVirtualTableDestroy = [];
  final Set<SqlVirtualTable> _dirtyVirtualTables = {};
  Iterable<_CreateTrigger> get _allTriggers => [
    ..._triggers.values,
    ..._temporaryTriggers.values,
  ];
  Iterable<MapEntry<String, _CreateTrigger>> get _allTriggerEntries => [
    ..._triggers.entries,
    ..._temporaryTriggers.entries,
  ];
  final Set<String> _viewStack;
  final Map<String, _AttachedDatabase> _attachedDatabases = {};
  PureDatabase? _attachedQueryContext;
  PureDatabase? _schemaMainOverride;
  PureDatabase? _schemaTempOverride;
  PureDatabase? _activeAttachedWriteDatabase;
  var _attachedWriteContext = false;
  final Set<PureDatabase> _transactionAttachedDatabases = {};
  final SqlLogCallback? _onLog;
  final Map<String, _Table> _recursiveCteTables = {};
  final Set<String> _materializingRecursiveCtes = {};
  final Map<String, Map<int, SqlScalarFunction>> _functions = {};
  final Map<String, Map<int, SqlAggregateFunction>> _aggregateFunctions = {};
  final Map<String, Map<int, SqlWindowFunction>> _windowFunctionCallbacks = {};
  SqlitePagerSync? _pager;
  final Map<String, Object> _temporaryPragmaValues = Map.of(
    _defaultTemporaryPragmaValues,
  );
  var _busyTimeout = Duration.zero;
  var _userVersion = 0;
  var _applicationId = 0;
  var _schemaVersion = 1;
  var _analysisLimit = 0;
  var _automaticIndex = true;
  var _secureDeleteMode = 0;
  var _threads = 0;
  var _countChanges = false;
  var _fullColumnNames = false;
  var _shortColumnNames = true;
  var _tempStore = 0;
  var _walAutoCheckpoint = 1000;
  var _journalMode = 'delete';
  var _journalSizeLimit = -1;
  var _defaultCacheSize = 0;
  var _memoryPageSize = 4096;
  var _lastReturningRows = <SqlRow>[];
  var _foreignKeys = false;
  var _ignoreCheckConstraints = false;
  var _queryOnly = false;
  var _readUncommitted = false;
  var _cacheSize = 2000;
  var _synchronous = 2;
  var _caseSensitiveLike = false;
  var _reverseUnorderedSelects = false;
  var _readOnly = false;
  var _changes = 0;
  var _totalChanges = 0;
  var _lastInsertRowId = 0;
  var _deferForeignKeys = false;
  var _recursiveTriggers = false;
  var _temporaryDatabaseOpened = false;
  var _transactionCallbackDepth = 0;
  var _legacyAlterTable = false;
  var _inTransaction = false;
  var _walTransaction = false;
  SqliteRollbackJournal? _transactionJournal;
  final List<_SqlSavepoint> _savepoints = [];
  Map<String, _Table>? _memoryTransactionTables;
  Map<String, _Table>? _memoryTransactionTemporaryTables;
  Map<String, _CreateView>? _memoryTransactionViews;
  Map<String, _CreateView>? _memoryTransactionTemporaryViews;
  Map<String, _CreateTrigger>? _memoryTransactionTriggers;
  Map<String, _CreateTrigger>? _transactionTemporaryTriggers;
  SqlRow? _activeTriggerContext;
  final Set<String> _activeTriggers = {};
  int _triggerExecutionDepth = 0;
  int? _memoryTransactionSchemaVersion;
  int? _memoryTransactionPageSize;
  Map<String, Object>? _memoryTransactionTemporaryPragmaValues;

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
    return _executeParsed(statement, values, sql);
  }

  int _executeParsed(_Statement statement, List<Object?> values, String sql) {
    if (_queryOnly &&
        (_isWriteStatement(statement) || _isWritePragma(statement, values))) {
      throw PureSqlException('attempt to write a readonly database');
    }
    if (statement is _Pragma && statement.schema != null) {
      final schema = statement.schema!;
      final schemaKey = _key(schema);
      final attached = _attachedDatabases[schemaKey];
      if (attached == null && schemaKey != 'main' && schemaKey != 'temp') {
        throw PureSqlException('no such database: $schema');
      }
      if (statement.value != null &&
          attached != null &&
          !_connectionPragmaNames.contains(_key(statement.name))) {
        final pragma = _Pragma(
          statement.name,
          statement.value,
          argument: statement.argument,
        );
        if (_inTransaction)
          _transactionAttachedDatabases.add(attached.database);
        _syncAttachedConnectionState(attached.database);
        return attached.database._executeParsed(pragma, values, sql);
      }
      if (statement.value != null && schemaKey == 'temp') {
        final name = _key(statement.name);
        if (_connectionPragmaNames.contains(name)) {
          return _executeParsed(
            _Pragma(
              statement.name,
              statement.value,
              argument: statement.argument,
            ),
            values,
            sql,
          );
        }
        if (!_supportedPragmaNames.contains(name) ||
            !_writablePragmaNames.contains(name)) {
          return 0;
        }
        _temporaryDatabaseOpened = true;
        return _pragmaTemporary(statement, values);
      }
      if (attached != null &&
          statement.value == null &&
          !_connectionPragmaNames.contains(_key(statement.name))) {
        if (_inTransaction)
          _transactionAttachedDatabases.add(attached.database);
        final pragma = _Pragma(
          statement.name,
          null,
          argument: statement.argument,
        );
        return attached.database._withCurrentFile(
          () => _withSqlFunctions(
            () => attached.database._pragma(pragma, values),
          ),
        );
      }
    }
    final attachedTarget = _attachedDmlTarget(statement);
    if (attachedTarget != null) {
      if (identical(attachedTarget.$1.database, this)) {
        statement = _withDmlTable(statement, attachedTarget.$2);
      } else {
        if (_triggerExecutionDepth > 0) {
          throw PureSqlException(
            'writes to attached databases from triggers are not supported',
          );
        }
        if (_attachedWriteContext) {
          throw PureSqlException(
            'cross-database writes from an attached database are not supported',
          );
        }
        return _executeOnAttachedDatabase(
          attachedTarget.$1,
          _withDmlTable(statement, attachedTarget.$2),
          values,
          sql,
        );
      }
    }
    if (statement case _Analyze(
      :final schema,
      :final target,
    ) when schema != null && !const ['main', 'temp'].contains(_key(schema))) {
      final attached = _attachedDatabases[_key(schema)];
      if (attached == null) throw PureSqlException('no such database: $schema');
      return _executeOnAttachedDatabase(
        attached,
        _Analyze(target),
        values,
        sql,
      );
    }
    if (statement case _Vacuum(
      :final schema,
      :final into,
    ) when schema != null && !const ['main', 'temp'].contains(_key(schema))) {
      final attached = _attachedDatabases[_key(schema)];
      if (attached == null) throw PureSqlException('no such database: $schema');
      return _executeOnAttachedDatabase(
        attached,
        _Vacuum(null, into),
        values,
        sql,
      );
    }
    if (statement case _Reindex(
      :final schema,
      :final target,
    ) when schema != null && !const ['main', 'temp'].contains(_key(schema))) {
      final attached = _attachedDatabases[_key(schema)];
      if (attached == null) throw PureSqlException('no such database: $schema');
      return _executeOnAttachedDatabase(
        attached,
        _Reindex(target, schema: 'main'),
        values,
        sql,
      );
    }
    final schemaObject = _qualifiedSchemaObject(statement);
    if (schemaObject != null) {
      final separator = schemaObject.indexOf('\u0000');
      if (separator >= 0) {
        final schema = schemaObject.substring(0, separator);
        final schemaKey = _key(schema);
        final normalizedSql = _stripSchemaObjectFromSql(sql, schemaObject);
        final normalized = _withoutSchemaObject(
          statement,
          schemaObject,
          temporary: schemaKey == 'temp',
          schema: const ['main', 'temp'].contains(schemaKey) ? schemaKey : null,
        );
        if (schemaKey == 'main' || schemaKey == 'temp') {
          statement = normalized;
          sql = normalizedSql;
        } else {
          final attached = _attachedDatabases[schemaKey];
          if (attached == null) {
            throw PureSqlException('no such database: $schema');
          }
          if (_triggerExecutionDepth > 0 || _attachedWriteContext) {
            throw PureSqlException(
              'schema changes from triggers or attached writes are not supported',
            );
          }
          return _executeOnAttachedDatabase(
            attached,
            normalized,
            values,
            normalizedSql,
          );
        }
      }
    }
    if (_activeAttachedWriteDatabase != null &&
        !_attachedWriteContext &&
        (statement is _Insert ||
            statement is _Update ||
            statement is _Delete)) {
      throw PureSqlException(
        'writes to another database during an attached write are not supported',
      );
    }
    if (statement is _Begin) return _begin();
    if (statement is _Commit) return _commit();
    if (statement is _Rollback) return _rollback();
    if (statement is _Savepoint) return _savepoint(statement.name);
    if (statement is _RollbackTo) return _rollbackTo(statement.name);
    if (statement is _Release) return _release(statement.name);
    if (statement is _Attach || statement is _Detach) {
      return _withSqlFunctions(() {
        _lastReturningRows = [];
        return switch (statement) {
          _Attach() => _attach(statement, values),
          _Detach() => _detach(statement),
          _ => 0,
        };
      });
    }
    if (statement is _Pragma && _key(statement.name) == 'wal_checkpoint') {
      final pragma = statement;
      return _withSqlFunctions(() {
        _lastReturningRows = [];
        return _pragma(pragma, values);
      });
    }
    if (_pager != null &&
        !_inTransaction &&
        statement is _Pragma &&
        _key(statement.name) == 'journal_mode' &&
        statement.value != null) {
      return _changeJournalMode(statement, values);
    }
    final isDml =
        statement is _Insert || statement is _Update || statement is _Delete;
    final isTemporaryTriggerWrite = switch (statement) {
      _CreateTrigger(temporary: true) => true,
      _Drop(type: 'trigger', name: final name, schema: final schema) =>
        schema == 'main' ? false : _temporaryTriggers.containsKey(_key(name)),
      _ => false,
    };
    final statementSavepoint =
        _pager != null &&
            _inTransaction &&
            isDml &&
            _allTriggers.any((trigger) => trigger.usesRaise)
        ? _pager!.createSavepoint()
        : null;
    int run() {
      return _withSqlFunctions(() {
        _lastReturningRows = [];
        try {
          final changesSchema = _changesSchema(statement);
          final changesTemporarySchema = _changesTemporarySchema(statement);
          final deferredSnapshot = !_inTransaction && isDml && _deferForeignKeys
              ? _snapshotRows()
              : null;
          final changed = _execute(statement, values, sql);
          if (_opensTemporaryDatabase(statement)) {
            _temporaryDatabaseOpened = true;
          }
          if (changesSchema) _incrementSchemaVersion();
          if (changesTemporarySchema) {
            _temporaryPragmaValues['schema_version'] =
                ((_temporaryPragmaValues['schema_version'] as int) + 1) &
                0xffffffff;
            _temporaryPragmaValues['page_size_locked'] = true;
          }
          if (deferredSnapshot != null) {
            try {
              _validateDeferredForeignKeys();
            } catch (_) {
              _restoreRows(deferredSnapshot);
              rethrow;
            } finally {
              _deferForeignKeys = false;
            }
          }
          if (_pager == null &&
              !_inTransaction &&
              _transactionCallbackDepth == 0) {
            _dirtyVirtualTables.clear();
          }
          return changed;
        } catch (_) {
          if (_pager == null &&
              !_inTransaction &&
              _transactionCallbackDepth == 0) {
            _dirtyVirtualTables.clear();
          }
          if (!_inTransaction && isDml) _deferForeignKeys = false;
          rethrow;
        }
      });
    }

    if (_pager != null && !_inTransaction && isTemporaryTriggerWrite) {
      return _recordChanges(statement, _withCurrentFile(run));
    }

    try {
      if (_pager != null &&
          !_inTransaction &&
          statement is! _Select &&
          !isTemporaryTriggerWrite) {
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
          _recordChanges(statement, failure!.changes);
          Error.throwWithStackTrace(failure!.error, failure!.stackTrace);
        }
        return _recordChanges(statement, changed);
      }
      return _recordChanges(statement, run());
    } on _ConflictFailException catch (failure) {
      _recordChanges(statement, failure.changes);
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    } on _TriggerRaiseException catch (raise, stackTrace) {
      if (raise.action == 'ABORT' && statementSavepoint != null) {
        _pager!.rollbackToSavepoint(statementSavepoint);
      } else if (raise.action == 'ROLLBACK' && _inTransaction) {
        _rollback();
        final connectionContext = _attachedQueryContext;
        if (_attachedWriteContext &&
            connectionContext?._inTransaction == true) {
          connectionContext!._rollback();
        }
      }
      Error.throwWithStackTrace(raise.error, stackTrace);
    } on SqliteDatabaseFullException catch (error) {
      throw PureSqlException(error.message);
    }
  }

  (_AttachedDatabase, String)? _attachedDmlTarget(_Statement statement) {
    final target = switch (statement) {
      _Insert(:final table) ||
      _Update(:final table) ||
      _Delete(:final table) => table,
      _ => null,
    };
    if (target == null) return null;
    final separator = target.indexOf('\u0000');
    if (separator < 0) {
      final key = _key(target);
      if (_temporaryTables.containsKey(key) ||
          _tables.containsKey(key) ||
          _temporaryViews.containsKey(key) ||
          _views.containsKey(key)) {
        return null;
      }
      for (final attached in _attachedDatabases.values) {
        final exists = identical(attached.database, this)
            ? _tables.containsKey(key) || _views.containsKey(key)
            : attached.database._withCurrentFile(
                () =>
                    attached.database._tables.containsKey(key) ||
                    attached.database._views.containsKey(key),
              );
        if (exists) return (attached, target);
      }
      return null;
    }
    final schema = target.substring(0, separator);
    final schemaKey = _key(schema);
    if (schemaKey == 'main' || schemaKey == 'temp') return null;
    final attached = _attachedDatabases[schemaKey];
    if (attached == null) {
      throw PureSqlException('no such database: $schema');
    }
    final table = target.substring(separator + 1);
    final exists = identical(attached.database, this)
        ? _tables.containsKey(_key(table)) || _views.containsKey(_key(table))
        : attached.database._withCurrentFile(
            () =>
                attached.database._tables.containsKey(_key(table)) ||
                attached.database._views.containsKey(_key(table)),
          );
    if (!exists) throw PureSqlException('no such table: $schema.$table');
    return (attached, table);
  }

  String? _qualifiedSchemaObject(_Statement statement) => switch (statement) {
    _CreateTable(:final name) ||
    _CreateVirtualTable(:final name) ||
    _CreateTableAs(:final name) ||
    _CreateView(:final name) ||
    _CreateTrigger(:final name) ||
    _CreateIndex(:final name) ||
    _Drop(:final name) => name,
    _AlterTable(:final table) ||
    _RenameTable(:final table) ||
    _RenameColumn(:final table) ||
    _DropColumn(:final table) => table,
    _ => null,
  };

  _Statement _withoutSchemaObject(
    _Statement statement,
    String name, {
    bool temporary = false,
    String? schema,
  }) {
    final separator = name.indexOf('\u0000');
    final unqualified = name.substring(separator + 1);
    return switch (statement) {
      _CreateTable(
        :final columns,
        :final ifNotExists,
        :final primaryKeyColumns,
        :final checkExpressions,
        :final uniqueConstraints,
        :final foreignKeyConstraints,
        temporary: final isTemporary,
      ) =>
        _CreateTable(
          unqualified,
          columns,
          ifNotExists,
          primaryKeyColumns: primaryKeyColumns,
          checkExpressions: checkExpressions,
          uniqueConstraints: uniqueConstraints,
          foreignKeyConstraints: foreignKeyConstraints,
          temporary: temporary || isTemporary,
        ),
      _CreateVirtualTable(
        :final module,
        :final arguments,
        :final ifNotExists,
        temporary: final isTemporary,
      ) =>
        _CreateVirtualTable(
          unqualified,
          module,
          arguments,
          ifNotExists,
          temporary: temporary || isTemporary,
        ),
      _CreateTableAs(
        :final query,
        :final ifNotExists,
        temporary: final isTemporary,
      ) =>
        _CreateTableAs(
          unqualified,
          query,
          ifNotExists,
          temporary: temporary || isTemporary,
        ),
      _CreateView(
        :final query,
        :final ifNotExists,
        :final columns,
        temporary: final isTemporary,
      ) =>
        _CreateView(
          unqualified,
          query,
          ifNotExists,
          columns,
          temporary: temporary || isTemporary,
        ),
      _CreateTrigger(
        :final table,
        :final timing,
        :final event,
        :final updateOf,
        when: final triggerWhen,
        :final steps,
        :final ifNotExists,
        :final usesRaise,
        temporary: final isTemporary,
      ) =>
        _CreateTrigger(
          unqualified,
          table,
          timing,
          event,
          updateOf,
          triggerWhen,
          steps,
          ifNotExists,
          usesRaise,
          temporary: temporary || isTemporary,
        ),
      _CreateIndex(
        :final table,
        :final terms,
        :final unique,
        :final ifNotExists,
        :final where,
        temporary: final isTemporary,
      ) =>
        _CreateIndex(
          unqualified,
          table,
          terms,
          unique: unique,
          ifNotExists: ifNotExists,
          where: where,
          temporary: temporary || isTemporary,
        ),
      _Drop(:final type, :final ifExists) => _Drop(
        type,
        unqualified,
        ifExists,
        schema: schema,
      ),
      _AlterTable(:final column, :final definitionSql) => _AlterTable(
        unqualified,
        column,
        definitionSql,
        schema: schema,
      ),
      _RenameTable(:final newName) => _RenameTable(
        unqualified,
        newName,
        schema: schema,
      ),
      _RenameColumn(:final oldName, :final newName) => _RenameColumn(
        unqualified,
        oldName,
        newName,
        schema: schema,
      ),
      _DropColumn(:final name) => _DropColumn(
        unqualified,
        name,
        schema: schema,
      ),
      _ => throw StateError('expected schema-qualified DDL'),
    };
  }

  String _stripSchemaObjectFromSql(String sql, String name) {
    final separator = name.indexOf('\u0000');
    final schema = _key(name.substring(0, separator));
    final object = _key(name.substring(separator + 1));
    final tokens = _Tokenizer(sql).tokenize();
    for (var index = 0; index + 2 < tokens.length; index++) {
      if (_key(tokens[index].text) == schema &&
          tokens[index + 1].text == '.' &&
          _key(tokens[index + 2].text) == object) {
        return sql.replaceRange(tokens[index].start, tokens[index + 1].end, '');
      }
    }
    return sql;
  }

  _Statement _withDmlTable(_Statement statement, String table) =>
      switch (statement) {
        _Insert(
          :final columns,
          :final rows,
          :final conflict,
          :final defaultValues,
          :final select,
          :final upserts,
          :final returning,
        ) =>
          _Insert(
            table,
            columns,
            rows,
            conflict: conflict,
            defaultValues: defaultValues,
            select: select,
            upserts: upserts,
            returning: returning,
          ),
        _Update(
          :final assignments,
          :final where,
          :final conflict,
          :final returning,
        ) =>
          _Update(
            table,
            assignments,
            where,
            conflict: conflict,
            returning: returning,
          ),
        _Delete(:final where, :final returning) => _Delete(
          table,
          where,
          returning: returning,
        ),
        _ => throw StateError('expected DML statement'),
      };

  int _executeOnAttachedDatabase(
    _AttachedDatabase attached,
    _Statement statement,
    List<Object?> values,
    String sql,
  ) {
    final database = attached.database;
    if (_inTransaction) _transactionAttachedDatabases.add(database);
    _syncAttachedConnectionState(database);
    final previousAttachments = Map<String, _AttachedDatabase>.of(
      database._attachedDatabases,
    );
    final previousQueryContext = database._attachedQueryContext;
    final previousMainOverride = database._schemaMainOverride;
    final previousTempOverride = database._schemaTempOverride;
    final previousWriteContext = database._attachedWriteContext;
    final previousActiveWriteDatabase = _activeAttachedWriteDatabase;
    database._attachedDatabases
      ..clear()
      ..addAll(_attachedDatabases);
    database._attachedDatabases[_key(attached.name)] = _AttachedDatabase(
      attached.name,
      attached.filename,
      database,
    );
    database
      .._attachedQueryContext = this
      .._schemaMainOverride = this
      .._schemaTempOverride = this
      .._attachedWriteContext = true;
    _activeAttachedWriteDatabase = database;
    try {
      return _withCurrentFile(
        () => database._executeParsed(statement, values, sql),
      );
    } finally {
      _changes = database._changes;
      _totalChanges = database._totalChanges;
      _lastInsertRowId = database._lastInsertRowId;
      _lastReturningRows = List<SqlRow>.from(database._lastReturningRows);
      _activeAttachedWriteDatabase = previousActiveWriteDatabase;
      database._attachedDatabases
        ..clear()
        ..addAll(previousAttachments);
      database
        .._attachedQueryContext = previousQueryContext
        .._schemaMainOverride = previousMainOverride
        .._schemaTempOverride = previousTempOverride
        .._attachedWriteContext = previousWriteContext;
    }
  }

  void _syncAttachedConnectionState(PureDatabase database) {
    _copyFunctionOverloads(database._functions, _functions);
    _copyFunctionOverloads(database._aggregateFunctions, _aggregateFunctions);
    _copyFunctionOverloads(
      database._windowFunctionCallbacks,
      _windowFunctionCallbacks,
    );
    database
      .._caseSensitiveLike = _caseSensitiveLike
      .._busyTimeout = _busyTimeout
      .._changes = _changes
      .._totalChanges = _totalChanges
      .._lastInsertRowId = _lastInsertRowId
      .._foreignKeys = _foreignKeys
      .._deferForeignKeys = _deferForeignKeys
      .._recursiveTriggers = _recursiveTriggers
      .._ignoreCheckConstraints = _ignoreCheckConstraints
      .._queryOnly = _queryOnly || database._readOnly
      .._readUncommitted = _readUncommitted
      .._threads = _threads
      .._reverseUnorderedSelects = _reverseUnorderedSelects
      .._legacyAlterTable = _legacyAlterTable
      .._walAutoCheckpoint = _walAutoCheckpoint
      .._temporaryDatabaseOpened = _temporaryDatabaseOpened;
    final attachedPager = database._pager;
    if (attachedPager != null) {
      attachedPager
        ..busyTimeout = _busyTimeout
        ..walAutoCheckpointPages = _walAutoCheckpoint;
    }
  }

  void _setSecureDeleteMode(int mode) {
    _secureDeleteMode = mode;
    _pager?.secureDeleteMode = mode;
  }

  void _copyFunctionOverloads<T>(
    Map<String, Map<int, T>> destination,
    Map<String, Map<int, T>> source,
  ) {
    destination
      ..clear()
      ..addAll({
        for (final entry in source.entries)
          entry.key: Map<int, T>.of(entry.value),
      });
  }

  bool _isWriteStatement(_Statement statement) =>
      statement is _CreateTable ||
      statement is _CreateVirtualTable ||
      statement is _CreateTableAs ||
      statement is _CreateView ||
      statement is _CreateTrigger ||
      statement is _CreateIndex ||
      statement is _Drop ||
      statement is _AlterTable ||
      statement is _RenameTable ||
      statement is _RenameColumn ||
      statement is _DropColumn ||
      statement is _Analyze ||
      statement is _Reindex ||
      statement is _Vacuum ||
      statement is _Insert ||
      statement is _Update ||
      statement is _Delete ||
      statement is _Attach ||
      statement is _Detach;

  bool _isWritePragma(
    _Statement statement, [
    List<Object?> parameters = const [],
  ]) {
    if (statement is! _Pragma) return false;
    if (_key(statement.name) == 'wal_checkpoint') {
      return _isMutatingWalCheckpoint(statement, parameters);
    }
    if (statement.value == null) return false;
    return const {
          'application_id',
          'default_cache_size',
          'max_page_count',
          'page_size',
          'schema_version',
          'user_version',
        }.contains(_key(statement.name)) ||
        _pager != null && _key(statement.name) == 'journal_mode';
  }

  bool _isMutatingWalCheckpoint(_Pragma statement, List<Object?> parameters) {
    if (_key(statement.name) != 'wal_checkpoint') return false;
    final mode = statement.argument == null
        ? 'PASSIVE'
        : _pragmaInput(
            statement.argument!,
            parameters,
          ).toString().toUpperCase();
    return mode != 'NOOP';
  }

  int _recordChanges(_Statement statement, int changed) {
    if (statement is _Insert || statement is _Update || statement is _Delete) {
      if (_triggerExecutionDepth == 0) _changes = changed;
      _totalChanges += changed;
    }
    return changed;
  }

  bool _changesMainTable(String? schema, String table) =>
      schema == 'main' ||
      schema == null && !_temporaryTables.containsKey(_key(table));

  bool _dropChangesMain<T, U>(
    String name,
    String? schema,
    Map<String, T> temporary,
    Map<String, U> main,
  ) => schema == 'main'
      ? main.containsKey(_key(name))
      : schema == 'temp'
      ? false
      : !temporary.containsKey(_key(name)) && main.containsKey(_key(name));

  bool _changesSchema(_Statement statement) => switch (statement) {
    _CreateTable(:final name, :final temporary) =>
      !temporary &&
          !_tables.containsKey(_key(name)) &&
          !_views.containsKey(_key(name)) &&
          !_indexes.containsKey(_key(name)) &&
          !_triggers.containsKey(_key(name)),
    _CreateTableAs(:final name, :final temporary) =>
      !temporary &&
          !_tables.containsKey(_key(name)) &&
          !_views.containsKey(_key(name)) &&
          !_indexes.containsKey(_key(name)) &&
          !_triggers.containsKey(_key(name)),
    _CreateVirtualTable(:final name, :final temporary) =>
      !temporary &&
          !_tables.containsKey(_key(name)) &&
          !_views.containsKey(_key(name)) &&
          !_indexes.containsKey(_key(name)) &&
          !_triggers.containsKey(_key(name)),
    _CreateView(:final name, :final temporary) =>
      !temporary &&
          !_views.containsKey(_key(name)) &&
          !_tables.containsKey(_key(name)) &&
          !_indexes.containsKey(_key(name)) &&
          !_triggers.containsKey(_key(name)),
    _CreateTrigger(:final name, :final temporary) =>
      !temporary && !_triggers.containsKey(_key(name)),
    _CreateIndex(:final name, :final temporary) =>
      !temporary &&
          !_indexes.containsKey(_key(name)) &&
          !_tables.containsKey(_key(name)) &&
          !_views.containsKey(_key(name)) &&
          !_triggers.containsKey(_key(name)),
    _RenameTable(:final table, :final schema) ||
    _RenameColumn(:final table, :final schema) ||
    _DropColumn(:final table, :final schema) ||
    _AlterTable(
      :final table,
      :final schema,
    ) => _changesMainTable(schema, table),
    _Analyze(:final schema, :final target) =>
      (schema == null || _key(schema) == 'main') &&
          !_tables.containsKey('sqlite_stat1') &&
          !(schema == null &&
              target != null &&
              (_temporaryTables.containsKey(_key(target)) ||
                  _temporaryIndexes.containsKey(_key(target)))),
    _Drop(:final type, :final name, :final schema) => switch (type) {
      'table' => _dropChangesMain(name, schema, _temporaryTables, _tables),
      'view' => _dropChangesMain(name, schema, _temporaryViews, _views),
      'index' => _dropChangesMain(name, schema, _temporaryIndexes, _indexes),
      'trigger' => _dropChangesMain(
        name,
        schema,
        _temporaryTriggers,
        _triggers,
      ),
      _ => false,
    },
    _ => false,
  };

  bool _temporarySchemaObjectExists(String name) =>
      _temporaryTables.containsKey(_key(name)) ||
      _temporaryViews.containsKey(_key(name)) ||
      _temporaryIndexes.containsKey(_key(name)) ||
      _temporaryTriggers.containsKey(_key(name));

  void _restoreTemporaryPragmas(Map<String, Object> snapshot) {
    for (final name in const {
      'application_id',
      'default_cache_size',
      'schema_version',
      'user_version',
    }) {
      _temporaryPragmaValues[name] = snapshot[name]!;
    }
  }

  bool _changesTemporarySchema(_Statement statement) => switch (statement) {
    _CreateTable(:final name, temporary: true) ||
    _CreateVirtualTable(:final name, temporary: true) ||
    _CreateTableAs(:final name, temporary: true) ||
    _CreateView(:final name, temporary: true) ||
    _CreateTrigger(:final name, temporary: true) ||
    _CreateIndex(
      :final name,
      temporary: true,
    ) => !_temporarySchemaObjectExists(name),
    _RenameTable(:final table, :final schema) ||
    _RenameColumn(:final table, :final schema) ||
    _DropColumn(:final table, :final schema) ||
    _AlterTable(:final table, :final schema) =>
      _key(schema ?? '') == 'temp' ||
          schema == null && _temporaryTables.containsKey(_key(table)),
    _Analyze(:final schema, :final target) =>
      !_temporaryTables.containsKey('sqlite_stat1') &&
          (_key(schema ?? '') == 'temp' ||
              schema == null &&
                  target != null &&
                  (_temporaryTables.containsKey(_key(target)) ||
                      _temporaryIndexes.containsKey(_key(target)))),
    _Drop(:final type, :final name, :final schema) => switch (type) {
      'table' =>
        _key(schema ?? '') != 'main' &&
            _temporaryTables.containsKey(_key(name)),
      'view' =>
        _key(schema ?? '') != 'main' && _temporaryViews.containsKey(_key(name)),
      'index' =>
        _key(schema ?? '') != 'main' &&
            _temporaryIndexes.containsKey(_key(name)),
      'trigger' =>
        _key(schema ?? '') != 'main' &&
            _temporaryTriggers.containsKey(_key(name)),
      _ => false,
    },
    _ => false,
  };

  bool _opensTemporaryDatabase(_Statement statement) => switch (statement) {
    _CreateTable(temporary: true) ||
    _CreateVirtualTable(temporary: true) ||
    _CreateTableAs(temporary: true) ||
    _CreateView(temporary: true) ||
    _CreateTrigger(temporary: true) ||
    _CreateIndex(temporary: true) ||
    _Analyze(schema: 'temp') => true,
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

  /// Runs a `SELECT`, read-only `PRAGMA`, or DML with `RETURNING`/count_changes.
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
      final schema = statement.schema;
      if (schema != null) {
        final schemaKey = _key(schema);
        final attached = _attachedDatabases[schemaKey];
        if (attached == null && schemaKey != 'main' && schemaKey != 'temp') {
          throw PureSqlException('no such database: $schema');
        }
        if (attached != null &&
            !_connectionPragmaNames.contains(_key(statement.name))) {
          final pragma = _Pragma(
            statement.name,
            null,
            argument: statement.argument,
          );
          final rows = attached.database._withCurrentFile(
            () => _withSqlFunctions(
              () => attached.database._pragmaRows(pragma, values),
            ),
          );
          if (_key(statement.name) == 'table_list') {
            return [
              for (final row in rows)
                if (row['schema'] == 'main') {...row, 'schema': attached.name},
            ];
          }
          return rows;
        }
        if (schemaKey == 'temp' &&
            !_connectionPragmaNames.contains(_key(statement.name)) &&
            _supportedPragmaNames.contains(_key(statement.name))) {
          _temporaryDatabaseOpened = true;
        }
      }
      if (_queryOnly && _isWritePragma(statement, values)) {
        throw PureSqlException('attempt to write a readonly database');
      }
      if (_key(statement.name) == 'wal_checkpoint') {
        return _withSqlFunctions(() => _pragmaRows(statement, values));
      }
      return _withCurrentFile(
        () => _withSqlFunctions(() => _pragmaRows(statement, values)),
      );
    }
    final isDml =
        statement is _Insert || statement is _Update || statement is _Delete;
    final hasReturning =
        statement is _Insert && statement.returning != null ||
        statement is _Update && statement.returning != null ||
        statement is _Delete && statement.returning != null;
    if (isDml && (hasReturning || _countChanges)) {
      final changed = _executeOne(sql, parameters);
      if (hasReturning) return List<SqlRow>.from(_lastReturningRows);
      final columnName = switch (statement) {
        _Insert() => 'rows inserted',
        _Update() => 'rows updated',
        _Delete() => 'rows deleted',
        _ => throw StateError('DML statement expected'),
      };
      return [
        <String, Object?>{columnName: changed},
      ];
    }
    if (statement is! _Select) {
      throw PureSqlException('Only SELECT can be used with select()');
    }
    return _withCurrentFile(
      () => _withSqlFunctions(() => _select(statement, values)),
    );
  }

  /// Commits [action] on success and rolls it back if [action] throws.
  ///
  /// Nested transactions are not supported for persistent databases.
  T transaction<T>(T Function(PureDatabase database) action) {
    if (_pager == null) {
      final beforeTemporaryPragmas = Map<String, Object>.of(
        _temporaryPragmaValues,
      );
      final before = _cloneTables(_tables);
      final beforeTemporary = _cloneTables(_temporaryTables);
      final modulesBefore = _virtualTableInstances();
      final beforeViews = Map<String, _CreateView>.of(_views);
      final beforeTemporaryViews = Map<String, _CreateView>.of(_temporaryViews);
      final beforeTriggers = Map<String, _CreateTrigger>.of(_triggers);
      final beforeTemporaryTriggers = Map<String, _CreateTrigger>.of(
        _temporaryTriggers,
      );
      final beforeSchemaVersion = _schemaVersion;
      _transactionCallbackDepth++;
      try {
        final result = action(this);
        _finishVirtualTableDrops(commit: true);
        _dirtyVirtualTables.clear();
        return result;
      } catch (_) {
        final modulesAfter = _virtualTableInstances();
        _restoreVirtualTableSnapshots(before);
        _restoreVirtualTableSnapshots(beforeTemporary);
        _tables = before;
        _temporaryTables = beforeTemporary;
        _views = beforeViews;
        _temporaryViews = beforeTemporaryViews;
        _triggers = beforeTriggers;
        _temporaryTriggers
          ..clear()
          ..addAll(beforeTemporaryTriggers);
        _restoreTemporaryPragmas(beforeTemporaryPragmas);
        _indexes = {
          for (final table in before.values)
            for (final index in table.indexes) _key(index.name): index,
        };
        _temporaryIndexes = {
          for (final table in beforeTemporary.values)
            for (final index in table.indexes) _key(index.name): index,
        };
        _schemaVersion = beforeSchemaVersion;
        final modulesRestored = _virtualTableInstances();
        for (final module in {...modulesBefore, ...modulesAfter}) {
          if (!modulesRestored.contains(module) &&
              !_pendingVirtualTableDestroy.contains(module)) {
            _disposeVirtualTable(module);
          }
        }
        _finishVirtualTableDrops(commit: false);
        _dirtyVirtualTables.clear();
        rethrow;
      } finally {
        _transactionCallbackDepth--;
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
        _CreateVirtualTable() => _createVirtualTable(statement, sql: sql),
        _CreateTableAs() => _createTableAs(statement, values),
        _CreateView() => _createView(statement, sql: sql),
        _CreateTrigger() => _createTrigger(statement, sql: sql),
        _Drop() => _drop(statement),
        _CreateIndex() => _createIndex(statement, sql: sql),
        _Pragma() => _pragma(statement, values),
        _RenameTable() => _renameTable(statement),
        _RenameColumn() => _renameColumn(statement),
        _DropColumn() => _dropColumn(statement),
        _AlterTable() => _alterTable(statement, sql: sql),
        _Analyze() => _analyze(statement),
        _Reindex() => _reindex(statement),
        _Vacuum() => _vacuum(statement, values),
        _Begin() ||
        _Commit() ||
        _Rollback() ||
        _Savepoint() ||
        _RollbackTo() ||
        _Release() ||
        _Attach() ||
        _Detach() => throw PureSqlException(
          'transaction control must use execute()',
        ),
        _Insert() => _insert(statement, values),
        _Update() => _update(statement, values),
        _Delete() => _delete(statement, values),
        _Select() => throw PureSqlException('SELECT must use select()'),
      };

  int _attach(_Attach statement, List<Object?> parameters) {
    final schema = statement.schema;
    final key = _key(schema);
    if (key.isEmpty || key == 'main' || key == 'temp') {
      throw PureSqlException('cannot attach database as $schema');
    }
    if (_attachedDatabases.containsKey(key)) {
      throw PureSqlException('database $schema is already in use');
    }
    final filename = _eval(
      statement.filename,
      const {},
      parameters,
    )?.toString();
    if (filename == null) {
      throw PureSqlException('ATTACH DATABASE filename cannot be NULL');
    }
    var path = filename;
    var memory = filename.isEmpty || filename == ':memory:';
    var readOnly = false;
    var displayFilename = filename;
    if (filename.length >= 5 &&
        filename.substring(0, 5).toLowerCase() == 'file:') {
      final uri = Uri.parse(filename);
      if (uri.scheme.toLowerCase() != 'file' ||
          uri.hasFragment ||
          uri.host.isNotEmpty && uri.host != 'localhost') {
        throw PureSqlException('invalid SQLite file URI: $filename');
      }
      final options = uri.queryParameters;
      if (options.containsKey('vfs') || options['cache'] == 'shared') {
        throw PureSqlException('unsupported SQLite file URI option');
      }
      path = Uri.decodeComponent(uri.path);
      final mode = (options['mode'] ?? 'rwc').toLowerCase();
      memory = mode == 'memory' || path.isEmpty || path == ':memory:';
      if (!memory && !const ['ro', 'rw', 'rwc'].contains(mode)) {
        throw PureSqlException('invalid SQLite file URI mode: $mode');
      }
      readOnly =
          mode == 'ro' ||
          const [
            '1',
            'true',
            'yes',
          ].contains((options['immutable'] ?? '').toLowerCase());
      if (!memory &&
          (mode != 'rwc' || readOnly) &&
          !io.File(path).existsSync()) {
        throw PureSqlException('unable to open database file: $path');
      }
      displayFilename = memory ? '' : path;
    }
    if (memory) displayFilename = '';
    final database = memory
        ? PureDatabase.memory(
            onLog: _onLog,
            virtualTableModules: _virtualTableModules,
          )
        : PureDatabase.open(
            path,
            busyTimeout: _busyTimeout,
            onLog: _onLog,
            virtualTableModules: _virtualTableModules,
          );
    database._setSecureDeleteMode(_secureDeleteMode);
    if (readOnly) {
      database
        .._readOnly = true
        .._queryOnly = true;
    }
    try {
      if (_inTransaction && !database._readOnly) {
        database._begin();
        for (final savepoint in _savepoints) {
          database._savepoint(savepoint.name);
        }
      }
      _attachedDatabases[key] = _AttachedDatabase(
        schema,
        displayFilename,
        database,
      );
    } catch (_) {
      if (database._inTransaction) database._rollback();
      database.close();
      rethrow;
    }
    return 0;
  }

  int _detach(_Detach statement) {
    final key = _key(statement.schema);
    final attached = _attachedDatabases[key];
    if (attached == null) {
      throw PureSqlException('no such database: ${statement.schema}');
    }
    if (_inTransaction &&
        _transactionAttachedDatabases.contains(attached.database)) {
      throw PureSqlException('database ${statement.schema} is locked');
    }
    if (attached.database._inTransaction) attached.database._rollback();
    _attachedDatabases.remove(key);
    attached.database.close();
    return 0;
  }

  int _createTableAs(_CreateTableAs statement, List<Object?> parameters) {
    final key = _key(statement.name);
    final tables = statement.temporary ? _temporaryTables : _tables;
    final indexes = statement.temporary ? _temporaryIndexes : _indexes;
    final triggers = statement.temporary ? _temporaryTriggers : _triggers;
    if (tables.containsKey(key) ||
        indexes.containsKey(key) ||
        triggers.containsKey(key) ||
        statement.temporary && _temporaryViews.containsKey(key) ||
        !statement.temporary && _views.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('table already exists: ${statement.name}');
    }

    _ensureUniqueSelectOutputNames(statement.query);
    final rows = _select(statement.query, parameters);
    final names = _materializedColumnNames(statement.query, rows, parameters);
    final definitions = _queryColumnDefinitions(statement.query, parameters);
    final typeNames = definitions.length == names.length
        ? [for (final definition in definitions) definition.typeName]
        : const <String?>[];
    final quoted = (String name) => '"${name.replaceAll('"', '""')}"';
    final columns = [
      for (var index = 0; index < names.length; index++)
        _ColumnDef(
          names[index],
          typeName: index < typeNames.length ? typeNames[index] : null,
        ),
    ];
    final schemaSql =
        'CREATE TABLE ${quoted(statement.name)} ('
        '${columns.map((column) {
          final type = column.typeName;
          return '${quoted(column.name)}${type == null || type.isEmpty ? '' : ' $type'}';
        }).join(', ')})';
    _create(
      _CreateTable(
        statement.name,
        columns,
        false,
        temporary: statement.temporary,
      ),
      sql: schemaSql,
    );
    if (rows.isEmpty) return 0;
    return _insert(
      _Insert(statement.name, names, [
        for (final row in rows) [for (final name in names) _Literal(row[name])],
      ]),
      const [],
    );
  }

  List<_ColumnDef> _queryColumnDefinitions(
    _Select query,
    List<Object?> parameters, [
    Set<_Select>? active,
  ]) {
    active ??= <_Select>{};
    if (!active.add(query)) {
      return [for (final item in query.items) _ColumnDef(item.outputName)];
    }
    try {
      final sources =
          <({String name, String? alias, List<_ColumnDef> columns})>[
            if (query.fromQuery != null)
              (
                name: query.alias ?? '(subquery)',
                alias: query.alias,
                columns: _queryColumnDefinitions(
                  query.fromQuery!,
                  parameters,
                  active,
                ),
              )
            else if (query.tableFunction != null)
              (
                name: query.tableFunction!.name,
                alias: query.alias,
                columns: _tableFunctionColumns(query.tableFunction!.name),
              )
            else if (query.table != null)
              (
                name: query.table!,
                alias: query.alias,
                columns: _sourceColumnDefinitions(
                  query.table!,
                  query.ctes,
                  parameters,
                  active,
                ),
              ),
            for (final join in query.joins)
              (
                name: join.tableFunction?.name ?? join.table ?? '(subquery)',
                alias: join.alias,
                columns: join.tableFunction != null
                    ? _tableFunctionColumns(join.tableFunction!.name)
                    : join.query != null
                    ? _queryColumnDefinitions(join.query!, parameters, active)
                    : _sourceColumnDefinitions(
                        join.table!,
                        query.ctes,
                        parameters,
                        active,
                      ),
              ),
          ];
      final result = <_ColumnDef>[];
      for (final item in query.items) {
        if (item.expression case _Column(
          :final name,
        ) when name == '*' || name.endsWith('.*')) {
          final qualifier = name == '*'
              ? null
              : name.substring(0, name.length - 2);
          final selectedSources = qualifier == null
              ? sources
              : sources.where(
                  (source) =>
                      _key(source.alias ?? _sourceLeaf(source.name)) ==
                      _key(qualifier),
                );
          if (qualifier != null && selectedSources.isEmpty) {
            return [];
          }
          for (final source in selectedSources) {
            for (final column in source.columns) {
              result.add(
                _ColumnDef(
                  column.name,
                  typeName: _ctasDeclaredType(column.typeName ?? ''),
                ),
              );
            }
          }
        } else {
          result.add(
            _ColumnDef(
              item.outputName,
              typeName: _queryExpressionTypeName(
                item.expression,
                sources,
                parameters,
                active,
              ),
            ),
          );
        }
      }
      return result;
    } finally {
      active.remove(query);
    }
  }

  String _queryExpressionTypeName(
    _Expr expression,
    List<({String name, String? alias, List<_ColumnDef> columns})> sources,
    List<Object?> parameters,
    Set<_Select> active,
  ) {
    if (expression is _Cast) return _ctasDeclaredType(expression.type);
    if (expression is _ScalarSubquery) {
      final columns = _queryColumnDefinitions(
        expression.query,
        parameters,
        active,
      );
      return columns.isEmpty ? '' : columns.first.typeName ?? '';
    }
    if (expression is! _Column ||
        expression.name == '*' ||
        expression.name.endsWith('.*')) {
      return '';
    }
    final separator = expression.name.lastIndexOf('.');
    final columnName = separator < 0
        ? expression.name
        : expression.name.substring(separator + 1);
    final qualifier = separator < 0
        ? null
        : expression.name.substring(0, separator);
    final candidates = sources.where((source) {
      if (qualifier != null &&
          _key(source.alias ?? _sourceLeaf(source.name)) != _key(qualifier)) {
        return false;
      }
      return source.columns.any(
            (column) => _key(column.name) == _key(columnName),
          ) ||
          const {'rowid', '_rowid_', 'oid'}.contains(_key(columnName)) &&
              source.columns.every(
                (column) => _key(column.name) != _key(columnName),
              );
    }).toList();
    if (candidates.length != 1) return '';
    final column = candidates.single.columns.where(
      (column) => _key(column.name) == _key(columnName),
    );
    return column.isEmpty
        ? 'INT'
        : _ctasDeclaredType(column.single.typeName ?? '');
  }

  List<_ColumnDef> _sourceColumnDefinitions(
    String name,
    Map<String, _Cte> ctes,
    List<Object?> parameters,
    Set<_Select> active,
  ) {
    final separator = name.indexOf('\u0000');
    if (separator >= 0) {
      return _schemaColumnDefinitions(
        name.substring(0, separator),
        name.substring(separator + 1),
        parameters,
        active,
      );
    }
    final key = _key(name);
    final recursive = _recursiveCteTables[key];
    if (recursive != null) return recursive.columns;
    final cte = ctes[key];
    if (cte != null) {
      final columns = _queryColumnDefinitions(cte.query, parameters, active);
      return _renameColumnDefinitions(columns, cte.columns);
    }
    final queryContext = _attachedQueryContext;
    if (queryContext != null) {
      return queryContext._sourceColumnDefinitions(
        name,
        ctes,
        parameters,
        active,
      );
    }
    final temporary = _temporaryTables[key];
    if (temporary != null) return temporary.columns;
    final temporaryView = _temporaryViews[key];
    if (temporaryView != null) {
      return _viewColumnDefinitions(temporaryView, parameters, active);
    }
    final main = _mainColumnDefinitions(name, parameters, active);
    if (main.isNotEmpty) return main;
    for (final attached in _attachedDatabases.values) {
      final columns = attached.database._mainColumnDefinitions(
        name,
        parameters,
        active,
      );
      if (columns.isNotEmpty) return columns;
    }
    return const [];
  }

  List<_ColumnDef> _schemaColumnDefinitions(
    String schema,
    String name,
    List<Object?> parameters,
    Set<_Select> active,
  ) {
    switch (_key(schema)) {
      case 'main':
        return (_schemaMainOverride ?? this)._mainColumnDefinitions(
          name,
          parameters,
          active,
        );
      case 'temp':
        final database = _schemaTempOverride ?? this;
        final table = database._temporaryTables[_key(name)];
        if (table != null) return table.columns;
        final view = database._temporaryViews[_key(name)];
        return view == null
            ? const []
            : database._viewColumnDefinitions(view, parameters, active);
      default:
        final attached = _attachedDatabases[_key(schema)];
        return attached?.database._mainColumnDefinitions(
              name,
              parameters,
              active,
            ) ??
            const [];
    }
  }

  List<_ColumnDef> _mainColumnDefinitions(
    String name,
    List<Object?> parameters,
    Set<_Select> active,
  ) {
    final table = _tables[_key(name)];
    if (table != null) return table.columns;
    final view = _views[_key(name)];
    return view == null
        ? const []
        : _viewColumnDefinitions(view, parameters, active);
  }

  List<_ColumnDef> _viewColumnDefinitions(
    _CreateView view,
    List<Object?> parameters,
    Set<_Select> active,
  ) => _renameColumnDefinitions(
    _queryColumnDefinitions(view.query, parameters, active),
    view.columns,
  );

  List<_ColumnDef> _renameColumnDefinitions(
    List<_ColumnDef> columns,
    List<String>? names,
  ) => names == null || names.length != columns.length
      ? columns
      : [
          for (var index = 0; index < names.length; index++)
            _ColumnDef(names[index], typeName: columns[index].typeName),
        ];

  void _ensureUniqueSelectOutputNames(_Select query, [Set<_Select>? visited]) {
    visited ??= <_Select>{};
    if (!visited.add(query)) return;
    final used = <String>{};
    for (var index = 0; index < query.items.length; index++) {
      final item = query.items[index];
      final original = item.outputName.isEmpty
          ? 'column${index + 1}'
          : item.outputName;
      var candidate = original;
      var suffix = 1;
      while (!used.add(_key(candidate))) {
        candidate = '$original:$suffix';
        suffix++;
      }
      if (candidate != item.outputName) {
        query.items[index] = _SelectItem(
          item.expression,
          candidate,
          explicitAlias: true,
        );
      }
    }
    for (final term in query.compoundTerms) {
      _ensureUniqueSelectOutputNames(term.query, visited);
    }
    if (query.fromQuery != null) {
      _ensureUniqueSelectOutputNames(query.fromQuery!, visited);
    }
    for (final join in query.joins) {
      if (join.query != null) {
        _ensureUniqueSelectOutputNames(join.query!, visited);
      }
    }
    for (final cte in query.ctes.values) {
      _ensureUniqueSelectOutputNames(cte.query, visited);
    }
  }

  int _begin() {
    if (_inTransaction) throw PureSqlException('transaction already active');
    _memoryTransactionTemporaryPragmaValues = Map.of(_temporaryPragmaValues);
    if (_pager == null) {
      _memoryTransactionTables = _cloneTables(_tables);
      _memoryTransactionTemporaryTables = _cloneTables(_temporaryTables);
      _memoryTransactionViews = Map.of(_views);
      _memoryTransactionTemporaryViews = Map.of(_temporaryViews);
      _memoryTransactionTriggers = Map.of(_triggers);
      _transactionTemporaryTriggers = Map.of(_temporaryTriggers);
      _memoryTransactionSchemaVersion = _schemaVersion;
      _memoryTransactionPageSize = _memoryPageSize;
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
              mode: _journalMode,
              flush: _synchronous > 0,
              sizeLimit: _journalSizeLimit,
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
    _memoryTransactionTables ??= _cloneTables(_tables);
    _memoryTransactionTemporaryTables ??= _cloneTables(_temporaryTables);
    _memoryTransactionTemporaryViews ??= Map.of(_temporaryViews);
    _transactionTemporaryTriggers ??= Map.of(_temporaryTriggers);
    _inTransaction = true;
    _transactionAttachedDatabases.clear();
    try {
      for (final attached in _attachedDatabases.values) {
        if (!attached.database._readOnly) attached.database._begin();
      }
    } catch (_) {
      _rollback();
      rethrow;
    }
    return 0;
  }

  int _commit() {
    if (!_inTransaction) return 0;
    try {
      _validateDeferredForeignKeys();
      for (final attached in _attachedDatabases.values) {
        attached.database._validateDeferredForeignKeys();
      }
    } catch (_) {
      _rollback();
      rethrow;
    }
    final participants = _transactionParticipants();
    final persistentParticipants = participants
        .where((database) => database._pager != null)
        .toList();
    if (persistentParticipants.length > 1 &&
        persistentParticipants.every(
          (database) =>
              !database._walTransaction &&
              database._synchronous > 0 &&
              database._transactionJournal?.canUseSuperJournal == true,
        )) {
      return _commitWithSuperJournal(participants, persistentParticipants);
    }
    try {
      for (final attached in _attachedDatabases.values) {
        attached.database._commit();
      }
      if (_walTransaction) {
        _pager!.commitWalTransaction();
      } else {
        if (_synchronous == 1) _pager?.syncDatabase();
        _transactionJournal?.commit(sizeLimit: _journalSizeLimit);
      }
      _finishVirtualTableDrops(commit: true);
      _dirtyVirtualTables.clear();
    } catch (_) {
      if (_inTransaction) _rollback();
      rethrow;
    } finally {
      if (_inTransaction) {
        _transactionJournal = null;
        _savepoints.clear();
        _memoryTransactionTables = null;
        _memoryTransactionTemporaryTables = null;
        _memoryTransactionViews = null;
        _memoryTransactionTemporaryViews = null;
        _memoryTransactionTriggers = null;
        _transactionTemporaryTriggers = null;
        _memoryTransactionSchemaVersion = null;
        _memoryTransactionPageSize = null;
        _memoryTransactionTemporaryPragmaValues = null;
        _inTransaction = false;
        _deferForeignKeys = false;
        _transactionAttachedDatabases.clear();
        if (_walTransaction) {
          _pager?.releaseWalWriterLock();
          _walTransaction = false;
        } else {
          _pager?.releaseExclusiveLock();
        }
      }
    }
    return 0;
  }

  List<PureDatabase> _transactionParticipants() {
    final participants = <PureDatabase>[];
    final visited = <PureDatabase>{};
    void collect(PureDatabase database) {
      if (!database._inTransaction || !visited.add(database)) return;
      participants.add(database);
      for (final attached in database._attachedDatabases.values) {
        collect(attached.database);
      }
    }

    collect(this);
    return participants;
  }

  int _commitWithSuperJournal(
    List<PureDatabase> participants,
    List<PureDatabase> persistentParticipants,
  ) {
    final journals = [
      for (final database in persistentParticipants)
        database._transactionJournal!,
    ];
    io.File? masterJournal;
    var committed = false;
    try {
      masterJournal = SqliteRollbackJournal.createSuperJournal(
        persistentParticipants.first._pager!.path,
        journals.map((journal) => journal.path),
      );
      for (final journal in journals) {
        journal.setSuperJournal(masterJournal.path);
      }
      for (final database in persistentParticipants) {
        database._pager!.syncDatabase();
      }
      try {
        masterJournal.deleteSync();
        committed = true;
      } catch (_) {
        committed = !masterJournal.existsSync();
        rethrow;
      }
    } catch (error, stackTrace) {
      if (!committed && masterJournal != null && !masterJournal.existsSync()) {
        committed = true;
      }
      if (!committed) {
        try {
          _rollback();
          if (masterJournal?.existsSync() == true) {
            masterJournal!.deleteSync();
          }
        } catch (_) {
          // Keep the coordinator file so later journal recovery still rolls
          // back every participant if an in-process rollback also fails.
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      final cleanupError = _finishSuperJournalCommit(participants);
      if (cleanupError != null) {
        Error.throwWithStackTrace(cleanupError, StackTrace.current);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    final cleanupError = _finishSuperJournalCommit(participants);
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, StackTrace.current);
    }
    return 0;
  }

  Object? _finishSuperJournalCommit(List<PureDatabase> participants) {
    Object? firstError;
    for (final database in participants) {
      try {
        database._transactionJournal?.commit(
          sizeLimit: database._journalSizeLimit,
        );
      } catch (error) {
        firstError ??= error;
      }
      database._transactionJournal = null;
      try {
        database._finishVirtualTableDrops(commit: true);
      } catch (error) {
        firstError ??= error;
      }
      database._dirtyVirtualTables.clear();
      database._clearCommittedTransactionState();
    }
    return firstError;
  }

  void _clearCommittedTransactionState() {
    _savepoints.clear();
    _memoryTransactionTables = null;
    _memoryTransactionTemporaryTables = null;
    _memoryTransactionViews = null;
    _memoryTransactionTemporaryViews = null;
    _memoryTransactionTriggers = null;
    _transactionTemporaryTriggers = null;
    _memoryTransactionSchemaVersion = null;
    _memoryTransactionPageSize = null;
    _memoryTransactionTemporaryPragmaValues = null;
    _inTransaction = false;
    _deferForeignKeys = false;
    _transactionAttachedDatabases.clear();
    if (_walTransaction) {
      _pager?.releaseWalWriterLock();
      _walTransaction = false;
    } else {
      _pager?.releaseExclusiveLock();
    }
  }

  int _rollback() {
    if (!_inTransaction) return 0;
    Object? attachedRollbackError;
    if (!_attachedWriteContext) {
      for (final attached in _attachedDatabases.values) {
        if (identical(attached.database, this) ||
            !attached.database._inTransaction) {
          continue;
        }
        try {
          attached.database._rollback();
        } catch (error) {
          attachedRollbackError ??= error;
        }
      }
    }
    if (_memoryTransactionTables case final snapshot?) {
      _restoreVirtualTableSnapshots(snapshot);
    }
    if (_memoryTransactionTemporaryTables case final snapshot?) {
      _restoreVirtualTableSnapshots(snapshot);
    }
    if (_pager == null) {
      _tables = _memoryTransactionTables!;
      _temporaryTables = _memoryTransactionTemporaryTables!;
      _views = _memoryTransactionViews!;
      _temporaryViews = _memoryTransactionTemporaryViews!;
      _triggers = _memoryTransactionTriggers!;
      _temporaryTriggers
        ..clear()
        ..addAll(_transactionTemporaryTriggers ?? const {});
      _schemaVersion = _memoryTransactionSchemaVersion!;
      _memoryPageSize = _memoryTransactionPageSize!;
      _indexes = {
        for (final table in _tables.values)
          for (final index in table.indexes) _key(index.name): index,
      };
      _temporaryIndexes = {
        for (final table in _temporaryTables.values)
          for (final index in table.indexes) _key(index.name): index,
      };
    } else if (_walTransaction) {
      try {
        _pager!.rollbackWalTransaction();
        _refreshFile(virtualTableSources: _memoryTransactionTables);
      } finally {
        _memoryTransactionTables = null;
        _temporaryTables = _memoryTransactionTemporaryTables!;
        _temporaryIndexes = {
          for (final table in _temporaryTables.values)
            for (final index in table.indexes) _key(index.name): index,
        };
        _memoryTransactionTemporaryTables = null;
        _memoryTransactionViews = null;
        _temporaryViews = _memoryTransactionTemporaryViews!;
        _memoryTransactionTemporaryViews = null;
        _memoryTransactionTriggers = null;
        _temporaryTriggers
          ..clear()
          ..addAll(_transactionTemporaryTriggers ?? const {});
        _transactionTemporaryTriggers = null;
        _memoryTransactionSchemaVersion = null;
        _memoryTransactionPageSize = null;
        _inTransaction = false;
        _walTransaction = false;
        _pager!.releaseWalWriterLock();
      }
    } else {
      try {
        _transactionJournal!.rollback(
          _pager!.path,
          databaseHandle: _pager!.databaseHandle,
          sizeLimit: _journalSizeLimit,
        );
        _refreshFile(virtualTableSources: _memoryTransactionTables);
      } finally {
        _transactionJournal = null;
        _memoryTransactionTables = null;
        _temporaryTables = _memoryTransactionTemporaryTables!;
        _temporaryIndexes = {
          for (final table in _temporaryTables.values)
            for (final index in table.indexes) _key(index.name): index,
        };
        _memoryTransactionTemporaryTables = null;
        _memoryTransactionViews = null;
        _temporaryViews = _memoryTransactionTemporaryViews!;
        _memoryTransactionTemporaryViews = null;
        _memoryTransactionTriggers = null;
        _temporaryTriggers
          ..clear()
          ..addAll(_transactionTemporaryTriggers ?? const {});
        _transactionTemporaryTriggers = null;
        _memoryTransactionSchemaVersion = null;
        _memoryTransactionPageSize = null;
        _inTransaction = false;
        _pager!.releaseExclusiveLock();
      }
    }
    _deferForeignKeys = false;
    if (_memoryTransactionTemporaryPragmaValues case final snapshot?) {
      _restoreTemporaryPragmas(snapshot);
    }
    _savepoints.clear();
    _transactionJournal = null;
    _memoryTransactionTables = null;
    _memoryTransactionTemporaryTables = null;
    _memoryTransactionViews = null;
    _memoryTransactionTemporaryViews = null;
    _memoryTransactionTriggers = null;
    _transactionTemporaryTriggers = null;
    _memoryTransactionSchemaVersion = null;
    _memoryTransactionPageSize = null;
    _memoryTransactionTemporaryPragmaValues = null;
    _inTransaction = false;
    _transactionAttachedDatabases.clear();
    _finishVirtualTableDrops(commit: false);
    _dirtyVirtualTables.clear();
    if (attachedRollbackError != null) throw attachedRollbackError;
    return 0;
  }

  int _savepoint(String name) {
    final startsTransaction = !_inTransaction;
    if (startsTransaction) _begin();
    final propagated = <PureDatabase>[];
    try {
      for (final attached in _attachedDatabases.values) {
        attached.database._savepoint(name);
        propagated.add(attached.database);
      }
      _savepoints.add(
        _SqlSavepoint(
          name,
          startsTransaction,
          pager: _pager?.createSavepoint(),
          tables: _cloneTables(_tables),
          temporaryTables: _cloneTables(_temporaryTables),
          views: Map.of(_views),
          temporaryViews: Map.of(_temporaryViews),
          triggers: Map.of(_triggers),
          temporaryTriggers: Map.of(_temporaryTriggers),
          schemaVersion: _schemaVersion,
          applicationId: _applicationId,
          userVersion: _userVersion,
          memoryPageSize: _memoryPageSize,
          temporaryPragmaValues: Map.of(_temporaryPragmaValues),
          pendingVirtualTableDestroy: List.of(_pendingVirtualTableDestroy),
          dirtyVirtualTables: Set.of(_dirtyVirtualTables),
        ),
      );
    } catch (_) {
      for (final database in propagated.reversed) {
        try {
          database._rollbackTo(name);
          database._release(name);
        } catch (_) {}
      }
      if (startsTransaction) _rollback();
      rethrow;
    }
    return 0;
  }

  int _rollbackTo(String name) {
    final index = _savepoints.lastIndexWhere(
      (savepoint) => _key(savepoint.name) == _key(name),
    );
    if (index < 0) throw PureSqlException('no such savepoint: $name');
    final savepoint = _savepoints[index];
    final modulesBefore = {
      ..._virtualTableInstances(),
      ..._pendingVirtualTableDestroy,
    };
    for (final attached in _attachedDatabases.values) {
      if (attached.database._savepoints.any(
        (candidate) => _key(candidate.name) == _key(name),
      )) {
        attached.database._rollbackTo(name);
      }
    }
    _restoreVirtualTableSnapshots(savepoint.tables);
    _restoreVirtualTableSnapshots(savepoint.temporaryTables);
    if (_pager != null) {
      _pager!.rollbackToSavepoint(savepoint.pager!);
      _refreshFile(virtualTableSources: savepoint.tables);
    } else {
      _tables = _cloneTables(savepoint.tables);
      _indexes = {
        for (final table in _tables.values)
          for (final index in table.indexes) _key(index.name): index,
      };
      _views = Map.of(savepoint.views);
      _triggers = Map.of(savepoint.triggers);
      _applicationId = savepoint.applicationId;
      _userVersion = savepoint.userVersion;
      _schemaVersion = savepoint.schemaVersion;
    }
    _temporaryTables = _cloneTables(savepoint.temporaryTables);
    _temporaryIndexes = {
      for (final table in _temporaryTables.values)
        for (final index in table.indexes) _key(index.name): index,
    };
    _temporaryViews = Map.of(savepoint.temporaryViews);
    _temporaryTriggers
      ..clear()
      ..addAll(savepoint.temporaryTriggers);
    _pendingVirtualTableDestroy
      ..clear()
      ..addAll(savepoint.pendingVirtualTableDestroy);
    _dirtyVirtualTables
      ..clear()
      ..addAll(savepoint.dirtyVirtualTables);
    final modulesRestored = _virtualTableInstances();
    for (final module in modulesBefore) {
      if (!modulesRestored.contains(module) &&
          !savepoint.pendingVirtualTableDestroy.contains(module)) {
        _disposeVirtualTable(module);
      }
    }
    if (_pager == null) _memoryPageSize = savepoint.memoryPageSize;
    _restoreTemporaryPragmas(savepoint.temporaryPragmaValues);
    _savepoints.removeRange(index + 1, _savepoints.length);
    return 0;
  }

  int _release(String name) {
    final index = _savepoints.lastIndexWhere(
      (savepoint) => _key(savepoint.name) == _key(name),
    );
    if (index < 0) throw PureSqlException('no such savepoint: $name');
    final commits = _savepoints[index].startsTransaction;
    _savepoints.removeRange(index, _savepoints.length);
    for (final attached in _attachedDatabases.values) {
      if (attached.database._savepoints.any(
        (candidate) => _key(candidate.name) == _key(name),
      )) {
        attached.database._release(name);
      }
    }
    if (commits) _commit();
    return 0;
  }

  T _journalled<T>(
    T Function() action, {
    String? journalMode,
    Map<String, _Table>? virtualTableSources,
  }) {
    final journal = SqliteRollbackJournal.begin(
      _pager!.path,
      databaseHandle: _pager!.databaseHandle,
      mode: journalMode ?? _journalMode,
      flush: _synchronous > 0,
      sizeLimit: _journalSizeLimit,
    );
    try {
      final result = action();
      if (_synchronous == 1) _pager?.syncDatabase();
      journal.commit(sizeLimit: _journalSizeLimit);
      return result;
    } catch (_) {
      journal.rollback(
        _pager!.path,
        databaseHandle: _pager!.databaseHandle,
        sizeLimit: _journalSizeLimit,
      );
      _refreshFile(virtualTableSources: virtualTableSources);
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
          final virtualTableSnapshot = _cloneVirtualTables(_tables);
          final temporaryVirtualTableSnapshot = _cloneVirtualTables(
            _temporaryTables,
          );
          pager.beginWalTransaction();
          try {
            final result = action();
            pager.commitWalTransaction();
            _finishVirtualTableDrops(commit: true);
            _dirtyVirtualTables.clear();
            return result;
          } catch (_) {
            pager.rollbackWalTransaction();
            _restoreVirtualTableSnapshots(virtualTableSnapshot);
            _restoreVirtualTableSnapshots(temporaryVirtualTableSnapshot);
            _refreshFile(virtualTableSources: virtualTableSnapshot);
            _finishVirtualTableDrops(commit: false);
            _dirtyVirtualTables.clear();
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
        final virtualTableSnapshot = _cloneVirtualTables(_tables);
        final temporaryVirtualTableSnapshot = _cloneVirtualTables(
          _temporaryTables,
        );
        try {
          final result = _journalled(
            action,
            virtualTableSources: virtualTableSnapshot,
          );
          _finishVirtualTableDrops(commit: true);
          _dirtyVirtualTables.clear();
          return result;
        } catch (_) {
          _restoreVirtualTableSnapshots(virtualTableSnapshot);
          _restoreVirtualTableSnapshots(temporaryVirtualTableSnapshot);
          _finishVirtualTableDrops(commit: false);
          _dirtyVirtualTables.clear();
          rethrow;
        }
      } finally {
        pager.releaseExclusiveLock();
      }
    }
  }

  int _changeJournalMode(_Pragma statement, List<Object?> parameters) {
    final pager = _pager!;
    final mode = _journalModeName(_pragmaInput(statement.value!, parameters));
    if (!const {
      'wal',
      'delete',
      'truncate',
      'persist',
      'memory',
      'off',
    }.contains(mode)) {
      throw PureSqlException('unsupported journal mode: $mode');
    }
    if (mode == 'wal') {
      final result = pager.withExclusiveLock(() {
        _refreshFile();
        if (pager.isWalMode) return 0;
        return _journalled(() {
          pager.enableWalMode();
          return 0;
        }, journalMode: 'delete');
      });
      _journalMode = 'wal';
      return result;
    }
    final result = pager.withExclusiveLock(() {
      _refreshFile();
      if (pager.isWalMode) pager.disableWalMode();
      _refreshFile();
      if (const {'delete', 'memory', 'off'}.contains(mode)) {
        final journal = io.File('${pager.path}-journal');
        if (journal.existsSync()) journal.deleteSync();
      }
      return 0;
    });
    _journalMode = mode;
    return result;
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

  T _withSqlFunctions<T>(T Function() action) => runZoned(
    action,
    zoneValues: {
      _sqlFunctionsZoneKey: _functions,
      _sqlAggregateFunctionsZoneKey: _aggregateFunctions,
      _sqlWindowFunctionsZoneKey: _windowFunctionCallbacks,
      _sqlCaseSensitiveLikeZoneKey: _caseSensitiveLike,
      _sqlChangesZoneKey: _changes,
      _sqlTotalChangesZoneKey: _totalChanges,
      _sqlLastInsertRowIdZoneKey: _lastInsertRowId,
      _sqlCurrentTimestampZoneKey: DateTime.now().toUtc(),
      _sqlLogZoneKey: _onLog,
    },
  );

  void _refreshFile({Map<String, _Table>? virtualTableSources}) {
    _pager!.refresh();
    _applicationId = _pager!.header.applicationId;
    _userVersion = _pager!.header.userVersion;
    _schemaVersion = _pager!.header.schemaCookie;
    final previousTables = _tables;
    final reusableTables = virtualTableSources ?? previousTables;
    _tables = {};
    _indexes = {};
    _views = {};
    _triggers = {};
    _loadFile(reusableTables);
    final retainedModules = {
      for (final table in _tables.values)
        if (table.virtualTable case final module?) module,
    };
    for (final table in {...previousTables.values, ...reusableTables.values}) {
      final module = table.virtualTable;
      if (module != null && !retainedModules.contains(module)) {
        _disposeVirtualTable(module);
      }
    }
  }

  void _refreshVirtualTableRows(_Table table) {
    final module = table.virtualTable;
    if (module == null) return;
    final ids = <int>{};
    final rows = <SqlRow>[];
    final rowIds = <int>[];
    for (final source in module.scan()) {
      if (source.rowId < -0x8000000000000000 ||
          source.rowId > 0x7fffffffffffffff ||
          !ids.add(source.rowId)) {
        throw PureSqlException('invalid or duplicate virtual-table rowid');
      }
      rows.add({
        for (final column in table.columns)
          column.name: _virtualTableValue(source.values, column.name),
      });
      rowIds.add(source.rowId);
    }
    var nextRowId = 1;
    while (ids.contains(nextRowId) && nextRowId < 0x7fffffffffffffff) {
      nextRowId++;
    }
    table.rows
      ..clear()
      ..addAll(rows);
    table.rowIds
      ..clear()
      ..addAll(rowIds);
    table.nextRowId = nextRowId;
  }

  _Table _currentTable(_Table table) {
    _refreshVirtualTableRows(table);
    return table;
  }

  Object? _virtualTableValue(SqlRow values, String column) {
    if (values.containsKey(column)) return values[column];
    for (final entry in values.entries) {
      if (_key(entry.key) == _key(column)) return entry.value;
    }
    return null;
  }

  bool _virtualRowsMatch(
    _Table table,
    SqlVirtualTable module,
    List<SqlVirtualTableRow> expected,
  ) {
    final actual = module.scan().toList();
    if (actual.length != expected.length) return false;
    final byId = {for (final row in actual) row.rowId: row};
    if (byId.length != actual.length) return false;
    for (var index = 0; index < expected.length; index++) {
      final wanted = expected[index];
      final found = byId[wanted.rowId];
      if (found == null) return false;
      for (final column in table.columns) {
        if (!_valueEqual(
          _virtualTableValue(found.values, column.name),
          wanted.values[column.name],
        )) {
          return false;
        }
      }
    }
    return true;
  }

  void _restoreVirtualTableState(
    _Table table,
    List<SqlRow> rows,
    List<int> rowIds,
  ) {
    final module = table.virtualTable;
    if (module == null) return;
    final expected = [
      for (var index = 0; index < rows.length; index++)
        SqlVirtualTableRow(
          rowIds[index],
          Map<String, Object?>.from(rows[index]),
        ),
    ];
    if (!_virtualRowsMatch(table, module, expected))
      module.replaceRows(expected);
  }

  void _restoreVirtualTableSnapshots(Map<String, _Table> snapshot) {
    for (final table in snapshot.values) {
      if (table.virtualTable case final module?
          when _dirtyVirtualTables.contains(module)) {
        _restoreVirtualTableState(table, table.rows, table.rowIds);
      }
    }
  }

  void _disposeVirtualTable(SqlVirtualTable module, {bool destroy = false}) {
    try {
      if (destroy) {
        module.destroy();
      } else {
        module.disconnect();
      }
    } catch (_) {}
  }

  Map<String, _Table> _cloneVirtualTables(Map<String, _Table> tables) => {
    for (final entry in tables.entries)
      if (entry.value.virtualTable != null) entry.key: entry.value.copy(),
  };

  void _finishVirtualTableDrops({required bool commit}) {
    final active = {
      for (final table in [..._tables.values, ..._temporaryTables.values])
        if (table.virtualTable case final module?) module,
    };
    for (final module in _pendingVirtualTableDestroy) {
      if (commit) {
        _disposeVirtualTable(module, destroy: true);
      } else if (!active.contains(module)) {
        _disposeVirtualTable(module);
      }
    }
    _pendingVirtualTableDestroy.clear();
  }

  Set<SqlVirtualTable> _virtualTableInstances() => {
    for (final table in [..._tables.values, ..._temporaryTables.values])
      if (table.virtualTable case final module?) module,
  };

  void _dropVirtualTable(_Table table) {
    final module = table.virtualTable;
    if (module == null) return;
    if (_pager == null && !_inTransaction && _transactionCallbackDepth == 0) {
      _disposeVirtualTable(module, destroy: true);
    } else if (!_pendingVirtualTableDestroy.contains(module)) {
      _pendingVirtualTableDestroy.add(module);
    }
  }

  void _ensureSequenceTable() {
    const key = 'sqlite_sequence';
    final existing = _tables[key];
    if (existing != null) {
      if (!existing.isSequenceTable) {
        throw PureSqlException('object name reserved for internal use: ' + key);
      }
      return;
    }
    const sql = 'CREATE TABLE sqlite_sequence(name,seq)';
    final pager = _pager;
    final rootPage = pager?.allocatePage();
    if (pager != null) {
      pager.writePage(
        rootPage!,
        SqliteTableBtree.emptyPage(pager.header.pageSize),
      );
      SqliteTableBtree.insertRow(pager, 1, _nextSchemaRowId(), [
        'table',
        key,
        key,
        rootPage,
        sql,
      ], pageStart: 100);
    }
    _tables[key] = _Table(
      key,
      [_ColumnDef('name'), _ColumnDef('seq')],
      rootPage: rootPage,
      schemaSql: sql,
      isSequenceTable: true,
    );
  }

  int _create(
    _CreateTable statement, {
    required String sql,
    bool internal = false,
  }) {
    final key = _key(statement.name);
    final tables = statement.temporary ? _temporaryTables : _tables;
    final indexes = statement.temporary ? _temporaryIndexes : _indexes;
    final triggers = statement.temporary ? _temporaryTriggers : _triggers;
    if (tables.containsKey(key) ||
        indexes.containsKey(key) ||
        triggers.containsKey(key) ||
        statement.temporary && _temporaryViews.containsKey(key) ||
        !statement.temporary && _views.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('table already exists: ${statement.name}');
    }
    if (key == 'sqlite_sequence' || key == 'sqlite_stat1' && !internal) {
      throw PureSqlException('object name reserved for internal use: $key');
    }
    if (statement.autoIncrementColumn != null && !statement.temporary) {
      if (key == 'sqlite_sequence') {
        throw PureSqlException('AUTOINCREMENT cannot use sqlite_sequence');
      }
      _ensureSequenceTable();
    }
    if (_pager == null || statement.temporary) {
      final table = _Table(
        statement.name,
        statement.columns,
        schemaSql: sql.trim(),
        isTemporary: statement.temporary,
        primaryKeyColumns: statement.primaryKeyColumns,
        checkExpressions: statement.checkExpressions,
        uniqueConstraints: statement.uniqueConstraints,
        foreignKeyConstraints: statement.foreignKeyConstraints,
      );
      tables[key] = table;
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
          [
            for (final column in constraints[index])
              _IndexTerm(_Column(column)),
          ],
          unique: true,
        );
        table.indexes.add(uniqueIndex);
        indexes[_key(uniqueIndex.name)] = uniqueIndex;
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
        [for (final column in columns) _IndexTerm(_Column(column))],
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

  int _createVirtualTable(
    _CreateVirtualTable statement, {
    required String sql,
  }) {
    final key = _key(statement.name);
    final tables = statement.temporary ? _temporaryTables : _tables;
    final indexes = statement.temporary ? _temporaryIndexes : _indexes;
    final triggers = statement.temporary ? _temporaryTriggers : _triggers;
    final views = statement.temporary ? _temporaryViews : _views;
    if (tables.containsKey(key) ||
        indexes.containsKey(key) ||
        triggers.containsKey(key) ||
        views.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('table already exists: ${statement.name}');
    }
    final moduleFactory = _virtualTableModules[_key(statement.module)];
    if (moduleFactory == null) {
      throw PureSqlException('no such module: ${statement.module}');
    }
    final module = moduleFactory(
      this,
      statement.temporary ? 'temp' : 'main',
      statement.name,
      statement.arguments,
      create: true,
    );
    try {
      final columns = List<String>.from(module.columns);
      final names = <String>{};
      if (columns.isEmpty) {
        throw PureSqlException(
          'virtual tables must expose at least one column',
        );
      }
      for (final column in columns) {
        if (column.isEmpty || !names.add(_key(column))) {
          throw PureSqlException('invalid virtual-table column: $column');
        }
      }
      final table = _Table(
        statement.name,
        [for (final column in columns) _ColumnDef(column)],
        rootPage: _pager == null || statement.temporary ? null : 0,
        virtualTable: module,
        schemaSql: sql.trim(),
        isTemporary: statement.temporary,
      );
      _refreshVirtualTableRows(table);
      if (_pager != null && !statement.temporary) {
        SqliteTableBtree.insertRow(_pager!, 1, _nextSchemaRowId(), [
          'table',
          statement.name,
          statement.name,
          0,
          sql.trim(),
        ], pageStart: 100);
      }
      tables[key] = table;
      return 0;
    } catch (_) {
      _disposeVirtualTable(module);
      rethrow;
    }
  }

  int _createView(_CreateView statement, {required String sql}) {
    final key = _key(statement.name);
    final views = statement.temporary ? _temporaryViews : _views;
    final nameExists = statement.temporary
        ? _temporaryTables.containsKey(key) ||
              _temporaryIndexes.containsKey(key) ||
              _temporaryTriggers.containsKey(key)
        : _tables.containsKey(key) ||
              _indexes.containsKey(key) ||
              _triggers.containsKey(key);
    if (nameExists || views.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('view already exists: ${statement.name}');
    }
    statement.schemaSql = sql.trim();
    views[key] = statement;
    final pager = _pager;
    if (pager != null && !statement.temporary) {
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

  int _createTrigger(_CreateTrigger statement, {required String sql}) {
    final key = _key(statement.name);
    final triggers = statement.temporary ? _temporaryTriggers : _triggers;
    if (triggers.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('trigger already exists: ${statement.name}');
    }
    if (key.startsWith('sqlite_')) {
      throw PureSqlException('object name reserved for internal use');
    }
    if (statement.temporary
        ? (_temporaryTables.containsKey(key) ||
              _temporaryIndexes.containsKey(key) ||
              _temporaryViews.containsKey(key))
        : (_tables.containsKey(key) ||
              _views.containsKey(key) ||
              _indexes.containsKey(key) ||
              _triggers.containsKey(key))) {
      throw PureSqlException('object already exists: ${statement.name}');
    }
    final isInsteadOf = statement.timing == 'INSTEAD OF';
    final tableKey = _key(statement.table);
    final view = !statement.temporary
        ? _views[tableKey]
        : _temporaryTables.containsKey(tableKey) ||
              _temporaryIndexes.containsKey(tableKey)
        ? null
        : _temporaryViews[tableKey] ?? _views[tableKey];
    if (isInsteadOf) {
      if (view == null) {
        throw PureSqlException(
          'cannot create INSTEAD OF trigger on table: ${statement.table}',
        );
      }
    } else if (view != null) {
      throw PureSqlException(
        'cannot create ${statement.timing} trigger on view: ${statement.table}',
      );
    }
    final table = isInsteadOf
        ? _materializeQuery(
            statement.table,
            _Cte(view!.query, view.columns),
            const [],
          )
        : statement.temporary
        ? _table(statement.table)
        : _tables[tableKey] ??
              (throw PureSqlException('no such table: ${statement.table}'));
    if (table.virtualTable != null) {
      throw PureSqlException('virtual tables cannot have triggers');
    }
    for (final column in statement.updateOf) {
      table.column(column);
    }
    if (isInsteadOf) table.isTemporary = view!.temporary;
    statement.targetTemporary = table.isTemporary;
    statement.schemaSql = sql.trim();
    triggers[key] = statement;
    final pager = _pager;
    if (pager != null && !statement.temporary) {
      SqliteTableBtree.insertRow(pager, 1, _nextSchemaRowId(), [
        'trigger',
        statement.name,
        statement.table,
        0,
        sql.trim(),
      ], pageStart: 100);
    }
    return 0;
  }

  int _renameTable(_RenameTable statement) {
    final oldKey = _key(statement.table);
    final newKey = _key(statement.newName);
    final table = _table(statement.table, schema: statement.schema);
    if (table.virtualTable != null) {
      throw PureSqlException('ALTER TABLE is not supported for virtual tables');
    }
    if (table.isTemporary) {
      return _renameTemporaryTable(table, oldKey, statement.newName);
    }
    if (_tables.containsKey(newKey) ||
        _indexes.containsKey(newKey) ||
        _views.containsKey(newKey) ||
        _triggers.containsKey(newKey) ||
        newKey.startsWith('sqlite_')) {
      throw PureSqlException('table already exists: ${statement.newName}');
    }
    final oldName = table.name;
    final oldSql = table.schemaSql;
    if (oldSql == null) throw SqliteFormatException('missing table SQL');
    final updateForeignKeys = !_legacyAlterTable || _foreignKeys;
    final renamedTableSql = _renameSqlIdentifiersAfter(
      oldSql,
      oldName,
      statement.newName,
      'table',
    );
    final newSql = updateForeignKeys
        ? _renameSqlIdentifiersAfter(
            renamedTableSql,
            oldName,
            statement.newName,
            'references',
          )
        : renamedTableSql;
    final renamedViews = <String, _CreateView>{};
    final renamedTemporaryViews = <String, _CreateView>{};
    for (final entry
        in _legacyAlterTable
            ? const <MapEntry<String, _CreateView>>[]
            : [..._views.entries, ..._temporaryViews.entries]) {
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
        (parsed.temporary ? renamedTemporaryViews : renamedViews)[entry.key] =
            parsed;
      }
    }
    final renamedTriggers = <String, _CreateTrigger>{};
    final renamedTemporaryTriggers = <String, _CreateTrigger>{};
    for (final entry in _allTriggerEntries) {
      final attached = _key(entry.value.table) == oldKey;
      if (_legacyAlterTable && !attached) continue;
      final triggerSql = entry.value.schemaSql;
      if (triggerSql == null)
        throw SqliteFormatException('missing trigger SQL');
      final renamedSql = _renameSqlIdentifiersAfter(
        triggerSql,
        oldName,
        statement.newName,
        _legacyAlterTable ? 'triggerTarget' : 'trigger',
      );
      if (renamedSql == triggerSql) continue;
      final parsed = _Parser(renamedSql).parse();
      if (parsed is! _CreateTrigger) {
        throw SqliteFormatException('invalid renamed trigger SQL');
      }
      parsed
        ..schemaSql = renamedSql
        ..targetTemporary = entry.value.targetTemporary;
      (parsed.temporary
              ? renamedTemporaryTriggers
              : renamedTriggers)[entry.key] =
          parsed;
    }

    final pager = _pager;
    if (pager != null) {
      final schemaRows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
      final updatedRows = [
        for (final row in schemaRows)
          _renameSchemaRow(
            row,
            oldName,
            statement.newName,
            newSql,
            legacyAlterTable: _legacyAlterTable,
            updateForeignKeys: updateForeignKeys,
          ),
      ];
      SqliteTableBtree.rewriteRows(pager, 1, updatedRows, pageStart: 100);
    }

    _tables.remove(oldKey);
    table.name = statement.newName;
    table.schemaSql = newSql;
    _tables[newKey] = table;
    if (table.autoIncrement) {
      final sequence = _tables['sqlite_sequence'];
      if (sequence != null) {
        for (final row in sequence.rows) {
          if (_key(row['name']?.toString() ?? '') == oldKey) {
            row['name'] = statement.newName;
          }
        }
        if (pager != null) _rewriteTable(pager, sequence);
      }
    }
    final autoIndexPrefix = 'sqlite_autoindex_${oldName}_';
    for (final index in table.indexes) {
      if (index.schemaSql case final schemaSql?) {
        index.schemaSql = _renameSqlIdentifiersAfter(
          schemaSql,
          oldName,
          statement.newName,
          'index',
        );
      }
      if (!_key(index.name).startsWith(_key(autoIndexPrefix))) continue;
      final suffix = index.name.substring(autoIndexPrefix.length);
      _indexes.remove(_key(index.name));
      index.name = 'sqlite_autoindex_${statement.newName}_$suffix';
      _indexes[_key(index.name)] = index;
    }
    for (final other in _tables.values) {
      if (updateForeignKeys) {
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
    }
    _views.addAll(renamedViews);
    _temporaryViews.addAll(renamedTemporaryViews);
    _triggers.addAll(renamedTriggers);
    _temporaryTriggers.addAll(renamedTemporaryTriggers);
    return 0;
  }

  int _renameTemporaryTable(_Table table, String oldKey, String newName) {
    final newKey = _key(newName);
    if (_temporaryTables.containsKey(newKey) ||
        _temporaryIndexes.containsKey(newKey) ||
        _temporaryViews.containsKey(newKey) ||
        _temporaryTriggers.containsKey(newKey) ||
        newKey.startsWith('sqlite_')) {
      throw PureSqlException('table already exists: $newName');
    }
    final oldName = table.name;
    final oldSql = table.schemaSql;
    if (oldSql == null) throw SqliteFormatException('missing table SQL');
    final updateForeignKeys = !_legacyAlterTable || _foreignKeys;
    final renamedTableSql = _renameSqlIdentifiersAfter(
      oldSql,
      oldName,
      newName,
      'table',
    );
    final newSql = updateForeignKeys
        ? _renameSqlIdentifiersAfter(
            renamedTableSql,
            oldName,
            newName,
            'references',
          )
        : renamedTableSql;
    final renamedViews = <String, _CreateView>{};
    for (final entry
        in _legacyAlterTable
            ? const <MapEntry<String, _CreateView>>[]
            : _temporaryViews.entries) {
      final viewSql = entry.value.schemaSql;
      if (viewSql == null) throw SqliteFormatException('missing view SQL');
      final renamedSql = _renameSqlIdentifiersAfter(
        viewSql,
        oldName,
        newName,
        'source',
      );
      if (renamedSql == viewSql) continue;
      final parsed = _Parser(renamedSql).parse();
      if (parsed is! _CreateView) {
        throw SqliteFormatException('invalid renamed view SQL');
      }
      parsed.schemaSql = renamedSql;
      renamedViews[entry.key] = parsed;
    }
    final renamedTriggers = <String, _CreateTrigger>{};
    for (final entry in _temporaryTriggers.entries) {
      final attached = _key(entry.value.table) == oldKey;
      if (_legacyAlterTable && !attached) continue;
      final triggerSql = entry.value.schemaSql;
      if (triggerSql == null) {
        throw SqliteFormatException('missing trigger SQL');
      }
      final renamedSql = _renameSqlIdentifiersAfter(
        triggerSql,
        oldName,
        newName,
        _legacyAlterTable ? 'triggerTarget' : 'trigger',
      );
      if (renamedSql == triggerSql) continue;
      final parsed = _Parser(renamedSql).parse();
      if (parsed is! _CreateTrigger) {
        throw SqliteFormatException('invalid renamed trigger SQL');
      }
      parsed
        ..schemaSql = renamedSql
        ..targetTemporary = entry.value.targetTemporary;
      renamedTriggers[entry.key] = parsed;
    }

    _temporaryTables.remove(oldKey);
    table
      ..name = newName
      ..schemaSql = newSql;
    _temporaryTables[newKey] = table;
    final autoIndexPrefix = 'sqlite_autoindex_${oldName}_';
    for (final index in table.indexes) {
      if (index.schemaSql case final schemaSql?) {
        index.schemaSql = _renameSqlIdentifiersAfter(
          schemaSql,
          oldName,
          newName,
          'index',
        );
      }
      if (!_key(index.name).startsWith(_key(autoIndexPrefix))) continue;
      final suffix = index.name.substring(autoIndexPrefix.length);
      _temporaryIndexes.remove(_key(index.name));
      index.name = 'sqlite_autoindex_${newName}_$suffix';
      _temporaryIndexes[_key(index.name)] = index;
    }
    for (final other in _temporaryTables.values) {
      if (updateForeignKeys) {
        if (other.schemaSql case final schemaSql?) {
          other.schemaSql = _renameSqlIdentifiersAfter(
            schemaSql,
            oldName,
            newName,
            'references',
          );
        }
        for (final column in other.columns) {
          if (column.referencesTable != null &&
              _key(column.referencesTable!) == oldKey) {
            column.referencesTable = newName;
          }
        }
        for (final foreignKey in other.foreignKeyConstraints) {
          if (_key(foreignKey.table) == oldKey) foreignKey.table = newName;
        }
      }
    }
    _temporaryViews.addAll(renamedViews);
    _temporaryTriggers.addAll(renamedTriggers);
    return 0;
  }

  bool _sourceHasRenameColumn(
    String sourceName,
    String columnName, {
    required bool temporary,
  }) {
    if (sourceName.contains('\u0000')) return true;
    final key = _key(sourceName);
    final table = temporary
        ? _temporaryTables[key] ?? _tables[key]
        : _tables[key];
    if (table != null) {
      return table.columns.any(
        (column) => _key(column.name) == _key(columnName),
      );
    }
    final view = temporary ? _temporaryViews[key] ?? _views[key] : _views[key];
    if (view != null) {
      return (view.columns ?? _selectColumnNames(view.query)).any(
        (column) => _key(column) == _key(columnName),
      );
    }
    // An unresolved source makes the reference potentially ambiguous.
    return true;
  }

  int _renameColumn(_RenameColumn statement) {
    final table = _table(statement.table, schema: statement.schema);
    if (table.virtualTable != null) {
      throw PureSqlException('ALTER TABLE is not supported for virtual tables');
    }
    final column = table.column(statement.oldName);
    if (table.columns.any(
      (other) => _key(other.name) == _key(statement.newName),
    )) {
      throw PureSqlException('duplicate column name: ${statement.newName}');
    }
    final renamedIndexes = <String, _Index>{};
    for (final index in table.indexes) {
      if (index.schemaSql == null ||
          !index.terms.any(
                (term) => _referencesColumn(term.expression, column.name),
              ) &&
              !(index.where != null &&
                  _referencesColumn(index.where!, column.name))) {
        continue;
      }
      final renamedSql = _renameIndexColumnToken(
        index.schemaSql!,
        column.name,
        statement.newName,
      );
      final parsedIndex = _Parser(renamedSql).parse();
      if (parsedIndex is! _CreateIndex ||
          _key(parsedIndex.name) != _key(index.name)) {
        throw SqliteFormatException('invalid renamed index SQL');
      }
      renamedIndexes[_key(index.name)] = _Index(
        parsedIndex.name,
        table,
        parsedIndex.terms,
        rootPage: index.rootPage,
        unique: parsedIndex.unique,
        where: parsedIndex.where,
        schemaSql: renamedSql,
      );
    }
    final renamedIncomingForeignKeys =
        <_Table, ({String sql, _CreateTable parsed})>{};
    for (final other in [..._tables.values, ..._temporaryTables.values]) {
      if (identical(other, table)) continue;
      final referencesRenamedColumn = _foreignKeysFor(other).any(
        (foreignKey) =>
            identical(_foreignKeyParent(other, foreignKey.table), table) &&
            foreignKey.referencedColumns.any(
              (name) => _key(name) == _key(column.name),
            ),
      );
      if (!referencesRenamedColumn) continue;
      final childSql = other.schemaSql;
      if (childSql == null) {
        throw SqliteFormatException('missing referencing table SQL');
      }
      final renamedSql = _renameForeignKeyTargetColumn(
        childSql,
        table.name,
        column.name,
        statement.newName,
      );
      final parsedChild = _Parser(renamedSql).parse();
      if (parsedChild is! _CreateTable ||
          parsedChild.columns.length != other.columns.length) {
        throw SqliteFormatException('invalid renamed foreign-key SQL');
      }
      renamedIncomingForeignKeys[other] = (
        sql: renamedSql,
        parsed: parsedChild,
      );
    }
    final renamedViews = <String, _CreateView>{};
    final renamedTemporaryViews = <String, _CreateView>{};
    for (final entry in [..._views.entries, ..._temporaryViews.entries]) {
      final view = entry.value;
      if (table.isTemporary && !view.temporary) continue;
      final viewSql = view.schemaSql;
      if (viewSql == null) throw SqliteFormatException('missing view SQL');
      bool sourceHasColumn(String sourceName) => _sourceHasRenameColumn(
        sourceName,
        column.name,
        temporary: view.temporary,
      );

      final tokens = _Tokenizer(viewSql).tokenize();
      final tokenByStart = {
        for (final token in tokens)
          if (token.start >= 0) token.start: token,
      };
      final replacements = <_Token>[];
      final visitedQueries = <_Select>{};
      var safe = true;
      late void Function(_Select query) visitQuery;
      bool referencesTable(String? name) {
        if (name == null) return false;
        final separator = name.indexOf('\u0000');
        final unqualifiedName = separator < 0
            ? name
            : name.substring(separator + 1);
        return _key(unqualifiedName) == _key(table.name);
      }

      void visitExpression(_Expr expression) {
        switch (expression) {
          case _ScalarSubquery(:final query) || _Exists(:final query):
            visitQuery(query);
          case _In(:final expression, :final values, :final query):
            if (query != null) visitQuery(query);
            visitExpression(expression);
            for (final value in values) {
              visitExpression(value);
            }
          case _Function(:final arguments, :final filter):
            for (final argument in arguments) {
              visitExpression(argument);
            }
            if (filter != null) visitExpression(filter);
          case _WindowFunction(
            :final function,
            :final partitionBy,
            :final orderBy,
          ):
            visitExpression(function);
            for (final expression in partitionBy) {
              visitExpression(expression);
            }
            for (final order in orderBy) {
              visitExpression(order.expression);
            }
          case _Binary(:final left, :final right):
            visitExpression(left);
            visitExpression(right);
          case _Unary(:final expression) || _Cast(:final expression):
            visitExpression(expression);
          case _Between(:final expression, :final lower, :final upper):
            visitExpression(expression);
            visitExpression(lower);
            visitExpression(upper);
          case _PatternMatch(:final expression, :final pattern, :final escape):
            visitExpression(expression);
            visitExpression(pattern);
            if (escape != null) visitExpression(escape);
          case _RowValue(:final values):
            for (final value in values) {
              visitExpression(value);
            }
          case _Case(:final branches, :final otherwise):
            for (final branch in branches) {
              visitExpression(branch.$1);
              visitExpression(branch.$2);
            }
            if (otherwise != null) visitExpression(otherwise);
          case _Literal() || _Param() || _Column():
            break;
        }
      }

      String? maskNestedSelects(
        _Select query,
        int segmentStart,
        String segment,
      ) {
        final nestedQueries = <_Select>{};
        void collect(_Expr expression) {
          switch (expression) {
            case _ScalarSubquery(:final query) || _Exists(:final query):
              nestedQueries.add(query);
            case _In(:final expression, :final values, :final query):
              if (query != null) nestedQueries.add(query);
              collect(expression);
              for (final value in values) {
                collect(value);
              }
            case _Function(:final arguments, :final filter):
              for (final argument in arguments) {
                collect(argument);
              }
              if (filter != null) collect(filter);
            case _WindowFunction(
              :final function,
              :final partitionBy,
              :final orderBy,
            ):
              collect(function);
              for (final expression in partitionBy) {
                collect(expression);
              }
              for (final order in orderBy) {
                collect(order.expression);
              }
            case _Binary(:final left, :final right):
              collect(left);
              collect(right);
            case _Unary(:final expression) || _Cast(:final expression):
              collect(expression);
            case _Between(:final expression, :final lower, :final upper):
              collect(expression);
              collect(lower);
              collect(upper);
            case _PatternMatch(
              :final expression,
              :final pattern,
              :final escape,
            ):
              collect(expression);
              collect(pattern);
              if (escape != null) collect(escape);
            case _RowValue(:final values):
              for (final value in values) {
                collect(value);
              }
            case _Case(:final branches, :final otherwise):
              for (final branch in branches) {
                collect(branch.$1);
                collect(branch.$2);
              }
              if (otherwise != null) collect(otherwise);
            case _Literal() || _Param() || _Column():
              break;
          }
        }

        for (final item in query.items) {
          collect(item.expression);
        }
        for (final expression in query.groupBy) {
          collect(expression);
        }
        if (query.where case final where?) collect(where);
        if (query.having case final having?) collect(having);
        for (final order in query.orderBy) {
          collect(order.expression);
        }
        if (query.limit case final limit?) collect(limit);
        if (query.offset case final offset?) collect(offset);
        for (final join in query.joins) {
          if (join.on case final on?) collect(on);
        }

        final ranges = <({int start, int end})>[];
        for (final nested in nestedQueries) {
          final start = nested.startToken;
          final end = nested.endToken;
          if (start == null ||
              end == null ||
              start <= 0 ||
              start >= end ||
              end > tokens.length - 1) {
            return null;
          }
          final openStack = <int>[];
          for (var index = 0; index < start; index++) {
            if (tokens[index].text == '(') {
              openStack.add(index);
            } else if (tokens[index].text == ')' && openStack.isNotEmpty) {
              openStack.removeLast();
            }
          }
          if (openStack.isEmpty) return null;
          final open = openStack.last;
          var depth = 0;
          var close = -1;
          for (var index = open; index < tokens.length; index++) {
            if (tokens[index].text == '(') depth++;
            if (tokens[index].text == ')' && --depth == 0) {
              close = index;
              break;
            }
          }
          if (close < end - 1) return null;
          final startOffset = tokens[open].start - segmentStart;
          final endOffset = tokens[close].end - segmentStart;
          if (startOffset < 0 || endOffset > segment.length) return null;
          ranges.add((start: startOffset, end: endOffset));
        }
        final codeUnits = segment.codeUnits.toList();
        for (final range in ranges) {
          for (var index = range.start; index < range.end; index++) {
            if (codeUnits[index] != 10 && codeUnits[index] != 13) {
              codeUnits[index] = 32;
            }
          }
        }
        return String.fromCharCodes(codeUnits);
      }

      visitQuery = (query) {
        if (!visitedQueries.add(query)) return;
        final directlyReadsTable =
            referencesTable(query.table) ||
            query.joins.any((join) => referencesTable(join.table));
        if (directlyReadsTable && _selectReferencesColumn(query, column.name)) {
          final start = query.startToken;
          final end = query.endToken;
          if (start == null ||
              end == null ||
              start < 0 ||
              start >= end ||
              end > tokens.length - 1) {
            safe = false;
          } else {
            final segmentStart = tokens[start].start;
            final segmentEnd = tokens[end - 1].end;
            final segment = viewSql.substring(segmentStart, segmentEnd);
            final scopedQuery = _Select(
              query.items,
              query.table,
              query.alias,
              query.joins,
              query.where,
              query.groupBy,
              query.having,
              query.compoundTerms.isEmpty ? query.orderBy : const [],
              query.compoundTerms.isEmpty ? query.limit : null,
              query.compoundTerms.isEmpty ? query.offset : null,
              query.distinct,
              fromQuery: query.fromQuery,
              tableFunction: query.tableFunction,
              namedWindows: query.namedWindows,
            );
            final scanSegment = maskNestedSelects(query, segmentStart, segment);
            final references = scanSegment == null
                ? (safe: false, tokens: const <_Token>[])
                : _viewColumnRenameReferences(
                    scopedQuery,
                    table.name,
                    column.name,
                    scanSegment,
                    sourceHasColumn,
                  );
            if (!references.safe) {
              safe = false;
            } else {
              for (final reference in references.tokens) {
                final token = tokenByStart[segmentStart + reference.start];
                if (token == null) {
                  safe = false;
                  break;
                }
                replacements.add(token);
              }
            }
          }
        }
        for (final cte in query.ctes.values) {
          visitQuery(cte.query);
        }
        if (query.fromQuery case final fromQuery?) visitQuery(fromQuery);
        for (final join in query.joins) {
          if (join.query case final joinedQuery?) visitQuery(joinedQuery);
          if (join.on case final on?) visitExpression(on);
        }
        for (final item in query.items) {
          visitExpression(item.expression);
        }
        if (query.where case final where?) visitExpression(where);
        for (final expression in query.groupBy) {
          visitExpression(expression);
        }
        if (query.having case final having?) visitExpression(having);
        for (final order in query.orderBy) {
          visitExpression(order.expression);
        }
        if (query.limit case final limit?) visitExpression(limit);
        if (query.offset case final offset?) visitExpression(offset);
        for (final term in query.compoundTerms) {
          visitQuery(term.query);
        }
      };

      visitQuery(view.query);
      if (!safe) {
        throw PureSqlException(
          'cannot safely rename a column referenced by a view',
        );
      }
      if (replacements.isEmpty) continue;
      final renamedSql = _replaceSqlTokens(
        viewSql,
        replacements,
        statement.newName,
      );
      final renamed = _Parser(renamedSql).parse();
      if (renamed is! _CreateView) {
        throw SqliteFormatException('invalid renamed view SQL');
      }
      renamed.schemaSql = renamedSql;
      (renamed.temporary ? renamedTemporaryViews : renamedViews)[entry.key] =
          renamed;
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
    String? rowIdColumnName;
    for (final parsedColumn in parsed.columns) {
      if (parsedColumn.primaryKey &&
          parsedColumn.typeName?.toUpperCase() == 'INTEGER') {
        rowIdColumnName = parsedColumn.name;
        break;
      }
    }
    if (rowIdColumnName == null && parsed.primaryKeyColumns.length == 1) {
      final name = parsed.primaryKeyColumns.single;
      for (final parsedColumn in parsed.columns) {
        if (_key(parsedColumn.name) == _key(name) &&
            parsedColumn.typeName?.toUpperCase() == 'INTEGER') {
          rowIdColumnName = parsedColumn.name;
          break;
        }
      }
    }
    final autoIndexColumns = <List<String>>[
      for (final parsedColumn in parsed.columns)
        if ((parsedColumn.primaryKey || parsedColumn.unique) &&
            _key(parsedColumn.name) != _key(rowIdColumnName ?? ''))
          [parsedColumn.name],
      if (parsed.primaryKeyColumns.isNotEmpty &&
          !(parsed.primaryKeyColumns.length == 1 &&
              _key(parsed.primaryKeyColumns.single) ==
                  _key(rowIdColumnName ?? '')))
        parsed.primaryKeyColumns,
      ...parsed.uniqueConstraints,
    ];
    final autoIndexes = table.indexes
        .where((index) => index.schemaSql == null)
        .toList();
    if (autoIndexes.length != autoIndexColumns.length) {
      throw SqliteFormatException('table auto-indexes do not match schema');
    }
    for (var index = 0; index < autoIndexes.length; index++) {
      final oldIndex = autoIndexes[index];
      renamedIndexes[_key(oldIndex.name)] = _Index(
        oldIndex.name,
        table,
        [for (final name in autoIndexColumns[index]) _IndexTerm(_Column(name))],
        rootPage: oldIndex.rootPage,
        unique: true,
      );
    }
    final renamedTriggers = <String, _CreateTrigger>{};
    final renamedTemporaryTriggers = <String, _CreateTrigger>{};
    for (final entry in _allTriggerEntries) {
      if (table.isTemporary && !entry.value.temporary) continue;
      final triggerSql = entry.value.schemaSql;
      if (triggerSql == null) {
        throw SqliteFormatException('missing trigger SQL');
      }
      final triggerBelongsToTable =
          entry.value.targetTemporary == table.isTemporary &&
          _key(entry.value.table) == _key(table.name);
      if (!triggerBelongsToTable &&
          !_triggerReferencesTable(triggerSql, table.name)) {
        continue;
      }
      final references = _triggerColumnReferences(
        triggerSql,
        statement.oldName,
        triggerBelongsToTable,
        entry.value,
        table.name,
        (sourceName) => _sourceHasRenameColumn(
          sourceName,
          column.name,
          temporary: entry.value.temporary,
        ),
      );
      if (!references.safe) {
        throw PureSqlException(
          'cannot safely rename a column referenced by a trigger',
        );
      }
      if (references.tokens.isEmpty) continue;
      final renamedSql = _replaceSqlTokens(
        triggerSql,
        references.tokens,
        statement.newName,
      );
      final renamed = _Parser(renamedSql).parse();
      if (renamed is! _CreateTrigger) {
        throw SqliteFormatException('invalid renamed trigger SQL');
      }
      renamed
        ..schemaSql = renamedSql
        ..targetTemporary = entry.value.targetTemporary;
      (renamed.temporary
              ? renamedTemporaryTriggers
              : renamedTriggers)[entry.key] =
          renamed;
    }
    final before = _snapshotRows();
    final oldColumns = List<_ColumnDef>.from(table.columns);
    final oldPrimaryKeyColumns = table.primaryKeyColumns;
    final oldChecks = table.checkExpressions;
    final oldUniqueConstraints = table.uniqueConstraints;
    final oldForeignKeyConstraints = table.foreignKeyConstraints;
    final oldIndexes = List<_Index>.from(table.indexes);
    final oldIncomingStates =
        <_Table, (List<_ColumnDef>, List<_ForeignKey>, String?)>{};
    for (final child in renamedIncomingForeignKeys.keys) {
      oldIncomingStates[child] = (
        List<_ColumnDef>.from(child.columns),
        [
          for (final foreignKey in child.foreignKeyConstraints)
            foreignKey.copy(),
        ],
        child.schemaSql,
      );
    }
    try {
      for (final row in table.rows) {
        final previous = Map<String, Object?>.from(row);
        row
          ..clear()
          ..addAll({
            for (var index = 0; index < parsed.columns.length; index++)
              parsed.columns[index].name: previous[oldColumns[index].name],
          });
      }
      table.columns
        ..clear()
        ..addAll(parsed.columns);
      table
        ..primaryKeyColumns = List<String>.from(parsed.primaryKeyColumns)
        ..checkExpressions = List<_Expr>.from(parsed.checkExpressions)
        ..uniqueConstraints = [
          for (final columns in parsed.uniqueConstraints)
            List<String>.from(columns),
        ]
        ..foreignKeyConstraints = [
          for (final foreignKey in parsed.foreignKeyConstraints)
            foreignKey.copy(),
        ];
      for (final entry in renamedIncomingForeignKeys.entries) {
        entry.key.columns
          ..clear()
          ..addAll(entry.value.parsed.columns);
        entry.key
          ..foreignKeyConstraints = [
            for (final foreignKey in entry.value.parsed.foreignKeyConstraints)
              foreignKey.copy(),
          ]
          ..schemaSql = entry.value.sql;
      }
      table.schemaSql = newSql;
      table.indexes
        ..clear()
        ..addAll([
          for (final index in oldIndexes)
            renamedIndexes[_key(index.name)] ?? index,
        ]);
      final pager = _pager;
      if (pager != null && !table.isTemporary) {
        _rewriteTable(pager, table);
        _rewriteIndexes(pager, table);
        final schemaRows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
        SqliteTableBtree.rewriteRows(pager, 1, [
          for (final row in schemaRows)
            if (row.values.length >= 5 &&
                row.values[0] == 'table' &&
                _key(row.values[1].toString()) == _key(table.name))
              SqliteBtreeRow(row.rowId, [...row.values]..[4] = newSql)
            else if (row.values.length >= 5 &&
                row.values[0] == 'trigger' &&
                renamedTriggers.containsKey(_key(row.values[1].toString())))
              SqliteBtreeRow(
                row.rowId,
                [...row.values]
                  ..[4] = renamedTriggers[_key(row.values[1].toString())]!
                      .schemaSql,
              )
            else if (row.values.length >= 5 &&
                row.values[0] == 'index' &&
                renamedIndexes.containsKey(_key(row.values[1].toString())))
              SqliteBtreeRow(
                row.rowId,
                [...row.values]
                  ..[4] =
                      renamedIndexes[_key(row.values[1].toString())]!.schemaSql,
              )
            else if (row.values.length >= 5 &&
                row.values[0] == 'view' &&
                renamedViews.containsKey(_key(row.values[1].toString())))
              SqliteBtreeRow(
                row.rowId,
                [...row.values]
                  ..[4] =
                      renamedViews[_key(row.values[1].toString())]!.schemaSql,
              )
            else
              row,
        ], pageStart: 100);
      }
      if (pager != null && renamedIncomingForeignKeys.isNotEmpty) {
        final incomingMainSchema = {
          for (final entry in renamedIncomingForeignKeys.entries)
            if (!entry.key.isTemporary) _key(entry.key.name): entry.value.sql,
        };
        final schemaRows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
        SqliteTableBtree.rewriteRows(pager, 1, [
          for (final row in schemaRows)
            if (row.values.length >= 5 &&
                row.values[0] == 'table' &&
                incomingMainSchema.containsKey(_key(row.values[1].toString())))
              SqliteBtreeRow(
                row.rowId,
                [...row.values]
                  ..[4] = incomingMainSchema[_key(row.values[1].toString())],
              )
            else
              row,
        ], pageStart: 100);
      }
      _triggers.addAll(renamedTriggers);
      _temporaryTriggers.addAll(renamedTemporaryTriggers);
    } catch (_) {
      table.columns
        ..clear()
        ..addAll(oldColumns);
      table
        ..primaryKeyColumns = oldPrimaryKeyColumns
        ..checkExpressions = oldChecks
        ..uniqueConstraints = oldUniqueConstraints
        ..foreignKeyConstraints = oldForeignKeyConstraints;
      for (final entry in oldIncomingStates.entries) {
        entry.key.columns
          ..clear()
          ..addAll(entry.value.$1);
        entry.key
          ..foreignKeyConstraints = entry.value.$2
          ..schemaSql = entry.value.$3;
      }
      table.indexes
        ..clear()
        ..addAll(oldIndexes);
      table.schemaSql = oldSql;
      _restoreRows(before);
      rethrow;
    }
    (table.isTemporary ? _temporaryIndexes : _indexes).addAll(renamedIndexes);
    _views.addAll(renamedViews);
    _temporaryViews.addAll(renamedTemporaryViews);
    return 0;
  }

  int _dropColumn(_DropColumn statement) {
    final table = _table(statement.table, schema: statement.schema);
    if (table.virtualTable != null) {
      throw PureSqlException('ALTER TABLE is not supported for virtual tables');
    }
    final column = table.column(statement.name);
    for (final trigger in _allTriggers) {
      if (table.isTemporary && !trigger.temporary) continue;
      final triggerSql = trigger.schemaSql;
      if (triggerSql == null) {
        throw SqliteFormatException('missing trigger SQL');
      }
      final triggerBelongsToTable =
          trigger.targetTemporary == table.isTemporary &&
          _key(trigger.table) == _key(table.name);
      if (!triggerBelongsToTable &&
          !_triggerReferencesTable(triggerSql, table.name)) {
        continue;
      }
      final references = _triggerColumnReferences(
        triggerSql,
        column.name,
        triggerBelongsToTable,
        trigger,
        table.name,
        (sourceName) => _sourceHasRenameColumn(
          sourceName,
          column.name,
          temporary: trigger.temporary,
        ),
      );
      if (!references.safe || references.tokens.isNotEmpty) {
        throw PureSqlException('cannot drop a column referenced by a trigger');
      }
    }
    final indexed = table.indexes.any(
      (index) =>
          index.terms.any(
            (term) => _referencesColumn(term.expression, column.name),
          ) ||
          index.where != null && _referencesColumn(index.where!, column.name),
    );
    final constrained =
        table.primaryKeyColumns.any(
          (name) => _key(name) == _key(column.name),
        ) ||
        table.checkExpressions.any(
          (expression) => _referencesColumn(expression, column.name),
        ) ||
        table.uniqueConstraints.any(
          (columns) => columns.any((name) => _key(name) == _key(column.name)),
        ) ||
        table.foreignKeyConstraints.any(
          (foreignKey) =>
              foreignKey.columns.any((name) => _key(name) == _key(column.name)),
        ) ||
        table.columns.any(
          (item) =>
              item != column &&
              item.checkExpressions.any(
                (expression) => _referencesColumn(expression, column.name),
              ),
        );
    if (table.columns.length == 1 ||
        table.rowIdColumn == column ||
        indexed ||
        constrained ||
        column.primaryKey ||
        column.unique ||
        column.checkExpressions.isNotEmpty ||
        column.referencesTable != null) {
      throw PureSqlException(
        'cannot drop a column with indexes or constraints',
      );
    }
    for (final child in [..._tables.values, ..._temporaryTables.values]) {
      for (final foreignKey in _foreignKeysFor(child)) {
        if (identical(_foreignKeyParent(child, foreignKey.table), table) &&
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
    final oldPrimaryKeyColumns = table.primaryKeyColumns;
    final oldChecks = table.checkExpressions;
    final oldUniqueConstraints = table.uniqueConstraints;
    final oldForeignKeyConstraints = table.foreignKeyConstraints;
    try {
      table.columns
        ..clear()
        ..addAll(parsed.columns);
      table
        ..primaryKeyColumns = List<String>.from(parsed.primaryKeyColumns)
        ..checkExpressions = List<_Expr>.from(parsed.checkExpressions)
        ..uniqueConstraints = [
          for (final columns in parsed.uniqueConstraints)
            List<String>.from(columns),
        ]
        ..foreignKeyConstraints = [
          for (final foreignKey in parsed.foreignKeyConstraints)
            foreignKey.copy(),
        ];
      for (final row in table.rows) {
        row.remove(column.name);
      }
      table.schemaSql = newSql;
      final pager = _pager;
      if (pager != null && !table.isTemporary) {
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
      table
        ..primaryKeyColumns = oldPrimaryKeyColumns
        ..checkExpressions = oldChecks
        ..uniqueConstraints = oldUniqueConstraints
        ..foreignKeyConstraints = oldForeignKeyConstraints
        ..schemaSql = oldSql;
      _restoreRows(before);
      rethrow;
    }
    return 0;
  }

  SqliteBtreeRow _renameSchemaRow(
    SqliteBtreeRow row,
    String oldName,
    String newName,
    String renamedTableSql, {
    required bool legacyAlterTable,
    required bool updateForeignKeys,
  }) {
    if (row.values.length < 5) return row;
    final values = List<Object?>.from(row.values);
    final type = values[0];
    if (type == 'table' && values[4] is String) {
      final rowName = values[1]?.toString() ?? '';
      values[4] = _key(rowName) == _key(oldName)
          ? renamedTableSql
          : updateForeignKeys
          ? _renameSqlIdentifiersAfter(
              values[4] as String,
              oldName,
              newName,
              'references',
            )
          : values[4];
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
    } else if (!legacyAlterTable && type == 'view' && values[4] is String) {
      values[4] = _renameSqlIdentifiersAfter(
        values[4] as String,
        oldName,
        newName,
        'source',
      );
    } else if (type == 'trigger') {
      final attached = _key(values[2]?.toString() ?? '') == _key(oldName);
      if (attached) {
        values[2] = newName;
      }
      if (values[4] is String && (!legacyAlterTable || attached)) {
        values[4] = _renameSqlIdentifiersAfter(
          values[4] as String,
          oldName,
          newName,
          legacyAlterTable ? 'triggerTarget' : 'trigger',
        );
      }
    }
    return SqliteBtreeRow(row.rowId, values);
  }

  int _alterTable(_AlterTable statement, {required String sql}) {
    final table = _table(statement.table, schema: statement.schema);
    if (table.virtualTable != null) {
      throw PureSqlException('ALTER TABLE is not supported for virtual tables');
    }
    final column = statement.column;
    final defaultExpression = column.defaultExpression;
    final defaultIsNull =
        defaultExpression == null ||
        defaultExpression is _Literal && defaultExpression.value == null;
    if (column.primaryKey || column.unique || column.autoIncrement) {
      throw PureSqlException('cannot add a PRIMARY KEY or UNIQUE column');
    }
    try {
      table.column(column.name);
      throw PureSqlException('duplicate column name: ${column.name}');
    } on PureSqlException catch (error) {
      if (!error.message.startsWith('no such column:')) rethrow;
    }
    if (column.notNull && table.rows.isNotEmpty && defaultIsNull) {
      throw PureSqlException(
        'cannot add a NOT NULL column with existing null values',
      );
    }
    if (column.defaultExpression != null &&
        column.defaultExpression is! _Literal) {
      throw PureSqlException('cannot add a column with non-constant default');
    }
    if (_foreignKeys && column.referencesTable != null && !defaultIsNull) {
      throw PureSqlException(
        'cannot add a REFERENCES column with non-NULL default value',
      );
    }
    final defaultValue = defaultExpression == null
        ? null
        : _eval(defaultExpression, const {}, const []);
    if (!_ignoreCheckConstraints) {
      for (final row in table.rows) {
        final candidate = {...row, column.name: defaultValue};
        for (final check in column.checkExpressions) {
          final value = _eval(check, candidate, const []);
          if (value != null && !_truthy(value)) {
            throw PureSqlException(
              'CHECK constraint failed: ${table.name}.${column.name}',
            );
          }
        }
      }
    }
    table.columns.add(column);
    for (final row in table.rows) {
      row[column.name] = defaultValue;
    }
    final oldSql = table.schemaSql;
    if (oldSql == null) throw SqliteFormatException('missing table SQL');
    final close = oldSql.lastIndexOf(')');
    if (close < 0) throw SqliteFormatException('invalid CREATE TABLE SQL');
    table.schemaSql =
        '${oldSql.substring(0, close)}, ${statement.definitionSql})';
    final pager = _pager;
    if (pager != null && !table.isTemporary) {
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

  int _analyze(_Analyze statement) {
    final targetName = statement.target;
    final schema = statement.schema == null ? null : _key(statement.schema!);
    if (schema != null && schema != 'main' && schema != 'temp') {
      throw PureSqlException('no such database: ${statement.schema}');
    }
    _Table? targetTable;
    _Index? targetIndex;
    var temporary = schema == 'temp';
    if (targetName == null) {
      // A schema-only ANALYZE covers that schema; unqualified ANALYZE covers main.
    } else if (schema != 'main' &&
        _temporaryTables.containsKey(_key(targetName))) {
      targetTable = _temporaryTables[_key(targetName)];
      temporary = true;
    } else if (schema != 'temp' && _tables.containsKey(_key(targetName))) {
      targetTable = _tables[_key(targetName)];
    } else if (schema != 'main' &&
        _temporaryIndexes.containsKey(_key(targetName))) {
      targetIndex = _temporaryIndexes[_key(targetName)];
      targetTable = targetIndex!.table;
      temporary = true;
    } else if (schema != 'temp' && _indexes.containsKey(_key(targetName))) {
      targetIndex = _indexes[_key(targetName)];
      targetTable = targetIndex!.table;
    }
    if (targetName != null && targetTable == null) {
      throw PureSqlException('no such table: $targetName');
    }

    final statsTable = temporary
        ? _temporaryTables[_key('sqlite_stat1')]
        : _tables[_key('sqlite_stat1')];
    final stats = statsTable ?? _createAnalyzeStatsTable(temporary);
    final remove = targetName == null
        ? (_) => true
        : targetIndex != null
        ? (SqlRow row) =>
              _key(row['idx']?.toString() ?? '') == _key(targetIndex!.name)
        : (SqlRow row) =>
              _key(row['tbl']?.toString() ?? '') == _key(targetTable!.name);
    for (var index = stats.rows.length - 1; index >= 0; index--) {
      if (remove(stats.rows[index])) {
        stats.rows.removeAt(index);
        stats.rowIds.removeAt(index);
      }
    }

    final tables = targetTable == null
        ? (temporary ? _temporaryTables.values : _tables.values).where(
            (table) => !_key(table.name).startsWith('sqlite_'),
          )
        : [targetTable];
    for (final table in tables) {
      final indexes = targetIndex == null ? table.indexes : [targetIndex];
      if (indexes.isEmpty) {
        if (table.rows.isNotEmpty) {
          _appendAnalyzeStat(stats, table.name, null, '${table.rows.length}');
        }
        continue;
      }
      for (final index in indexes) {
        final stat = _indexStatistics(index);
        if (stat != null)
          _appendAnalyzeStat(stats, table.name, index.name, stat);
      }
    }
    if (!temporary && _pager != null) _rewriteTable(_pager!, stats);
    return 0;
  }

  int _vacuum(_Vacuum statement, List<Object?> parameters) {
    if (_inTransaction) {
      throw PureSqlException('cannot VACUUM from within a transaction');
    }
    final schema = statement.schema == null ? 'main' : _key(statement.schema!);
    if (schema != 'main' && schema != 'temp') {
      throw PureSqlException('no such database: ${statement.schema}');
    }
    if (statement.into != null) {
      if (schema != 'main') {
        throw PureSqlException('VACUUM INTO supports only the main schema');
      }
      return _vacuumInto(statement.into!, parameters);
    }
    final pager = _pager;
    if (pager == null || schema == 'temp') return 0;

    final oldSchemaRows = SqliteTableBtree.readTree(pager, 1, pageStart: 100);
    pager.resetForVacuum();
    _rewriteVacuum(pager, oldSchemaRows, publish: true);
    return 0;
  }

  int _reindex(_Reindex statement) {
    final schema = statement.schema == null ? null : _key(statement.schema!);
    if (schema != null) return _reindexSchema(statement.target, schema);

    final target = statement.target;
    if (target == null) {
      _reindexSchema(null, 'temp');
      _reindexSchema(null, 'main');
      for (final attached in _attachedDatabases.values) {
        _executeOnAttachedDatabase(
          attached,
          _Reindex(null, schema: 'main'),
          const [],
          'REINDEX',
        );
      }
      return 0;
    }

    // Collation names take precedence over table and index names in SQLite.
    final collation = _key(target);
    if (const {'binary', 'nocase'}.contains(collation)) {
      _reindexSchema(target, 'temp');
      _reindexSchema(target, 'main');
      for (final attached in _attachedDatabases.values) {
        _executeOnAttachedDatabase(
          attached,
          _Reindex(target, schema: 'main'),
          const [],
          'REINDEX $target',
        );
      }
      return 0;
    }

    if (_reindexTargetInSchema(target, 'temp')) return 0;
    if (_reindexTargetInSchema(target, 'main')) return 0;
    for (final attached in _attachedDatabases.values) {
      if (_attachedHasReindexTarget(attached.database, target)) {
        _executeOnAttachedDatabase(
          attached,
          _Reindex(target, schema: 'main'),
          const [],
          'REINDEX $target',
        );
        return 0;
      }
    }
    throw PureSqlException('no such collation sequence: $target');
  }

  int _reindexSchema(String? target, String schema) {
    if (schema != 'main' && schema != 'temp') {
      throw PureSqlException('no such database: $schema');
    }
    final indexes = schema == 'temp' ? _temporaryIndexes : _indexes;
    final tables = schema == 'temp' ? _temporaryTables : _tables;
    Iterable<_Index> selected;
    if (target == null) {
      selected = indexes.values;
    } else if (const {'binary', 'nocase'}.contains(_key(target))) {
      selected = indexes.values.where(
        (index) => index.terms.any(
          (term) =>
              _indexTermCollation(index.table, term) ==
              _key(target).toUpperCase(),
        ),
      );
    } else {
      final key = _key(target);
      final index = indexes[key];
      if (index != null) {
        selected = [index];
      } else {
        final table = tables[key];
        if (table == null) {
          throw PureSqlException('no such collation sequence: $target');
        }
        selected = table.indexes;
      }
    }
    for (final index in selected.toList()) {
      _validateIndexRows(index, index.table.rows);
      final pager = _pager;
      final rootPage = index.rootPage;
      if (pager != null && schema == 'main' && rootPage != null) {
        SqliteIndexBtree.rewriteRows(
          pager,
          rootPage,
          _indexEntries(index),
          compare: (left, right) => _compareIndexEntries(index, left, right),
        );
      }
    }
    return 0;
  }

  bool _reindexTargetInSchema(String target, String schema) {
    final indexes = schema == 'temp' ? _temporaryIndexes : _indexes;
    final tables = schema == 'temp' ? _temporaryTables : _tables;
    final index = indexes[_key(target)];
    if (index != null) {
      _reindexSchema(target, schema);
      return true;
    }
    final table = tables[_key(target)];
    if (table != null) {
      _reindexSchema(target, schema);
      return true;
    }
    return false;
  }

  bool _attachedHasReindexTarget(PureDatabase database, String target) =>
      database._indexes.containsKey(_key(target)) ||
      database._tables.containsKey(_key(target));

  int _vacuumInto(_Expr expression, List<Object?> parameters) {
    final sourcePager = _pager;
    final sourceHeader =
        sourcePager?.header ??
        SqliteDatabaseHeader(
          pageSize: _memoryPageSize,
          schemaCookie: _schemaVersion,
          userVersion: _userVersion,
          applicationId: _applicationId,
          defaultCacheSize: _defaultCacheSize,
        );
    final destination = _eval(expression, const {}, parameters);
    if (destination == null || destination.toString().isEmpty) {
      throw PureSqlException('VACUUM INTO requires a non-empty filename');
    }
    final output = io.File(destination.toString()).absolute;
    if (sourcePager != null && output.path == sourcePager.path) {
      throw PureSqlException('output file already exists');
    }
    final existed = output.existsSync();
    if (existed && output.lengthSync() != 0) {
      throw PureSqlException('output file already exists');
    }

    SqlitePagerSync? destinationPager;
    try {
      destinationPager = SqlitePagerSync.open(
        output.path,
        pageSize: sourceHeader.pageSize,
      );
      final schemaRows = sourcePager == null
          ? _memorySchemaRows()
          : SqliteTableBtree.readTree(sourcePager, 1, pageStart: 100);
      destinationPager.withExclusiveLock(() {
        destinationPager!.resetForVacuumFrom(sourceHeader);
        _rewriteVacuum(destinationPager, schemaRows, publish: false);
      });
      destinationPager.close();
      return 0;
    } catch (_) {
      destinationPager?.close();
      if (!existed && output.existsSync()) output.deleteSync();
      rethrow;
    }
  }

  List<SqliteBtreeRow> _memorySchemaRows() {
    final rows = <SqliteBtreeRow>[];
    var rowId = 1;
    void add(String type, String name, String table, String? sql) {
      rows.add(SqliteBtreeRow(rowId++, [type, name, table, 0, sql]));
    }

    for (final table in _tables.values) {
      add('table', table.name, table.name, table.schemaSql);
    }
    for (final index in _indexes.values) {
      add('index', index.name, index.table.name, index.schemaSql);
    }
    for (final view in _views.values) {
      add('view', view.name, view.name, view.schemaSql);
    }
    for (final trigger in _triggers.values) {
      add('trigger', trigger.name, trigger.table, trigger.schemaSql);
    }
    return rows;
  }

  void _rewriteVacuum(
    SqlitePagerSync pager,
    List<SqliteBtreeRow> oldSchemaRows, {
    required bool publish,
  }) {
    final tables = {
      for (final entry in _tables.entries) entry.key: entry.value.copy(),
    };
    final indexes = {
      for (final table in tables.values)
        for (final index in table.indexes) _key(index.name): index,
    };

    final schemaRows = <SqliteBtreeRow>[];
    for (final row in oldSchemaRows) {
      final values = List<Object?>.from(row.values);
      if (values.length >= 5 && values[0] == 'table') {
        final table = tables[_key(values[1].toString())];
        if (table != null && table.virtualTable == null) {
          final rootPage = pager.allocatePage();
          table.rootPage = rootPage;
          pager.writePage(
            rootPage,
            SqliteTableBtree.emptyPage(pager.header.pageSize),
          );
          _rewriteTable(pager, table);
          values[3] = rootPage;
        }
      } else if (values.length >= 5 && values[0] == 'index') {
        final index = indexes[_key(values[1].toString())];
        if (index != null) {
          final rootPage = pager.allocatePage();
          index.rootPage = rootPage;
          pager.writePage(
            rootPage,
            SqliteIndexBtree.emptyPage(pager.header.pageSize),
          );
          SqliteIndexBtree.rewriteRows(
            pager,
            rootPage,
            _indexEntries(index),
            compare: (left, right) => _compareIndexEntries(index, left, right),
          );
          values[3] = rootPage;
        }
      }
      schemaRows.add(SqliteBtreeRow(row.rowId, values));
    }
    SqliteTableBtree.rewriteRows(pager, 1, schemaRows, pageStart: 100);
    if (publish) {
      _tables = tables;
      _indexes = indexes;
    }
  }

  _Table _createAnalyzeStatsTable(bool temporary) {
    const sql = 'CREATE TABLE sqlite_stat1(tbl,idx,stat)';
    _create(
      _CreateTable(
        'sqlite_stat1',
        [_ColumnDef('tbl'), _ColumnDef('idx'), _ColumnDef('stat')],
        false,
        temporary: temporary,
      ),
      sql: sql,
      internal: true,
    );
    return temporary
        ? _temporaryTables['sqlite_stat1']!
        : _tables['sqlite_stat1']!;
  }

  String? _indexStatistics(_Index index) {
    final rows = [
      for (final row in index.table.rows)
        if (index.where == null || _truthy(_eval(index.where!, row, const [])))
          row,
    ];
    if (rows.isEmpty) return null;
    // ponytail: bounded sample after materializing entries; stream the B-tree
    // if ANALYZE becomes a measured I/O bottleneck.
    final sampleRows = _analysisLimit > 0 && rows.length > _analysisLimit
        ? _sampleAnalyzeRows(index, rows, _analysisLimit)
        : rows;
    final values = <int>[rows.length];
    // ponytail: exact prefix grouping is quadratic; sort-and-group if ANALYZE becomes a hot path.
    for (var length = 1; length <= index.terms.length; length++) {
      final prefixes = <List<Object?>>[];
      for (final row in sampleRows) {
        final prefix = [
          for (final term in index.terms.take(length))
            _eval(term.expression, row, const []),
        ];
        final found = prefixes.any((existing) {
          for (var position = 0; position < length; position++) {
            if (_compare(
                  existing[position],
                  prefix[position],
                  noCase:
                      _indexTermCollation(index.table, index.terms[position]) ==
                      'NOCASE',
                ) !=
                0) {
              return false;
            }
          }
          return true;
        });
        if (!found) prefixes.add(prefix);
      }
      values.add((sampleRows.length + prefixes.length - 1) ~/ prefixes.length);
    }
    return values.join(' ');
  }

  List<SqlRow> _sampleAnalyzeRows(_Index index, List<SqlRow> rows, int limit) {
    final entries =
        [
          for (final row in rows)
            (
              row: row,
              key: [
                for (final term in index.terms)
                  _eval(term.expression, row, const []),
              ],
            ),
        ]..sort((left, right) {
          for (var position = 0; position < index.terms.length; position++) {
            final term = index.terms[position];
            final comparison = _compare(
              left.key[position],
              right.key[position],
              noCase: _indexTermCollation(index.table, term) == 'NOCASE',
            );
            if (comparison != 0) {
              return term.descending ? -comparison : comparison;
            }
          }
          return 0;
        });
    final sample = entries.take(limit).toList();
    if (sample.length == limit && entries.length > limit) {
      final firstKey = sample.first.key.first;
      final collation =
          _indexTermCollation(index.table, index.terms.first) == 'NOCASE';
      if (sample.every(
        (entry) => _compare(entry.key.first, firstKey, noCase: collation) == 0,
      )) {
        final nextGroup = entries.indexWhere(
          (entry) =>
              _compare(entry.key.first, firstKey, noCase: collation) != 0,
        );
        if (nextGroup >= 0) {
          sample.addAll(entries.skip(nextGroup).take(limit));
        }
      }
    }
    return [for (final entry in sample) entry.row];
  }

  void _appendAnalyzeStat(
    _Table stats,
    String table,
    String? index,
    String value,
  ) {
    stats.rows.add({'tbl': table, 'idx': index, 'stat': value});
    stats.rowIds.add(stats.nextRowId++);
  }

  int _pragmaTemporary(_Pragma statement, List<Object?> parameters) {
    final name = _key(statement.name);
    final expression = statement.value;
    if (expression == null) return 0;
    final value = _pragmaInput(expression, parameters);
    switch (name) {
      case 'application_id':
      case 'schema_version':
        final version = _asInt(value);
        if (version < 0 || version > 0xffffffff) {
          throw PureSqlException('$name must be an unsigned 32-bit integer');
        }
        _temporaryPragmaValues[name] = version;
        _temporaryPragmaValues['page_size_locked'] = true;
      case 'user_version':
        final version = _asInt(value);
        if (version < 0) {
          throw PureSqlException('user_version must not be negative');
        }
        _temporaryPragmaValues[name] = version;
        _temporaryPragmaValues['page_size_locked'] = true;
      case 'cache_size':
      case 'journal_size_limit':
        _temporaryPragmaValues[name] = _asInt(value);
      case 'secure_delete':
        final mode = _secureDeleteInput(value);
        if (mode != null) _temporaryPragmaValues[name] = mode;
      case 'default_cache_size':
        final pageCount = _asInt(value).abs();
        if (pageCount > 0x7fffffff) {
          throw PureSqlException(
            'default_cache_size must fit a signed 32-bit page count',
          );
        }
        _temporaryPragmaValues[name] = pageCount;
        _temporaryPragmaValues['cache_size'] = pageCount;
        _temporaryPragmaValues['page_size_locked'] = true;
      case 'max_page_count':
        final requested = _asInt(value);
        if (requested > 0) {
          _temporaryPragmaValues[name] = math
              .min(requested, 1073741823)
              .toInt();
        }
      case 'page_size':
        final pageSize = _asInt(value);
        if (_temporaryPragmaValues['page_size_locked'] != true &&
            SqlitePagerSync.isValidPageSize(pageSize)) {
          _temporaryPragmaValues[name] = pageSize;
        }
      case 'synchronous':
        if (_inTransaction) {
          throw PureSqlException(
            'Safety level may not be changed inside a transaction',
          );
        }
        // TEMP databases are always synchronous=OFF; SQLite ignores writes.
        return 0;
      case 'journal_mode':
        final mode = _journalModeName(value);
        if (const {
          'delete',
          'truncate',
          'persist',
          'memory',
          'off',
        }.contains(mode)) {
          _temporaryPragmaValues[name] = mode;
        }
    }
    return 0;
  }

  int _pragma(_Pragma statement, List<Object?> parameters) {
    final name = _key(statement.name);
    if (name == 'shrink_memory') return 0;
    if (name == 'wal_checkpoint') {
      _walCheckpointRows(statement, parameters);
      return 0;
    }
    final expression = statement.value;
    if (expression == null || !_writablePragmaNames.contains(name)) return 0;
    final value = _pragmaInput(expression, parameters);
    if (name == 'analysis_limit') {
      final limit = _asInt(value);
      if (limit >= 0) _analysisLimit = limit;
      return 0;
    }
    if (name == 'automatic_index') {
      _automaticIndex = _truthy(value);
      return 0;
    }
    if (name == 'threads') {
      final requested = _asInt(value);
      if (requested >= 0) _threads = math.min(requested, 8).toInt();
      return 0;
    }
    if (name == 'mmap_size') return 0;
    if (name == 'secure_delete') {
      final mode = _secureDeleteInput(value);
      if (mode == null) return 0;
      _setSecureDeleteMode(mode);
      if (statement.schema == null) {
        _temporaryPragmaValues['secure_delete'] = mode;
        for (final attached in _attachedDatabases.values) {
          attached.database._setSecureDeleteMode(mode);
        }
      }
      return 0;
    }
    if (name == 'count_changes') {
      _countChanges = _truthy(value);
      return 0;
    }
    if (name == 'full_column_names') {
      _fullColumnNames = _truthy(value);
      return 0;
    }
    if (name == 'short_column_names') {
      _shortColumnNames = _truthy(value);
      return 0;
    }
    if (name == 'temp_store') {
      final requested = switch (value) {
        String text => switch (text.toUpperCase()) {
          'DEFAULT' => 0,
          'FILE' => 1,
          'MEMORY' => 2,
          _ => int.tryParse(text) ?? -1,
        },
        num number => number.isFinite ? number.toInt() : -1,
        _ => -1,
      };
      if (requested < 0 || requested > 2 || requested == _tempStore) {
        return 0;
      }
      if (_inTransaction || _transactionCallbackDepth > 0) {
        throw PureSqlException(
          'temporary storage cannot be changed from within a transaction',
        );
      }
      _tempStore = requested;
      _temporaryTables.clear();
      _temporaryIndexes.clear();
      _temporaryViews.clear();
      _temporaryTriggers.clear();
      _temporaryPragmaValues
        ..clear()
        ..addAll(_defaultTemporaryPragmaValues);
      return 0;
    }
    if (name == 'wal_autocheckpoint') {
      final limit = _asInt(value);
      _walAutoCheckpoint = limit > 0 ? limit : 0;
      if (_pager != null) _pager!.walAutoCheckpointPages = _walAutoCheckpoint;
      return 0;
    }
    if (name == 'journal_size_limit') {
      _journalSizeLimit = _asInt(value);
      if (_pager != null) _pager!.journalSizeLimit = _journalSizeLimit;
      return 0;
    }
    if (name == 'default_cache_size') {
      final requested = _asInt(value);
      final pageCount = requested.abs();
      if (pageCount > 0x7fffffff) {
        throw PureSqlException(
          'default_cache_size must fit a signed 32-bit page count',
        );
      }
      _defaultCacheSize = pageCount;
      _cacheSize = pageCount;
      final pager = _pager;
      if (pager != null) {
        pager.header.defaultCacheSize = pageCount;
        pager.writePage(1, pager.readPage(1));
      }
      return 0;
    }
    if (name == 'foreign_keys') {
      if (!_inTransaction) _foreignKeys = _truthy(value);
      return 0;
    }
    if (name == 'defer_foreign_keys') {
      _deferForeignKeys = _truthy(value);
      return 0;
    }
    if (name == 'recursive_triggers') {
      _recursiveTriggers = _truthy(value);
      return 0;
    }
    if (name == 'ignore_check_constraints') {
      _ignoreCheckConstraints = _truthy(value);
      return 0;
    }
    if (name == 'query_only') {
      _queryOnly = _readOnly || _truthy(value);
      return 0;
    }
    if (name == 'read_uncommitted') {
      _readUncommitted = _truthy(value);
      return 0;
    }
    if (name == 'case_sensitive_like') {
      _caseSensitiveLike = _truthy(value);
      return 0;
    }
    if (name == 'legacy_alter_table') {
      _legacyAlterTable = _truthy(value);
      return 0;
    }
    if (name == 'reverse_unordered_selects') {
      _reverseUnorderedSelects = _truthy(value);
      return 0;
    }
    if (name == 'busy_timeout') {
      final milliseconds = _asInt(value);
      if (milliseconds < 0) {
        throw PureSqlException('busy_timeout must not be negative');
      }
      _busyTimeout = Duration(milliseconds: milliseconds);
      _pager?.busyTimeout = _busyTimeout;
      return 0;
    }
    if (name == 'cache_size') {
      _cacheSize = _asInt(value);
      return 0;
    }
    if (name == 'max_page_count') {
      final pager = _pager;
      if (pager == null) {
        throw PureSqlException(
          'PRAGMA max_page_count requires a persistent database',
        );
      }
      pager.maxPageCount = _asInt(value);
      return 0;
    }
    if (name == 'page_size') {
      final pageSize = _asInt(value);
      if (!SqlitePagerSync.isValidPageSize(pageSize)) return 0;
      final pager = _pager;
      if (pager != null) {
        pager.setPageSize(pageSize);
      } else if (_tables.isEmpty &&
          _views.isEmpty &&
          _indexes.isEmpty &&
          _triggers.isEmpty) {
        _memoryPageSize = pageSize;
      }
      return 0;
    }
    if (name == 'synchronous') {
      if (_inTransaction) {
        throw PureSqlException(
          'Safety level may not be changed inside a transaction',
        );
      }
      final synchronous = switch (value.toString().toUpperCase()) {
        'OFF' => 0,
        'NORMAL' => 1,
        'FULL' => 2,
        'EXTRA' => 3,
        _ => _asInt(value),
      };
      if (synchronous < 0 || synchronous > 3) {
        throw PureSqlException('invalid synchronous value: $value');
      }
      _synchronous = synchronous;
      if (_pager != null) _pager!.synchronous = synchronous;
      return 0;
    }
    if (name == 'journal_mode') {
      final mode = _journalModeName(value);
      if (_pager == null) {
        if (mode == 'off') {
          _journalMode = 'off';
          return 0;
        }
        if (const {
          'delete',
          'truncate',
          'persist',
          'memory',
          'wal',
        }.contains(mode)) {
          _journalMode = 'memory';
          return 0;
        }
      } else if (_inTransaction) {
        throw PureSqlException(
          'cannot change journal mode inside a transaction',
        );
      }
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
    if (name != 'user_version') return 0;
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

  List<SqlRow> _walCheckpointRows(_Pragma statement, List<Object?> parameters) {
    if (_key(statement.schema ?? '') == 'temp') {
      return const [
        {'busy': 0, 'log': -1, 'checkpointed': -1},
      ];
    }
    final argument = statement.argument;
    final mode = argument == null
        ? 'PASSIVE'
        : _pragmaInput(argument, parameters).toString().toUpperCase();
    if (!const {
      'PASSIVE',
      'FULL',
      'RESTART',
      'TRUNCATE',
      'NOOP',
    }.contains(mode)) {
      throw PureSqlException('invalid wal_checkpoint mode: $mode');
    }
    final pager = _pager;
    final result = pager?.checkpointWal(mode) ?? (0, -1, -1);
    return [
      {'busy': result.$1, 'log': result.$2, 'checkpointed': result.$3},
    ];
  }

  Object? _pragmaValue(_Pragma statement) {
    final name = _key(statement.name);
    if (_key(statement.schema ?? '') == 'temp') {
      if (name == 'default_cache_size') {
        final pageCount = _temporaryPragmaValues[name] as int;
        return pageCount == 0 ? -2000 : pageCount;
      }
      if (_temporaryPragmaValues.containsKey(name)) {
        return _temporaryPragmaValues[name];
      }
      if (const {
        'auto_vacuum',
        'freelist_count',
        'page_count',
      }.contains(name)) {
        return 0;
      }
      if (name == 'encoding') return 'UTF-8';
    }
    if (name == 'analysis_limit') return _analysisLimit;
    if (name == 'automatic_index') return _automaticIndex ? 1 : 0;
    if (name == 'threads') return _threads;
    if (name == 'secure_delete') return _secureDeleteMode;
    if (name == 'count_changes') return _countChanges ? 1 : 0;
    if (name == 'full_column_names') return _fullColumnNames ? 1 : 0;
    if (name == 'short_column_names') return _shortColumnNames ? 1 : 0;
    if (name == 'temp_store') return _tempStore;
    if (name == 'wal_autocheckpoint') {
      return _pager?.walAutoCheckpointPages ?? _walAutoCheckpoint;
    }
    if (name == 'journal_size_limit') {
      return _pager?.journalSizeLimit ?? _journalSizeLimit;
    }
    if (name == 'foreign_keys') return _foreignKeys ? 1 : 0;
    if (name == 'defer_foreign_keys') return _deferForeignKeys ? 1 : 0;
    if (name == 'recursive_triggers') return _recursiveTriggers ? 1 : 0;
    if (name == 'ignore_check_constraints') {
      return _ignoreCheckConstraints ? 1 : 0;
    }
    if (name == 'query_only') return _queryOnly ? 1 : 0;
    if (name == 'read_uncommitted') return _readUncommitted ? 1 : 0;
    if (name == 'case_sensitive_like') return _caseSensitiveLike ? 1 : 0;
    if (name == 'legacy_alter_table') return _legacyAlterTable ? 1 : 0;
    if (name == 'reverse_unordered_selects') {
      return _reverseUnorderedSelects ? 1 : 0;
    }
    if (name == 'busy_timeout') return _busyTimeout.inMilliseconds;
    if (name == 'cache_size') return _cacheSize;
    if (name == 'default_cache_size') {
      final pageCount = _pager?.header.defaultCacheSize ?? _defaultCacheSize;
      return pageCount == 0 ? -2000 : pageCount;
    }
    if (name == 'max_page_count') {
      return _pager?.maxPageCount ?? SqlitePagerSync.defaultMaxPageCount;
    }
    if (name == 'synchronous') return _synchronous;
    if (name == 'journal_mode') {
      if (_pager == null) return _journalMode;
      return _pager!.isWalMode ? 'wal' : _journalMode;
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
    if (name == 'page_size') {
      return _pager?.header.pageSize ?? _memoryPageSize;
    }
    if (name == 'page_count') return _pager?.pageCount ?? 0;
    if (name == 'freelist_count') {
      return _pager?.header.freelistPageCount ?? 0;
    }
    if (name == 'auto_vacuum') return 0;
    throw PureSqlException('unsupported PRAGMA: ${statement.name}');
  }

  List<SqlRow> _pragmaRows(_Pragma statement, List<Object?> parameters) {
    final name = _key(statement.name);
    if (!_supportedPragmaNames.contains(name)) return const [];
    if (name == 'shrink_memory') return const [];
    if (name == 'mmap_size') {
      if (_key(statement.schema ?? '') == 'temp' || _pager == null) {
        return const [];
      }
      return const [
        {'mmap_size': 0},
      ];
    }
    if (name == 'pragma_list') {
      return [
        for (final pragma in _supportedPragmaNames) {'name': pragma},
      ];
    }
    if (name == 'module_list') {
      const builtins = ['json_each', 'json_tree', 'jsonb_each', 'jsonb_tree'];
      return [
        for (final module in builtins) {'name': module},
        for (final module in _virtualTableModules.keys)
          if (!builtins.contains(module)) {'name': module},
      ];
    }
    if (name == 'compile_options') return const [];
    if (name == 'wal_checkpoint') {
      return _walCheckpointRows(statement, parameters);
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
      final index = switch (_key(statement.schema ?? '')) {
        'temp' => _temporaryIndexes[_key(indexName)],
        'main' => _indexes[_key(indexName)],
        _ => _temporaryIndexes[_key(indexName)] ?? _indexes[_key(indexName)],
      };
      if (index == null) throw PureSqlException('no such index: $indexName');
      return [
        for (var position = 0; position < index.terms.length; position++)
          _indexInfoRow(index, position, name),
        if (name == 'index_xinfo')
          {
            'seqno': index.terms.length,
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
      final schema = _key(statement.schema ?? 'main');
      final tables = statement.argument != null
          ? [_pragmaTable(statement, parameters)]
          : schema == 'temp'
          ? _temporaryTables.values
          : _tables.values;
      final violations = <SqlRow>[];
      for (final table in tables) {
        final foreignKeys = _foreignKeysFor(table);
        for (var id = 0; id < foreignKeys.length; id++) {
          final foreignKey = foreignKeys[id];
          final parent = _foreignKeyParent(table, foreignKey.table);
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
      final attachedDatabases = _attachedDatabases.values.toList(
        growable: false,
      );
      return [
        {'seq': 0, 'name': 'main', 'file': _pager?.path ?? ''},
        if (_temporaryDatabaseOpened) {'seq': 1, 'name': 'temp', 'file': ''},
        for (var index = 0; index < attachedDatabases.length; index++)
          {
            'seq': index + 2,
            'name': attachedDatabases[index].name,
            'file': attachedDatabases[index].filename == ':memory:'
                ? ''
                : attachedDatabases[index].filename,
          },
      ];
    }
    if (name == 'table_list') {
      final schema = _key(statement.schema ?? '');
      final includeTemporary = schema != 'main';
      final includeMain = schema != 'temp';
      final rows = <SqlRow>[
        for (final table in _temporaryTables.values)
          if (includeTemporary)
            {
              'schema': 'temp',
              'name': table.name,
              'type': table.virtualTable == null ? 'table' : 'virtual',
              'ncol': table.columns.length,
              'wr': 0,
              'strict': 0,
            },
        for (final view in _temporaryViews.values)
          if (includeTemporary)
            {
              'schema': 'temp',
              'name': view.name,
              'type': 'view',
              'ncol':
                  view.columns?.length ?? _selectColumnNames(view.query).length,
              'wr': 0,
              'strict': 0,
            },
        for (final table in _tables.values)
          if (includeMain)
            {
              'schema': 'main',
              'name': table.name,
              'type': table.virtualTable == null ? 'table' : 'virtual',
              'ncol': table.columns.length,
              'wr': 0,
              'strict': 0,
            },
        for (final view in _views.values)
          if (includeMain)
            {
              'schema': 'main',
              'name': view.name,
              'type': 'view',
              'ncol':
                  view.columns?.length ?? _selectColumnNames(view.query).length,
              'wr': 0,
              'strict': 0,
            },
        if (statement.schema == null)
          for (final attached in _attachedDatabases.values)
            ...attached.database._withCurrentFile(
              () => [
                for (final table in attached.database._tables.values)
                  {
                    'schema': attached.name,
                    'name': table.name,
                    'type': table.virtualTable == null ? 'table' : 'virtual',
                    'ncol': table.columns.length,
                    'wr': 0,
                    'strict': 0,
                  },
                for (final view in attached.database._views.values)
                  {
                    'schema': attached.name,
                    'name': view.name,
                    'type': 'view',
                    'ncol':
                        view.columns?.length ??
                        attached.database._selectColumnNames(view.query).length,
                    'wr': 0,
                    'strict': 0,
                  },
              ],
            ),
      ];
      if (statement.argument == null) return rows;
      final tableName = _pragmaInput(
        statement.argument!,
        parameters,
      ).toString();
      return rows
          .where((row) => _key(row['name'].toString()) == _key(tableName))
          .toList();
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
        'STRING_AGG',
        'JSON_GROUP_ARRAY',
        'JSON_GROUP_OBJECT',
        'JSONB_GROUP_ARRAY',
        'JSONB_GROUP_OBJECT',
        'MEDIAN',
        'MAX',
        'MIN',
        'PERCENTILE',
        'PERCENTILE_CONT',
        'PERCENTILE_DISC',
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
          'CHANGES',
          'COALESCE',
          'CONCAT',
          'CONCAT_WS',
          'CURRENT_DATE',
          'CURRENT_TIME',
          'CURRENT_TIMESTAMP',
          'COS',
          'COSH',
          'COUNT',
          'DATE',
          'DATETIME',
          'DEGREES',
          'EXP',
          'FLOOR',
          'FORMAT',
          'GLOB',
          'GROUP_CONCAT',
          'STRING_AGG',
          'MEDIAN',
          'BASE64',
          'BASE85',
          'HEX',
          'IFNULL',
          'IF',
          'IIF',
          'INSTR',
          'JSON',
          'JSON_ARRAY',
          'JSON_ARRAY_INSERT',
          'JSON_ARRAY_LENGTH',
          'JSONB',
          'JSONB_ARRAY',
          'JSONB_ARRAY_INSERT',
          'JSONB_EXTRACT',
          'JSONB_INSERT',
          'JSONB_OBJECT',
          'JSONB_PATCH',
          'JSONB_REMOVE',
          'JSONB_REPLACE',
          'JSONB_SET',
          'JSON_ERROR_POSITION',
          'JSON_EXTRACT',
          'JSON_GROUP_ARRAY',
          'JSON_GROUP_OBJECT',
          'JSONB_GROUP_ARRAY',
          'JSONB_GROUP_OBJECT',
          'JSON_INSERT',
          'JSON_OBJECT',
          'JSON_PATCH',
          'JSON_PRETTY',
          'JSON_QUOTE',
          'JSON_REMOVE',
          'JSON_REPLACE',
          'JSON_SET',
          'JSON_TYPE',
          'JSON_VALID',
          'LN',
          'LOG',
          'LOG10',
          'LOG2',
          'JULIANDAY',
          'LENGTH',
          'LAST_INSERT_ROWID',
          'LIKELIHOOD',
          'LIKELY',
          'LIKE',
          'LOWER',
          'LTRIM',
          'MAX',
          'MIN',
          'MOD',
          'NULLIF',
          'OCTET_LENGTH',
          'PI',
          'PERCENTILE',
          'PERCENTILE_CONT',
          'PERCENTILE_DISC',
          'PRINTF',
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
          'SQLITE_COMPILEOPTION_GET',
          'SQLITE_COMPILEOPTION_USED',
          'SQLITE_LOG',
          'SQLITE_OFFSET',
          'SQLITE_SOURCE_ID',
          'SQLITE_VERSION',
          'SOUNDEX',
          'SIN',
          'SINH',
          'SQRT',
          'STRFTIME',
          'SUBSTR',
          'SUBSTRING',
          'SUBTYPE',
          'SUM',
          'TIME',
          'TIMEDIFF',
          'TOTAL',
          'TOTAL_CHANGES',
          'TAN',
          'TANH',
          'TRIM',
          'TRUNC',
          'TYPEOF',
          'UNICODE',
          'UNIXEPOCH',
          'UNLIKELY',
          'UNHEX',
          'UNISTR',
          'UNISTR_QUOTE',
          'UPPER',
          'ZEROBLOB',
          '->',
          '->>',
        ])
          if (function != 'BASE64' &&
              function != 'BASE85' &&
              function != 'SQLITE_OFFSET')
            for (final arity in _builtinSqlFunctionArities(function))
              {
                'name': function,
                'builtin': 1,
                'type':
                    aggregates.contains(function) &&
                        ((function != 'MAX' && function != 'MIN') || arity == 1)
                    ? 'w'
                    : 's',
                'enc': 'utf8',
                'narg': arity,
                'flags': _sqliteFunctionFlags(
                  function,
                  arity,
                  aggregate:
                      aggregates.contains(function) &&
                      ((function != 'MAX' && function != 'MIN') || arity == 1),
                ),
              },
        for (final function in const ['BASE64', 'BASE85'])
          {
            'name': function,
            'builtin': 0,
            'type': 's',
            'enc': 'utf8',
            'narg': 1,
            'flags': 0,
          },
        {
          'name': 'SQLITE_OFFSET',
          'builtin': 1,
          'type': 's',
          'enc': 'utf8',
          'narg': 1,
          'flags': 0,
        },
        for (final arity in const [1, 2])
          {
            'name': 'LOAD_EXTENSION',
            'builtin': 1,
            'type': 's',
            'enc': 'utf8',
            'narg': arity,
            'flags': 0,
          },
        for (final (function, arity) in const [
          ('CUME_DIST', 0),
          ('DENSE_RANK', 0),
          ('FIRST_VALUE', 1),
          ('LAG', 1),
          ('LAG', 2),
          ('LAG', 3),
          ('LAST_VALUE', 1),
          ('LEAD', 1),
          ('LEAD', 2),
          ('LEAD', 3),
          ('NTILE', 1),
          ('PERCENT_RANK', 0),
          ('RANK', 0),
          ('ROW_NUMBER', 0),
          ('NTH_VALUE', 2),
        ])
          {
            'name': function,
            'builtin': 1,
            'type': 'w',
            'enc': 'utf8',
            'narg': arity,
            'flags': 0x200000,
          },
        for (final entry in _functions.entries)
          for (final arity in entry.value.keys)
            {
              'name': entry.key.toUpperCase(),
              'builtin': 0,
              'type': 's',
              'enc': 'utf8',
              'narg': arity,
              'flags': 0,
            },
        for (final entry in _aggregateFunctions.entries)
          for (final arity in entry.value.keys)
            {
              'name': entry.key.toUpperCase(),
              'builtin': 0,
              'type': 'a',
              'enc': 'utf8',
              'narg': arity,
              'flags': 0,
            },
        for (final entry in _windowFunctionCallbacks.entries)
          for (final arity in entry.value.keys)
            {
              'name': entry.key.toUpperCase(),
              'builtin': 0,
              'type': 'w',
              'enc': 'utf8',
              'narg': arity,
              'flags': 0,
            },
      ];
    }
    if (name == 'integrity_check' || name == 'quick_check') {
      final argument = statement.argument == null
          ? null
          : _pragmaInput(statement.argument!, parameters);
      final tableName = argument is String ? argument : null;
      final maxErrors = argument is num ? argument.toInt() : null;
      final errors = _integrityErrors(
        temporary: _key(statement.schema ?? '') == 'temp',
        tableName: tableName,
      );
      final limitedErrors = maxErrors != null && maxErrors > 0
          ? errors.take(maxErrors)
          : errors;
      final result = limitedErrors.toList();
      return [
        for (final error in result.isEmpty ? const ['ok'] : result)
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
    return statement.schema == null
        ? _selectTable(tableName, const {}, parameters)
        : _selectSchemaTable(statement.schema!, tableName, parameters);
  }

  SqlRow _indexInfoRow(_Index index, int position, String pragma) {
    final term = index.terms[position];
    final columnName = term.expression is _Column
        ? (term.expression as _Column).name
        : null;
    final columnId = columnName == null
        ? -2
        : index.table.columns.indexWhere(
            (column) => _key(column.name) == _key(columnName),
          );
    return {
      'seqno': position,
      'cid': columnId,
      'name': columnName,
      if (pragma == 'index_xinfo') ...{
        'desc': term.descending ? 1 : 0,
        'coll': _indexTermCollation(index.table, term),
        'key': 1,
      },
    };
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
        index.terms.length == primaryColumns.length &&
        index.terms.every(
          (term) =>
              term.expression is _Column &&
              primaryColumns.any(
                (primaryColumn) =>
                    _key(primaryColumn) ==
                    _key((term.expression as _Column).name),
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

  List<String> _integrityErrors({bool temporary = false, String? tableName}) {
    final errors = <String>[];
    final foreignKeys = _foreignKeys;
    _foreignKeys = false;
    try {
      final tables = temporary ? _temporaryTables.values : _tables.values;
      final selectedTables = tables
          .where(
            (table) => tableName == null || _key(table.name) == _key(tableName),
          )
          .toList();
      if (tableName != null && selectedTables.isEmpty) {
        throw PureSqlException('no such table: $tableName');
      }
      for (final table in selectedTables) {
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
    final indexes = statement.temporary ? _temporaryIndexes : _indexes;
    final tables = statement.temporary ? _temporaryTables : _tables;
    final triggers = statement.temporary ? _temporaryTriggers : _triggers;
    if (indexes.containsKey(key) ||
        tables.containsKey(key) ||
        triggers.containsKey(key) ||
        statement.temporary && _temporaryViews.containsKey(key) ||
        !statement.temporary && _views.containsKey(key)) {
      if (statement.ifNotExists) return 0;
      throw PureSqlException('index already exists: ${statement.name}');
    }
    final table = tables[_key(statement.table)];
    if (table == null) {
      throw PureSqlException('no such table: ${statement.table}');
    }
    if (table.virtualTable != null) {
      throw PureSqlException('virtual tables cannot have indexes');
    }
    final index = _Index(
      statement.name,
      table,
      statement.terms,
      unique: statement.unique,
      where: statement.where,
      schemaSql: sql.trim(),
    );
    _validateIndexTerms(index);
    _validateIndexRows(index, table.rows);
    if (_pager == null || statement.temporary) {
      indexes[key] = index;
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
    SqliteIndexBtree.rewriteRows(
      pager,
      rootPage,
      _indexEntries(index),
      compare: (left, right) => _compareIndexEntries(index, left, right),
    );
    SqliteTableBtree.insertRow(pager, 1, _nextSchemaRowId(), [
      'index',
      statement.name,
      statement.table,
      rootPage,
      sql.trim(),
    ], pageStart: 100);
    indexes[key] = index;
    table.indexes.add(index);
    return 0;
  }

  void _validateIndexTerms(_Index index) {
    final row = {for (final column in index.table.columns) column.name: null};
    for (final term in index.terms) {
      if (!_deterministicIndexExpression(term.expression)) {
        throw PureSqlException(
          'non-deterministic expression in index: ${index.name}',
        );
      }
      _eval(term.expression, row, const []);
    }
    if (index.where != null) {
      if (!_deterministicIndexExpression(index.where!)) {
        throw PureSqlException(
          'non-deterministic expression in index: ${index.name}',
        );
      }
      _eval(index.where!, row, const []);
    }
  }

  int _drop(_Drop statement) {
    final schema = statement.schema == null ? null : _key(statement.schema!);
    final allowTemporary = schema != 'main';
    final allowMain = schema != 'temp';
    if (statement.type == 'trigger') {
      final key = _key(statement.name);
      final temporary = allowTemporary ? _temporaryTriggers.remove(key) : null;
      final trigger = temporary ?? (allowMain ? _triggers.remove(key) : null);
      if (trigger == null) {
        if (statement.ifExists) return 0;
        throw PureSqlException('no such trigger: ${statement.name}');
      }
      if (_pager != null && temporary == null) {
        _rewriteSchemaWithout(_pager!, {_key(trigger.name)});
      }
      return 0;
    }
    if (statement.type == 'view') {
      final key = _key(statement.name);
      final temporaryView = allowTemporary ? _temporaryViews.remove(key) : null;
      final view = temporaryView ?? (allowMain ? _views.remove(key) : null);
      if (view == null) {
        if (statement.ifExists) return 0;
        throw PureSqlException('no such view: ${statement.name}');
      }
      final attachedTriggerNames = {
        for (final trigger in _triggers.values)
          if (!view.temporary && _key(trigger.table) == _key(view.name))
            _key(trigger.name),
      };
      if (!view.temporary) {
        _triggers.removeWhere(
          (_, trigger) => _key(trigger.table) == _key(view.name),
        );
      }
      _temporaryTriggers.removeWhere(
        (_, trigger) =>
            trigger.targetTemporary == view.temporary &&
            _key(trigger.table) == _key(view.name),
      );
      if (_pager != null && !view.temporary) {
        _rewriteSchemaWithout(_pager!, {
          _key(view.name),
          ...attachedTriggerNames,
        });
      }
      return 0;
    }
    if (statement.type == 'table') {
      final key = _key(statement.name);
      final table =
          (allowTemporary ? _temporaryTables[key] : null) ??
          (allowMain ? _tables[key] : null);
      if (table == null) {
        if (statement.ifExists) return 0;
        throw PureSqlException('no such table: ${statement.name}');
      }
      if (table.isTemporary) {
        if (_foreignKeys && table.virtualTable == null) {
          final before = _snapshotRows();
          final changedTables = <_Table>{};
          try {
            for (final rowId in List<int>.from(table.rowIds)) {
              _deleteRowWithActions(
                table,
                rowId,
                changedTables,
                {},
                fireParentTrigger: false,
              );
            }
            changedTables.remove(table);
            _rewriteChangedTables(changedTables);
          } catch (_) {
            _restoreRows(before);
            rethrow;
          }
        }
        for (final index in table.indexes) {
          _temporaryIndexes.remove(_key(index.name));
        }
        _temporaryTriggers.removeWhere(
          (_, trigger) =>
              trigger.targetTemporary &&
              _key(trigger.table) == _key(table.name),
        );
        _temporaryTables.remove(_key(table.name));
        _dropVirtualTable(table);
        return 0;
      }
      if (table.isSequenceTable &&
          _tables.values.any((candidate) => candidate.autoIncrement)) {
        throw PureSqlException(
          'cannot drop sqlite_sequence while AUTOINCREMENT tables exist',
        );
      }
      if (_foreignKeys && table.virtualTable == null) {
        final before = _snapshotRows();
        final changedTables = <_Table>{};
        try {
          for (final rowId in List<int>.from(table.rowIds)) {
            _deleteRowWithActions(
              table,
              rowId,
              changedTables,
              {},
              fireParentTrigger: false,
            );
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
        for (final trigger in _triggers.values)
          if (_key(trigger.table) == _key(table.name)) _key(trigger.name),
      };
      _triggers.removeWhere(
        (_, trigger) => _key(trigger.table) == _key(table.name),
      );
      _temporaryTriggers.removeWhere(
        (_, trigger) =>
            !trigger.targetTemporary && _key(trigger.table) == _key(table.name),
      );
      final pager = _pager;
      if (pager != null) {
        for (final index in table.indexes) {
          if (index.rootPage != null) {
            SqliteIndexBtree.freeTree(pager, index.rootPage!);
          }
        }
        if (table.virtualTable == null) {
          SqliteTableBtree.freeTree(pager, table.rootPage!);
        }
        _rewriteSchemaWithout(pager, schemaNames);
      }
      if (table.autoIncrement) {
        final sequence = _tables['sqlite_sequence'];
        if (sequence != null) {
          for (var index = sequence.rows.length - 1; index >= 0; index--) {
            if (_key(sequence.rows[index]['name']?.toString() ?? '') ==
                _key(table.name)) {
              sequence.rows.removeAt(index);
              sequence.rowIds.removeAt(index);
            }
          }
          if (pager != null) _rewriteTable(pager, sequence);
        }
      }
      for (final index in table.indexes) {
        _indexes.remove(_key(index.name));
      }
      _tables.remove(_key(table.name));
      _dropVirtualTable(table);
      return 0;
    }
    final key = _key(statement.name);
    final temporaryIndex = allowTemporary && _temporaryIndexes.containsKey(key);
    if (!allowMain && !temporaryIndex) {
      if (statement.ifExists) return 0;
      throw PureSqlException('no such index: ${statement.name}');
    }
    final index = temporaryIndex ? _temporaryIndexes[key] : _indexes[key];
    if (index == null) {
      if (statement.ifExists) return 0;
      throw PureSqlException('no such index: ${statement.name}');
    }
    if (index.name.startsWith('sqlite_autoindex_')) {
      throw PureSqlException('cannot drop an internal index');
    }
    final pager = _pager;
    if (pager != null && !temporaryIndex) {
      SqliteIndexBtree.freeTree(pager, index.rootPage!);
      _rewriteSchemaWithout(pager, {_key(index.name)});
    }
    index.table.indexes.remove(index);
    (temporaryIndex ? _temporaryIndexes : _indexes).remove(key);
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
                !const [
                  'table',
                  'index',
                  'view',
                  'trigger',
                ].contains(row.values[0]) ||
                !names.contains(_key(row.values[1].toString())),
          )
          .toList(),
      pageStart: 100,
    );
  }

  int _insert(_Insert statement, List<Object?> parameters) {
    final view = _viewDmlTable(statement.table, 'INSERT');
    if (view != null) return _insertView(statement, view, parameters);
    final table = _table(statement.table);
    final before = _snapshotRows();
    final oldNextRowId = table.nextRowId;
    try {
      var changed = 0;
      final rows = statement.select == null
          ? statement.rows
          : [
              for (final row in _select(
                statement.select!,
                parameters,
                outerRow: _activeTriggerContext ?? const {},
              ))
                [for (final value in row.values) _Literal(value)],
            ];
      insertRows:
      for (final values in rows) {
        final rowBefore = statement.conflict == 'fail' ? _snapshotRows() : null;
        try {
          changed += _insertRow(statement, table, values, parameters);
        } catch (error, stackTrace) {
          if (error is _TriggerRaiseException && _triggerExecutionDepth == 0) {
            if (error.action == 'IGNORE') {
              if (error.before) continue insertRows;
              changed++;
              break insertRows;
            }
            if (error.action == 'FAIL') {
              throw _ConflictFailException(
                error.error,
                stackTrace,
                changed + (error.before ? 0 : 1),
              );
            }
          }
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
      if (error is _TriggerRaiseException &&
          const ['IGNORE', 'FAIL'].contains(error.action) &&
          _triggerExecutionDepth > 0) {
        rethrow;
      }
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

  _Table? _viewDmlTable(String name, String event) {
    final key = _key(name);
    final view =
        _temporaryViews[key] ??
        (_temporaryTables.containsKey(key) ? null : _views[key]);
    if (view == null) return null;
    if (!_allTriggers.any(
      (trigger) =>
          _key(trigger.table) == _key(name) &&
          trigger.targetTemporary == view.temporary &&
          trigger.timing == 'INSTEAD OF' &&
          trigger.event == event,
    )) {
      throw PureSqlException('cannot modify $name because it is a view');
    }
    return _selectTable(name, const {}, const []);
  }

  int _insertView(_Insert statement, _Table view, List<Object?> parameters) {
    if (statement.upserts.isNotEmpty) {
      throw PureSqlException('UPSERT is not supported for views');
    }
    final before = _snapshotRows();
    try {
      final rows = statement.select == null
          ? statement.rows
          : [
              for (final row in _select(
                statement.select!,
                parameters,
                outerRow: _activeTriggerContext ?? const {},
              ))
                [for (final value in row.values) _Literal(value)],
            ];
      for (final values in rows) {
        final columns = statement.defaultValues
            ? const <String>[]
            : statement.columns ??
                  view.columns.map((column) => column.name).toList();
        if (columns.length != values.length) {
          throw PureSqlException('column/value count mismatch');
        }
        final row = <String, Object?>{
          for (final column in view.columns) column.name: null,
        };
        for (var index = 0; index < columns.length; index++) {
          final column = view.column(columns[index]);
          final value = _evalQueryExpression(
            values[index],
            _triggerEvalRow(row),
            parameters,
          );
          if (value is _SqlRowValue) {
            throw PureSqlException('row value misused');
          }
          row[column.name] = value;
        }
        final returningRow = _returningRow(
          view,
          row,
          statement.returning,
          parameters,
        );
        try {
          _fireTriggers(view, 'INSERT', timing: 'INSTEAD OF', newRow: row);
        } on _TriggerRaiseException catch (raise, stackTrace) {
          if (_triggerExecutionDepth > 0 &&
              const ['IGNORE', 'FAIL'].contains(raise.action)) {
            rethrow;
          }
          if (raise.action == 'IGNORE') continue;
          if (raise.action == 'FAIL') {
            throw _ConflictFailException(raise.error, stackTrace, 0);
          }
          rethrow;
        }
        if (returningRow != null) _lastReturningRows.add(returningRow);
      }
      return 0;
    } on _ConflictFailException {
      rethrow;
    } on _TriggerRaiseException catch (raise) {
      if (_triggerExecutionDepth > 0 &&
          const ['IGNORE', 'FAIL'].contains(raise.action)) {
        rethrow;
      }
      _restoreRows(before);
      rethrow;
    } catch (_) {
      _restoreRows(before);
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
    Object? explicitRowId;
    for (var i = 0; i < columns.length; i++) {
      final value = _evalQueryExpression(
        values[i],
        _triggerEvalRow(row),
        parameters,
      );
      if (value is _SqlRowValue) {
        throw PureSqlException('row value misused');
      }
      if (table.isRowIdAlias(columns[i])) {
        final rowIdColumn = table.rowIdColumn;
        if (rowIdColumn == null) {
          explicitRowId = value;
        } else {
          row[rowIdColumn.name] = value;
        }
        continue;
      }
      final column = table.column(columns[i]);
      row[column.name] = value;
    }
    final rowIdColumn = table.rowIdColumn;
    final requestedRowId = rowIdColumn == null
        ? explicitRowId
        : row[rowIdColumn.name] ?? explicitRowId;
    final rowId = requestedRowId == null
        ? table.autoIncrement
              ? _nextAutoIncrementRowId(table)
              : table.nextRowId
        : _asInt(requestedRowId);
    if (table.virtualTable != null) {
      if (rowId < -0x8000000000000000 || rowId > 0x7fffffffffffffff) {
        throw PureSqlException(
          'virtual-table rowid must be a signed 64-bit integer',
        );
      }
    } else if (rowId < 1) {
      throw PureSqlException('rowid must be positive');
    }
    if (rowIdColumn != null) row[rowIdColumn.name] = rowId;
    _fireTriggers(
      table,
      'INSERT',
      timing: 'BEFORE',
      newRow: row,
      newRowId: rowId,
    );
    final conflicts = _conflictingRows(table, row, rowId);
    for (final upsert in statement.upserts) {
      final result = _applyUpsertClause(
        upsert,
        table,
        row,
        conflicts,
        parameters,
        statement.returning,
      );
      if (result != null) return result;
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
    SqlRow? returningRow;
    var sequenceChanged = false;
    try {
      for (final rowId in conflictRowIds.reversed) {
        final index = table.rowIds.indexOf(rowId);
        if (index < 0) continue;
        if (_foreignKeys) {
          _deleteRowWithActions(
            table,
            rowId,
            changedTables,
            {},
            fireParentTrigger: _recursiveTriggers,
          );
        } else {
          final oldRow = Map<String, Object?>.from(table.rows[index]);
          if (_recursiveTriggers) {
            _fireTriggers(
              table,
              'DELETE',
              timing: 'BEFORE',
              oldRow: oldRow,
              oldRowId: rowId,
            );
          }
          table.rows.removeAt(index);
          table.rowIds.removeAt(index);
          if (_recursiveTriggers) {
            _fireTriggers(table, 'DELETE', oldRow: oldRow, oldRowId: rowId);
          }
        }
      }
      _validate(table, row);
      returningRow = _returningRow(
        table,
        row,
        statement.returning,
        parameters,
        rowId: rowId,
      );
      table.nextRowId = rowId >= table.nextRowId ? rowId + 1 : table.nextRowId;
      table.rows.add(row);
      table.rowIds.add(rowId);
      sequenceChanged = _recordSequence(table, rowId);
      if (changedTables.isNotEmpty || table.virtualTable != null) {
        changedTables.add(table);
      }
      for (final index in table.indexes) {
        _validateIndexRows(index, table.rows);
      }
    } catch (_) {
      _restoreRows(before);
      table.nextRowId = oldNextRowId;
      rethrow;
    }
    final pager = _pager;
    if (table.virtualTable != null) {
      _rewriteChangedTables({table});
    } else if (pager != null && !table.isTemporary) {
      try {
        if (changedTables.isNotEmpty) {
          _rewriteChangedTables(changedTables);
        } else {
          if (conflicts.isEmpty) {
            SqliteTableBtree.insertRow(pager, table.rootPage!, rowId, [
              ..._storedValues(table, row),
            ]);
            _refreshTableRecordOffsets(pager, table);
          } else {
            _rewriteTable(pager, table);
          }
          _rewriteIndexes(pager, table);
        }
        if (sequenceChanged) {
          _rewriteTable(pager, _tables['sqlite_sequence']!);
        }
      } catch (_) {
        _restoreRows(before);
        table.nextRowId = oldNextRowId;
        rethrow;
      }
    }
    if (returningRow != null) _lastReturningRows.add(returningRow);
    _lastInsertRowId = rowId;
    _fireTriggers(table, 'INSERT', newRow: row, newRowId: rowId);
    return 1;
  }

  SqlRow _triggerEvalRow(SqlRow row) =>
      _activeTriggerContext == null ? row : {...row, ..._activeTriggerContext!};

  SqlRow _tableDmlRow(_Table table, int index) => _triggerEvalRow(
    _qualifiedRow(table, table.rows[index], null, rowId: table.rowIds[index]),
  );

  void _fireTriggers(
    _Table table,
    String event, {
    String timing = 'AFTER',
    SqlRow? oldRow,
    SqlRow? newRow,
    int? oldRowId,
    int? newRowId,
    Set<String> updatedColumns = const {},
  }) {
    for (final trigger in _allTriggers.toList()) {
      if (_key(trigger.table) != _key(table.name) ||
          trigger.targetTemporary != table.isTemporary ||
          trigger.event != event ||
          trigger.timing != timing) {
        continue;
      }
      if (trigger.updateOf.isNotEmpty &&
          !trigger.updateOf.any(
            (column) => updatedColumns.contains(_key(column)),
          )) {
        continue;
      }
      final key =
          '${trigger.temporary ? 'temp' : 'main'}:${_key(trigger.name)}';
      if (_recursiveTriggers && _triggerExecutionDepth >= 1000) {
        throw PureSqlException('maximum trigger recursion depth exceeded');
      }
      final entered = _activeTriggers.add(key);
      if (!entered && !_recursiveTriggers) continue;
      final previousContext = _activeTriggerContext;
      final context = <String, Object?>{};
      for (final column in table.columns) {
        context['@OLD.${column.name}'] = oldRow?[column.name];
        context['@NEW.${column.name}'] = newRow?[column.name];
      }
      for (final alias in const ['rowid', '_rowid_', 'oid']) {
        if (!table.isRowIdAlias(alias)) continue;
        context['@OLD.$alias'] = oldRowId;
        context['@NEW.$alias'] = newRowId;
      }
      _activeTriggerContext = context;
      final previousLastInsertRowId = _lastInsertRowId;
      _triggerExecutionDepth++;
      try {
        final triggerDepth = _triggerExecutionDepth;
        runZoned(
          () {
            if (trigger.when != null &&
                !_matches(trigger.when, context, const [])) {
              return;
            }
            for (final step in trigger.steps) {
              try {
                if (step is _Select) {
                  _select(step, const [], outerRow: context);
                } else {
                  _recordChanges(
                    step,
                    _execute(step, const [], trigger.schemaSql ?? ''),
                  );
                }
              } on _TriggerRaiseException catch (raise) {
                if (raise.action == 'IGNORE' &&
                    raise.triggerDepth > triggerDepth) {
                  continue;
                }
                rethrow;
              }
            }
          },
          zoneValues: {
            _sqlTriggerExecutionDepthZoneKey: triggerDepth,
            _sqlTriggerTimingZoneKey: trigger.timing,
          },
        );
      } finally {
        _triggerExecutionDepth--;
        _lastInsertRowId = previousLastInsertRowId;
        _activeTriggerContext = previousContext;
        if (entered) _activeTriggers.remove(key);
      }
    }
  }

  int _nextAutoIncrementRowId(_Table table) {
    if (table.isTemporary) return table.nextRowId;
    final sequence = _sequenceValue(table);
    var largest = sequence ?? 0;
    if (sequence == null) {
      for (final rowId in table.rowIds) {
        if (rowId > largest) largest = rowId;
      }
    }
    if (largest >= 0x7fffffffffffffff) {
      throw PureSqlException('database or disk is full');
    }
    return largest + 1;
  }

  int? _sequenceValue(_Table table, [_Table? sequenceTable]) {
    final sequence = sequenceTable ?? _tables['sqlite_sequence'];
    if (sequence == null) return null;
    for (final row in sequence.rows) {
      if (_key(row['name']?.toString() ?? '') != _key(table.name)) continue;
      final value = row['seq'];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }
    return null;
  }

  bool _recordSequence(_Table table, int rowId) {
    if (table.isTemporary) return false;
    if (!table.autoIncrement) return false;
    final sequence = _tables['sqlite_sequence'];
    if (sequence == null || !sequence.isSequenceTable) {
      throw PureSqlException('AUTOINCREMENT sequence table is missing');
    }
    final current = _sequenceValue(table, sequence) ?? 0;
    if (rowId <= current) return false;
    for (var index = 0; index < sequence.rows.length; index++) {
      if (_key(sequence.rows[index]['name']?.toString() ?? '') ==
          _key(table.name)) {
        sequence.rows[index]['seq'] = rowId;
        return true;
      }
    }
    final sequenceRowId = sequence.nextRowId++;
    sequence.rows.add({'name': table.name, 'seq': rowId});
    sequence.rowIds.add(sequenceRowId);
    return true;
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

  bool _isUniqueTarget(
    _Table table,
    List<_UpsertTargetTerm> target,
    _Expr? targetWhere,
  ) {
    final keys = <List<_IndexTerm>>[
      if (targetWhere == null) ...[
        for (final column in table.columns)
          if (column.unique || column.primaryKey)
            [_IndexTerm(_Column(column.name))],
        if (table.primaryKeyColumns.isNotEmpty)
          [
            for (final column in table.primaryKeyColumns)
              _IndexTerm(_Column(column)),
          ],
        for (final constraint in table.uniqueConstraints)
          [for (final column in constraint) _IndexTerm(_Column(column))],
      ],
      for (final index in table.indexes)
        if (index.unique &&
            (index.where == null && targetWhere == null ||
                index.where != null &&
                    targetWhere != null &&
                    _sameExpression(index.where!, targetWhere)))
          index.terms,
    ];
    return keys.any((key) {
      if (key.length != target.length) return false;
      for (var position = 0; position < key.length; position++) {
        final targetTerm = target[position];
        if (!_sameExpression(key[position].expression, targetTerm.expression) ||
            (targetTerm.collation ??
                    _expressionCollation(table, targetTerm.expression)) !=
                _indexTermCollation(table, key[position])) {
          return false;
        }
      }
      return true;
    });
  }

  bool _matchesConflictTarget(
    _Table table,
    SqlRow attempted,
    SqlRow existing,
    List<_UpsertTargetTerm> target,
    _Expr? targetWhere,
  ) =>
      (targetWhere == null ||
          _truthy(_eval(targetWhere, attempted, const [])) &&
              _truthy(_eval(targetWhere, existing, const []))) &&
      target.every((targetColumn) {
        final value = _eval(targetColumn.expression, attempted, const []);
        final oldValue = _eval(targetColumn.expression, existing, const []);
        return value != null &&
            oldValue != null &&
            _compare(
                  oldValue,
                  value,
                  noCase:
                      (targetColumn.collation ??
                          _expressionCollation(
                            table,
                            targetColumn.expression,
                          )) ==
                      'NOCASE',
                ) ==
                0;
      });

  int? _applyUpsertClause(
    _UpsertClause clause,
    _Table table,
    SqlRow row,
    List<int> conflicts,
    List<Object?> parameters,
    List<_SelectItem>? returning,
  ) {
    final target = clause.target;
    if (target != null && !_isUniqueTarget(table, target, clause.targetWhere)) {
      throw PureSqlException('ON CONFLICT target does not match a UNIQUE key');
    }
    int? conflictIndex;
    for (final index in conflicts) {
      if (target == null ||
          _matchesConflictTarget(
            table,
            row,
            table.rows[index],
            target,
            clause.targetWhere,
          )) {
        conflictIndex = index;
        break;
      }
    }
    if (conflictIndex == null) return null;
    if (clause.doNothing) return 0;

    final existing = table.rows[conflictIndex];
    final context = _qualifiedRow(
      table,
      existing,
      null,
      rowId: table.rowIds[conflictIndex],
    );
    for (final column in table.columns) {
      context['@excluded.${column.name}'] = row[column.name];
    }
    if (clause.where != null && !_matches(clause.where, context, parameters)) {
      return 0;
    }
    final next = Map<String, Object?>.from(existing);
    var replacementRowId = table.rowIds[conflictIndex];
    for (final assignment in clause.assignments) {
      final assignedRowId = _assignValues(
        table,
        next,
        assignment.columns,
        _evalQueryExpression(assignment.expression, context, parameters),
      );
      if (assignedRowId case _RowIdAssignment(:final value)) {
        replacementRowId = value == null ? table.nextRowId : _asInt(value);
      }
    }
    if (table.rowIdColumn case final rowIdColumn?) {
      replacementRowId = _asInt(next[rowIdColumn.name]);
    }
    final returningRow = _returningRow(
      table,
      next,
      returning,
      parameters,
      rowId: replacementRowId,
    );
    final before = _snapshotRows();
    final changedTables = <_Table>{};
    try {
      _updateRowWithActions(
        table,
        table.rowIds[conflictIndex],
        next,
        changedTables,
        {},
        updatedColumns: {
          for (final assignment in clause.assignments)
            for (final name in assignment.columns) _key(name),
        },
        replacementRowId: table.rowIdColumn == null ? replacementRowId : null,
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
    if (returningRow != null) _lastReturningRows.add(returningRow);
    return 1;
  }

  SqlRow? _returningRow(
    _Table table,
    SqlRow row,
    List<_SelectItem>? items,
    List<Object?> parameters, {
    int? rowId,
  }) => items == null
      ? null
      : _project(
          _qualifiedRow(table, row, null, rowId: rowId),
          items,
          parameters,
          [(table, null)],
        );

  bool _sameIndexKey(_Index index, SqlRow left, SqlRow right) {
    if (index.where != null &&
        (!_truthy(_eval(index.where!, left, const [])) ||
            !_truthy(_eval(index.where!, right, const [])))) {
      return false;
    }
    for (final term in index.terms) {
      final a = _eval(term.expression, left, const []);
      final b = _eval(term.expression, right, const []);
      if (a == null || b == null) return false;
      if (_compare(
            a,
            b,
            noCase: _indexTermCollation(index.table, term) == 'NOCASE',
          ) !=
          0) {
        return false;
      }
    }
    return true;
  }

  String _expressionCollation(_Table table, _Expr expression) =>
      expression is _Column
      ? table.column(expression.name).collation ?? 'BINARY'
      : 'BINARY';

  String _indexTermCollation(_Table table, _IndexTerm term) =>
      term.collation ?? _expressionCollation(table, term.expression);

  void _loadFile([Map<String, _Table> previousTables = const {}]) {
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
      if (statement is _CreateVirtualTable) {
        if (rootPage != 0) {
          throw SqliteFormatException('invalid virtual-table root page');
        }
        final moduleFactory = _virtualTableModules[_key(statement.module)];
        if (moduleFactory == null) {
          throw PureSqlException('no such module: ${statement.module}');
        }
        final previous = previousTables[_key(statement.name)];
        final module = previous?.schemaSql == sql
            ? previous?.virtualTable
            : null;
        final instance =
            module ??
            moduleFactory(
              this,
              'main',
              statement.name,
              statement.arguments,
              create: false,
            );
        try {
          final columns = List<String>.from(instance.columns);
          final names = <String>{};
          if (columns.isEmpty) {
            throw PureSqlException(
              'virtual tables must expose at least one column',
            );
          }
          for (final column in columns) {
            if (column.isEmpty || !names.add(_key(column))) {
              throw PureSqlException('invalid virtual-table column: $column');
            }
          }
          final table = _Table(
            statement.name,
            [for (final column in columns) _ColumnDef(column)],
            rootPage: 0,
            virtualTable: instance,
            schemaSql: sql,
          );
          _refreshVirtualTableRows(table);
          _tables[_key(table.name)] = table;
        } catch (_) {
          if (!identical(instance, previous?.virtualTable))
            _disposeVirtualTable(instance);
          rethrow;
        }
        continue;
      }
      if (statement is! _CreateTable) continue;
      final table = _Table(
        statement.name,
        statement.columns,
        schemaSql: sql,
        rootPage: rootPage,
        isSequenceTable: _key(statement.name) == 'sqlite_sequence',
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
        if (row.recordOffset case final offset?) {
          table.recordOffsets[row.rowId] = offset;
        }
        table.nextRowId = row.rowId >= table.nextRowId
            ? row.rowId + 1
            : table.nextRowId;
      }
      _tables[_key(table.name)] = table;
    }
    final sequenceTable = _tables['sqlite_sequence'];
    if (sequenceTable != null) {
      for (final table in _tables.values.where(
        (table) => table.autoIncrement,
      )) {
        final sequence = _sequenceValue(table, sequenceTable);
        if (sequence != null) {
          table.nextRowId = math.max(table.nextRowId, sequence + 1);
        }
      }
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
      List<_IndexTerm>? terms;
      var unique = false;
      if (sql is String) {
        final parsed = _Parser(sql).parse();
        if (parsed is! _CreateIndex) continue;
        statement = parsed;
        terms = statement.terms;
        unique = statement.unique;
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
        terms = [
          for (final column in candidates[offset]) _IndexTerm(_Column(column)),
        ];
        unique = true;
      } else {
        continue;
      }
      final index = _Index(
        indexName,
        table,
        terms,
        rootPage: rootPage,
        unique: unique,
        where: sql is String ? statement?.where : null,
        schemaSql: sql is String ? sql : null,
      );
      _indexes[_key(index.name)] = index;
      table.indexes.add(index);
    }
    for (final schemaRow in schemaRows) {
      if (schemaRow.values.length < 5 ||
          schemaRow.values[0] != 'trigger' ||
          schemaRow.values[4] is! String) {
        continue;
      }
      final sql = schemaRow.values[4] as String;
      final statement = _Parser(sql).parse();
      if (statement is _CreateTrigger) {
        statement.schemaSql = sql;
        _triggers[_key(statement.name)] = statement;
      }
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
    final modules = {
      for (final table in [..._tables.values, ..._temporaryTables.values])
        if (table.virtualTable case final module?) module,
    };
    for (final module in modules) {
      _disposeVirtualTable(module);
    }
    for (final attached in _attachedDatabases.values) {
      attached.database.close();
    }
    _attachedDatabases.clear();
    _pager?.close();
  }

  int _update(_Update statement, List<Object?> parameters) {
    final view = _viewDmlTable(statement.table, 'UPDATE');
    if (view != null) return _updateView(statement, view, parameters);
    final table = _table(statement.table);
    final updatedColumns = {
      for (final assignment in statement.assignments)
        for (final column in assignment.columns) _key(column),
    };
    final rowIds = [
      for (var index = 0; index < table.rows.length; index++)
        if (_matches(statement.where, _tableDmlRow(table, index), parameters))
          table.rowIds[index],
    ];
    if (rowIds.isEmpty) return 0;
    final before = _snapshotRows();
    final changedTables = <_Table>{table};
    var count = 0;
    try {
      updateRows:
      for (final rowId in rowIds) {
        final rowIndex = table.rowIds.indexOf(rowId);
        if (rowIndex < 0) continue;
        final row = table.rows[rowIndex];
        final next = Map<String, Object?>.from(row);
        var replacementRowId = rowId;
        for (final assignment in statement.assignments) {
          final assignedRowId = _assignValues(
            table,
            next,
            assignment.columns,
            _evalQueryExpression(
              assignment.expression,
              _tableDmlRow(table, rowIndex),
              parameters,
            ),
          );
          if (assignedRowId case _RowIdAssignment(:final value)) {
            replacementRowId = value == null ? table.nextRowId : _asInt(value);
          }
        }
        final rowIdColumn = table.rowIdColumn;
        if (rowIdColumn != null) {
          replacementRowId = _asInt(next[rowIdColumn.name]);
        }
        final returningRow = _returningRow(
          table,
          next,
          statement.returning,
          parameters,
          rowId: replacementRowId,
        );
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
              _deleteRowWithActions(
                table,
                conflictRowId,
                changedTables,
                {},
                fireParentTrigger: _recursiveTriggers,
              );
            } else {
              final oldConflictRow = Map<String, Object?>.from(
                table.rows[conflictIndex],
              );
              if (_recursiveTriggers) {
                _fireTriggers(
                  table,
                  'DELETE',
                  timing: 'BEFORE',
                  oldRow: oldConflictRow,
                  oldRowId: conflictRowId,
                );
              }
              table.rows.removeAt(conflictIndex);
              table.rowIds.removeAt(conflictIndex);
              changedTables.add(table);
              if (_recursiveTriggers) {
                _fireTriggers(
                  table,
                  'DELETE',
                  oldRow: oldConflictRow,
                  oldRowId: conflictRowId,
                );
              }
            }
          }
        }
        final rowBefore =
            statement.conflict == 'ignore' || statement.conflict == 'fail'
            ? _snapshotRows()
            : null;
        final changedBefore = Set<_Table>.from(changedTables);
        try {
          _updateRowWithActions(
            table,
            rowId,
            next,
            changedTables,
            {},
            updatedColumns: updatedColumns,
            replacementRowId: rowIdColumn == null ? replacementRowId : null,
          );
          for (final changed in changedTables) {
            for (final index in changed.indexes) {
              _validateIndexRows(index, changed.rows);
            }
          }
        } catch (error, stackTrace) {
          if (error is _TriggerRaiseException && _triggerExecutionDepth == 0) {
            if (error.action == 'IGNORE') {
              if (!error.before) {
                if (returningRow != null) {
                  _lastReturningRows.add(returningRow);
                }
                count++;
                break updateRows;
              }
              continue updateRows;
            }
            if (error.action == 'FAIL') {
              _rewriteChangedTables(changedTables);
              throw _ConflictFailException(
                error.error,
                stackTrace,
                count + (error.before ? 0 : 1),
              );
            }
          }
          if (rowBefore != null && _isIgnorableUpdateError(error, table)) {
            _restoreRows(rowBefore);
            changedTables.retainAll(changedBefore);
            if (statement.conflict == 'ignore') continue;
            _rewriteChangedTables(changedTables);
            throw _ConflictFailException(error, stackTrace, count);
          }
          rethrow;
        }
        if (returningRow != null) _lastReturningRows.add(returningRow);
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
      if (error is _TriggerRaiseException &&
          const ['IGNORE', 'FAIL'].contains(error.action) &&
          _triggerExecutionDepth > 0) {
        _rewriteChangedTables(changedTables);
        rethrow;
      }
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

  int _updateView(_Update statement, _Table view, List<Object?> parameters) {
    final updatedColumns = {
      for (final assignment in statement.assignments)
        for (final column in assignment.columns) _key(column),
    };
    final rowIndexes = [
      for (var index = 0; index < view.rows.length; index++)
        if (_matches(
          statement.where,
          _triggerEvalRow(view.rows[index]),
          parameters,
        ))
          index,
    ];
    if (rowIndexes.isEmpty) return 0;
    final before = _snapshotRows();
    try {
      for (final index in rowIndexes) {
        final oldRow = Map<String, Object?>.from(view.rows[index]);
        final newRow = Map<String, Object?>.from(oldRow);
        for (final assignment in statement.assignments) {
          _assignValues(
            view,
            newRow,
            assignment.columns,
            _evalQueryExpression(
              assignment.expression,
              _triggerEvalRow(oldRow),
              parameters,
            ),
          );
        }
        final returningRow = _returningRow(
          view,
          newRow,
          statement.returning,
          parameters,
        );
        try {
          _fireTriggers(
            view,
            'UPDATE',
            timing: 'INSTEAD OF',
            oldRow: oldRow,
            newRow: newRow,
            updatedColumns: updatedColumns,
          );
        } on _TriggerRaiseException catch (raise, stackTrace) {
          if (_triggerExecutionDepth > 0 &&
              const ['IGNORE', 'FAIL'].contains(raise.action)) {
            rethrow;
          }
          if (raise.action == 'IGNORE') continue;
          if (raise.action == 'FAIL') {
            throw _ConflictFailException(raise.error, stackTrace, 0);
          }
          rethrow;
        }
        if (returningRow != null) _lastReturningRows.add(returningRow);
      }
      return 0;
    } on _ConflictFailException {
      rethrow;
    } on _TriggerRaiseException catch (raise) {
      if (_triggerExecutionDepth > 0 &&
          const ['IGNORE', 'FAIL'].contains(raise.action)) {
        rethrow;
      }
      _restoreRows(before);
      rethrow;
    } catch (_) {
      _restoreRows(before);
      rethrow;
    }
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

  _RowIdAssignment? _assignValues(
    _Table table,
    SqlRow row,
    List<String> columns,
    Object? value,
  ) {
    final values = value is _SqlRowValue ? value.values : [value];
    if (values.any((item) => item is _SqlRowValue)) {
      throw PureSqlException('nested row value misused');
    }
    if (columns.length != values.length) {
      throw PureSqlException(
        'assignment column count does not match value count',
      );
    }
    _RowIdAssignment? rowIdAssignment;
    for (var index = 0; index < columns.length; index++) {
      if (table.isRowIdAlias(columns[index])) {
        final rowIdColumn = table.rowIdColumn;
        if (rowIdColumn == null) {
          rowIdAssignment = _RowIdAssignment(values[index]);
        } else {
          row[rowIdColumn.name] = values[index];
        }
      } else {
        row[table.column(columns[index]).name] = values[index];
      }
    }
    return rowIdAssignment;
  }

  int _delete(_Delete statement, List<Object?> parameters) {
    final view = _viewDmlTable(statement.table, 'DELETE');
    if (view != null) return _deleteView(statement, view, parameters);
    final table = _table(statement.table);
    final rowIds = [
      for (var index = table.rows.length - 1; index >= 0; index--)
        if (_matches(statement.where, _tableDmlRow(table, index), parameters))
          table.rowIds[index],
    ];
    if (rowIds.isEmpty) return 0;
    final before = _snapshotRows();
    final changedTables = <_Table>{};
    var count = 0;
    try {
      deleteRows:
      for (final rowId in rowIds) {
        final rowIndex = table.rowIds.indexOf(rowId);
        if (rowIndex < 0) continue;
        final oldRow = Map<String, Object?>.from(table.rows[rowIndex]);
        final returningRow = _returningRow(
          table,
          oldRow,
          statement.returning,
          parameters,
          rowId: rowId,
        );
        try {
          if (_foreignKeys) {
            _deleteRowWithActions(table, rowId, changedTables, {});
          } else {
            _fireTriggers(
              table,
              'DELETE',
              timing: 'BEFORE',
              oldRow: oldRow,
              oldRowId: rowId,
            );
            table.rows.removeAt(rowIndex);
            table.rowIds.removeAt(rowIndex);
            changedTables.add(table);
            _fireTriggers(table, 'DELETE', oldRow: oldRow, oldRowId: rowId);
          }
        } on _TriggerRaiseException catch (raise, stackTrace) {
          if (_triggerExecutionDepth > 0) rethrow;
          if (!table.rowIds.contains(rowId)) {
            if (returningRow != null) _lastReturningRows.add(returningRow);
            count++;
          }
          if (raise.action == 'IGNORE') {
            if (raise.before) continue deleteRows;
            break deleteRows;
          }
          if (raise.action == 'FAIL') {
            _rewriteChangedTables(changedTables);
            throw _ConflictFailException(raise.error, stackTrace, count);
          }
          rethrow;
        }
        if (!table.rowIds.contains(rowId)) {
          count++;
        }
        if (returningRow != null) _lastReturningRows.add(returningRow);
      }
      _rewriteChangedTables(changedTables);
    } on _ConflictFailException {
      rethrow;
    } on _TriggerRaiseException catch (raise) {
      if (const ['IGNORE', 'FAIL'].contains(raise.action) &&
          _triggerExecutionDepth > 0) {
        _rewriteChangedTables(changedTables);
        rethrow;
      }
      _restoreRows(before);
      rethrow;
    } catch (_) {
      _restoreRows(before);
      rethrow;
    }
    return count;
  }

  int _deleteView(_Delete statement, _Table view, List<Object?> parameters) {
    final rowIndexes = [
      for (var index = view.rows.length - 1; index >= 0; index--)
        if (_matches(
          statement.where,
          _triggerEvalRow(view.rows[index]),
          parameters,
        ))
          index,
    ];
    if (rowIndexes.isEmpty) return 0;
    final before = _snapshotRows();
    try {
      for (final index in rowIndexes) {
        final oldRow = Map<String, Object?>.from(view.rows[index]);
        final returningRow = _returningRow(
          view,
          oldRow,
          statement.returning,
          parameters,
        );
        try {
          _fireTriggers(view, 'DELETE', timing: 'INSTEAD OF', oldRow: oldRow);
        } on _TriggerRaiseException catch (raise, stackTrace) {
          if (_triggerExecutionDepth > 0 &&
              const ['IGNORE', 'FAIL'].contains(raise.action)) {
            rethrow;
          }
          if (raise.action == 'IGNORE') continue;
          if (raise.action == 'FAIL') {
            throw _ConflictFailException(raise.error, stackTrace, 0);
          }
          rethrow;
        }
        if (returningRow != null) _lastReturningRows.add(returningRow);
      }
      return 0;
    } on _ConflictFailException {
      rethrow;
    } on _TriggerRaiseException catch (raise) {
      if (_triggerExecutionDepth > 0 &&
          const ['IGNORE', 'FAIL'].contains(raise.action)) {
        rethrow;
      }
      _restoreRows(before);
      rethrow;
    } catch (_) {
      _restoreRows(before);
      rethrow;
    }
  }

  Map<_Table, (List<SqlRow>, List<int>, int, Map<int, int>)> _snapshotRows() =>
      {
        for (final table in [..._tables.values, ..._temporaryTables.values])
          table: (
            table.rows.map((row) => Map<String, Object?>.from(row)).toList(),
            List<int>.from(table.rowIds),
            table.nextRowId,
            Map<int, int>.from(table.recordOffsets),
          ),
      };

  void _restoreRows(
    Map<_Table, (List<SqlRow>, List<int>, int, Map<int, int>)> snapshot,
  ) {
    for (final entry in snapshot.entries) {
      entry.key.rows
        ..clear()
        ..addAll(entry.value.$1);
      entry.key.rowIds
        ..clear()
        ..addAll(entry.value.$2);
      entry.key.nextRowId = entry.value.$3;
      entry.key.recordOffsets
        ..clear()
        ..addAll(entry.value.$4);
      _restoreVirtualTableState(entry.key, entry.key.rows, entry.key.rowIds);
    }
  }

  void _rewriteChangedTables(Set<_Table> tables) {
    final pager = _pager;
    for (final table in tables) {
      if (table.virtualTable case final module?) {
        module.replaceRows([
          for (var index = 0; index < table.rows.length; index++)
            SqlVirtualTableRow(
              table.rowIds[index],
              Map<String, Object?>.from(table.rows[index]),
            ),
        ]);
        _dirtyVirtualTables.add(module);
        continue;
      }
      if (pager == null) continue;
      if (table.isTemporary) continue;
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
    _refreshTableRecordOffsets(pager, table);
  }

  void _refreshTableRecordOffsets(SqlitePagerSync pager, _Table table) {
    table.recordOffsets
      ..clear()
      ..addEntries([
        for (final row in SqliteTableBtree.readTree(pager, table.rootPage!))
          if (row.recordOffset case final offset?) MapEntry(row.rowId, offset),
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
          for (final term in index.terms)
            _eval(term.expression, index.table.rows[row], const []),
        ]),
  ];

  int _compareIndexEntries(
    _Index index,
    SqliteIndexEntry left,
    SqliteIndexEntry right,
  ) {
    for (var position = 0; position < index.terms.length; position++) {
      final term = index.terms[position];
      final result = _compare(
        left.values[position],
        right.values[position],
        noCase: _indexTermCollation(index.table, term) == 'NOCASE',
      );
      if (result != 0) return term.descending ? -result : result;
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
        for (final term in index.terms) {
          final a = _eval(term.expression, indexedRows[left], const []);
          final b = _eval(term.expression, indexedRows[right], const []);
          if (a == null || b == null) {
            hasNull = true;
          } else if (_compare(
                a,
                b,
                noCase: _indexTermCollation(index.table, term) == 'NOCASE',
              ) !=
              0) {
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
      final parent = _foreignKeyParent(table, foreignKey.table);
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

  void _validateDeferredForeignKeys() {
    if (!_foreignKeys || !_deferForeignKeys) return;
    for (final table in [..._tables.values, ..._temporaryTables.values]) {
      for (final row in table.rows) {
        _validateForeignKeys(table, row);
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

  _Table? _foreignKeyParent(_Table child, String name) =>
      (child.isTemporary ? _temporaryTables : _tables)[_key(name)];

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
    Set<(_Table, int)> visiting, {
    bool fireParentTrigger = true,
  }) {
    final identity = (parent, parentRowId);
    if (!visiting.add(identity)) return;
    try {
      final parentIndex = parent.rowIds.indexOf(parentRowId);
      if (parentIndex < 0) return;
      final parentRow = Map<String, Object?>.from(parent.rows[parentIndex]);
      if (fireParentTrigger) {
        _fireTriggers(
          parent,
          'DELETE',
          timing: 'BEFORE',
          oldRow: parentRow,
          oldRowId: parentRowId,
        );
      }
      parent.rows.removeAt(parentIndex);
      parent.rowIds.removeAt(parentIndex);
      changedTables.add(parent);
      for (final child in [..._tables.values, ..._temporaryTables.values]) {
        for (final foreignKey in _foreignKeysFor(child)) {
          if (!identical(_foreignKeyParent(child, foreignKey.table), parent)) {
            continue;
          }
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
              case 'NO ACTION':
                if (!_deferForeignKeys) {
                  throw PureSqlException('FOREIGN KEY constraint failed');
                }
              case 'RESTRICT':
                throw PureSqlException('FOREIGN KEY constraint failed');
            }
          }
        }
      }
      if (fireParentTrigger) {
        _fireTriggers(
          parent,
          'DELETE',
          oldRow: parentRow,
          oldRowId: parentRowId,
        );
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
    Set<(_Table, int)> visiting, {
    Set<String>? updatedColumns,
    int? replacementRowId,
    bool fireParentTrigger = true,
  }) {
    final identity = (parent, parentRowId);
    if (!visiting.add(identity)) return;
    try {
      final parentIndex = parent.rowIds.indexOf(parentRowId);
      if (parentIndex < 0) return;
      final oldParentRow = Map<String, Object?>.from(parent.rows[parentIndex]);
      final rowIdColumn = parent.rowIdColumn;
      final nextParentRowId = rowIdColumn != null
          ? _asInt(nextParentRow[rowIdColumn.name])
          : replacementRowId ?? parentRowId;
      final columns =
          updatedColumns ??
          {
            for (final column in parent.columns)
              if (!_equal(
                oldParentRow[column.name],
                nextParentRow[column.name],
              ))
                _key(column.name),
          };
      final actions = <(_Table, _ForeignKey, List<int>)>[];
      if (_foreignKeys) {
        for (final child in [..._tables.values, ..._temporaryTables.values]) {
          for (final foreignKey in _foreignKeysFor(child)) {
            if (!identical(
              _foreignKeyParent(child, foreignKey.table),
              parent,
            )) {
              continue;
            }
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
      if (fireParentTrigger) {
        _fireTriggers(
          parent,
          'UPDATE',
          timing: 'BEFORE',
          oldRow: oldParentRow,
          newRow: nextParentRow,
          oldRowId: parentRowId,
          newRowId: nextParentRowId,
          updatedColumns: columns,
        );
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
            case 'NO ACTION':
              if (!_deferForeignKeys) {
                throw PureSqlException('FOREIGN KEY constraint failed');
              }
            case 'RESTRICT':
              throw PureSqlException('FOREIGN KEY constraint failed');
          }
          _updateRowWithActions(
            child,
            childRowId,
            childNext,
            changedTables,
            visiting,
            updatedColumns: {for (final name in foreignKey.columns) _key(name)},
          );
        }
      }
      final index = parent.rows.indexOf(current);
      if (index >= 0) {
        _validate(parent, current, ignore: current);
        final nextRowId = rowIdColumn != null
            ? _asInt(current[rowIdColumn.name])
            : replacementRowId;
        if (nextRowId != null) {
          final invalidRowId = parent.virtualTable != null
              ? nextRowId < -0x8000000000000000 ||
                    nextRowId > 0x7fffffffffffffff
              : nextRowId < 1;
          if (invalidRowId ||
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
      if (fireParentTrigger) {
        _fireTriggers(
          parent,
          'UPDATE',
          oldRow: oldParentRow,
          newRow: nextParentRow,
          oldRowId: parentRowId,
          newRowId: nextParentRowId,
          updatedColumns: columns,
        );
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
        : statement.tableFunction != null
        ? _materializeTableFunction(
            statement.tableFunction!,
            outerRow,
            parameters,
          )
        : statement.table == null
        ? null
        : _selectTable(statement.table!, statement.ctes, parameters);
    if (table == null &&
        statement.fromQuery == null &&
        statement.tableFunction == null &&
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
          Map<String, Object?>.from(outerRow)..addAll(
            _qualifiedRow(
              table,
              table.rows[index],
              statement.alias,
              rowId: table.rowIds[index],
            ),
          ),
        );
      }
    }
    final sourceTables = <(_Table, String?)>[
      if (table != null) (table, statement.alias),
    ];
    for (final join in statement.joins) {
      final joinedTable = join.tableFunction != null
          ? _emptyTableFunction(join.tableFunction!.name)
          : join.query == null
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
        growable: true,
      );
      final next = <SqlRow>[];
      for (final leftRow in joinedRows) {
        var matched = false;
        final rightRows = join.tableFunction == null
            ? joinedTable.rows
            : _materializeTableFunction(
                join.tableFunction!,
                leftRow,
                parameters,
              ).rows;
        for (var index = 0; index < rightRows.length; index++) {
          if (index >= matchedRightRows.length) {
            matchedRightRows.addAll(
              List<bool>.filled(index - matchedRightRows.length + 1, false),
            );
          }
          final rightRow = rightRows[index];
          final combined = Map<String, Object?>.from(leftRow)
            ..addAll(
              _qualifiedRow(
                joinedTable,
                rightRow,
                join.alias,
                rowId: index < joinedTable.rowIds.length
                    ? joinedTable.rowIds[index]
                    : null,
              ),
            );
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
              combined['@@sqlite_offset:${_key(column)}'] = _readSqliteOffset(
                row: leftRow,
                name: column,
              );
            }
            next.add(combined);
            matched = true;
            matchedRightRows[index] = true;
          }
        }
        if (!matched && (join.type == 'LEFT' || join.type == 'FULL')) {
          final combined = Map<String, Object?>.from(leftRow)
            ..addAll(
              _qualifiedRow(
                joinedTable,
                const {},
                join.alias,
                includeUnqualifiedOffset: false,
              ),
            );
          for (final column in usingColumns) {
            combined[leftColumnNames[_key(column)]!] = _readColumn(
              leftRow,
              column,
            );
            combined['@@sqlite_offset:${_key(column)}'] = _readSqliteOffset(
              row: leftRow,
              name: column,
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
        final unmatchedRightRows = join.tableFunction == null
            ? joinedTable.rows
            : _materializeTableFunction(
                join.tableFunction!,
                nullLeftRow,
                parameters,
              ).rows;
        for (var index = 0; index < unmatchedRightRows.length; index++) {
          if (index < matchedRightRows.length && matchedRightRows[index]) {
            continue;
          }
          final rightRow = unmatchedRightRows[index];
          final combined = Map<String, Object?>.from(nullLeftRow)
            ..addAll(
              _qualifiedRow(
                joinedTable,
                rightRow,
                join.alias,
                rowId: index < joinedTable.rowIds.length
                    ? joinedTable.rowIds[index]
                    : null,
              ),
            );
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

    final windowFunctions = <_WindowFunction>{};
    for (final item in statement.items) {
      windowFunctions.addAll(_windowFunctions(item.expression));
    }
    for (final order in statement.orderBy) {
      windowFunctions.addAll(_windowFunctions(order.expression));
    }
    final groupedWindowAggregate = windowFunctions.any(
      (window) =>
          window.function.arguments.any(_containsAggregate) ||
          window.partitionBy.any(_containsAggregate) ||
          window.orderBy.any((order) => _containsAggregate(order.expression)),
    );
    final groupedQuery =
        statement.groupBy.isNotEmpty ||
        statement.having != null ||
        statement.items.any((item) => _containsAggregate(item.expression)) ||
        statement.orderBy.any(
          (order) => _containsAggregate(order.expression),
        ) ||
        groupedWindowAggregate;
    if (windowFunctions.isNotEmpty && !groupedQuery) {
      for (final window in windowFunctions) {
        _evaluateWindowFunction(
          window,
          rows,
          parameters,
          _evalQueryExpression,
          _runSubquery,
        );
      }
    }

    if (groupedQuery) {
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
      if (windowFunctions.isNotEmpty) {
        final groupsByWindowRow = Map<SqlRow, List<SqlRow>>.identity();
        final windowRows = <SqlRow>[];
        for (final group in selectedGroups) {
          final row = group.isEmpty ? <String, Object?>{} : group.first;
          groupsByWindowRow[row] = group;
          windowRows.add(row);
        }
        Object? evaluateGrouped(
          _Expr expression,
          SqlRow row,
          List<Object?> parameters,
        ) {
          final group = groupsByWindowRow[row]!;
          return _evalGroup(
            expression,
            group,
            group.isEmpty ? row : group.first,
            parameters,
            selectSubquery: _runSubquery,
          );
        }

        Object? evaluateWindowAggregate(
          _Function function,
          List<SqlRow> frameRows,
          SqlRow row,
          List<Object?> parameters,
        ) {
          if (function.arguments.any(
            (argument) => argument is _Column && argument.name == '*',
          )) {
            return _evalGroup(
              function,
              frameRows,
              row,
              parameters,
              selectSubquery: _runSubquery,
            );
          }
          final names = [
            for (var index = 0; index < function.arguments.length; index++)
              'window-aggregate:$index',
          ];
          final values = [
            for (final frameRow in frameRows)
              <String, Object?>{
                for (final (index, argument) in function.arguments.indexed)
                  '@${names[index]}': evaluateGrouped(
                    argument,
                    frameRow,
                    parameters,
                  ),
              },
          ];
          return _evalGroup(
            _Function(function.name, [
              for (final name in names) _Column(name),
            ], distinct: function.distinct),
            values,
            values.isEmpty ? const {} : values.first,
            parameters,
            selectSubquery: _runSubquery,
          );
        }

        for (final window in windowFunctions) {
          _evaluateWindowFunction(
            window,
            windowRows,
            parameters,
            evaluateGrouped,
            _runSubquery,
            evaluateAggregate: evaluateWindowAggregate,
          );
        }
      }
      var grouped = [
        for (final group in selectedGroups)
          _projectGroup(
            group,
            statement.items,
            parameters,
            sources: sourceTables,
            selectSubquery: _runSubquery,
          ),
      ];
      if (statement.orderBy.isNotEmpty) {
        final positions = List<int>.generate(grouped.length, (index) => index);
        positions.sort((left, right) {
          for (final order in statement.orderBy) {
            final result = _compareOrderValues(
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
              order,
            );
            if (result != 0) return result;
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
          final result = _compareOrderValues(
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
            order,
          );
          if (result != 0) return result;
        }
        return 0;
      });
    }
    if (_reverseUnorderedSelects && statement.orderBy.isEmpty) {
      rows = rows.reversed.toList();
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
      for (final row in rows)
        _project(row, statement.items, parameters, sourceTables),
    ];
    return statement.distinct ? _distinctRows(result) : result;
  }

  _Table _emptyTableFunction(String name) =>
      _Table(name, _tableFunctionColumns(name));

  _Table _materializeTableFunction(
    _TableFunction function,
    SqlRow row,
    List<Object?> parameters,
  ) {
    if (function.name.startsWith('pragma_')) {
      return _materializePragmaTableFunction(function, row, parameters);
    }
    final values = [
      for (final argument in function.arguments)
        _evalQueryExpression(argument, row, parameters),
    ];
    if (values.isEmpty || values.length > 2) {
      throw PureSqlException('${function.name} expects one or two arguments');
    }
    if (values.first == null || values.length == 2 && values[1] == null) {
      return _emptyTableFunction(function.name);
    }
    final json = _decodeSqlJson(values.first);
    final path = values.length == 1 ? r'$' : values[1]!.toString();
    final parts = _parseJsonPath(path);
    final selected = _jsonPathValue(json, path);
    final table = _emptyTableFunction(function.name);
    if (selected == _missingJsonPath) return table;
    table.rows.addAll(_jsonTableFunctionRows(function.name, selected, parts));
    table.rowIds.addAll(
      List<int>.generate(table.rows.length, (index) => index + 1),
    );
    return table;
  }

  _Table _materializePragmaTableFunction(
    _TableFunction function,
    SqlRow row,
    List<Object?> parameters,
  ) {
    final name = function.name.substring('pragma_'.length);
    final maximumArguments = _pragmaTableFunctionMaxArguments[name] ?? 0;
    if (function.arguments.length > maximumArguments) {
      throw PureSqlException(
        'too many arguments on pragma_$name() - max $maximumArguments',
      );
    }
    final values = [
      for (final argument in function.arguments)
        _evalQueryExpression(argument, row, parameters),
    ];
    final tableArgument = values.isEmpty ? null : values.first;
    final schema = values.length > 1 ? values[1]?.toString() : function.schema;
    if (const {
          'foreign_key_list',
          'index_info',
          'index_list',
          'index_xinfo',
          'table_info',
          'table_xinfo',
        }.contains(name) &&
        tableArgument == null) {
      return _emptyTableFunction(function.name);
    }

    final pragma = _Pragma(
      name,
      null,
      argument: tableArgument == null ? null : _Literal(tableArgument),
      schema: schema,
    );
    if (schema != null && _key(schema) == 'temp') {
      _temporaryDatabaseOpened = true;
    }
    final attached =
        schema == null || const {'main', 'temp'}.contains(_key(schema))
        ? null
        : _attachedDatabases[_key(schema)];
    if (schema != null &&
        attached == null &&
        !const {'main', 'temp'}.contains(_key(schema))) {
      throw PureSqlException('no such database: $schema');
    }

    List<SqlRow> rows;
    try {
      rows = attached == null
          ? _pragmaRows(pragma, const [])
          : attached.database._withCurrentFile(
              () => attached.database._withSqlFunctions(
                () => attached.database._pragmaRows(
                  _Pragma(name, null, argument: pragma.argument),
                  const [],
                ),
              ),
            );
    } on PureSqlException catch (error) {
      if (error.message.startsWith('no such table:') &&
              const {
                'foreign_key_list',
                'index_list',
                'table_info',
                'table_xinfo',
              }.contains(name) ||
          error.message.startsWith('no such index:') &&
              const {'index_info', 'index_xinfo'}.contains(name)) {
        return _emptyTableFunction(function.name);
      }
      rethrow;
    }
    return _emptyTableFunction(function.name)
      ..rows.addAll(rows)
      ..rowIds.addAll(List<int>.generate(rows.length, (index) => index + 1));
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
      tableFunction: query.tableFunction,
      namedWindows: query.namedWindows,
      startToken: query.startToken,
      endToken: query.endToken,
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
          final comparison = _compareOrderValues(leftValue, rightValue, order);
          if (comparison != 0) return comparison;
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
    final separator = name.indexOf('\u0000');
    if (separator >= 0) {
      return _selectSchemaTable(
        name.substring(0, separator),
        name.substring(separator + 1),
        parameters,
      );
    }
    final key = _key(name);
    final recursiveTable = _recursiveCteTables[key];
    if (recursiveTable != null) return recursiveTable;
    if (_materializingRecursiveCtes.contains(key)) {
      throw PureSqlException(
        'recursive CTE referenced outside its recursive arm',
      );
    }
    final cte = ctes[key];
    if (cte != null) return _materializeQuery(name, cte, parameters);
    final queryContext = _attachedQueryContext;
    if (queryContext != null) {
      return queryContext._selectTable(name, ctes, parameters);
    }
    final temporary = _temporaryTables[key];
    if (temporary != null) return _currentTable(temporary);
    final view = _temporaryViews[key] ?? _views[key];
    if (view == null) {
      final mainTable = _tables[key];
      if (mainTable != null) return _currentTable(mainTable);
      for (final attached in _attachedDatabases.values) {
        final table = identical(attached.database, _activeAttachedWriteDatabase)
            ? attached.database._tryResolveMainSchemaTable(name, parameters)
            : attached.database._withCurrentFile(
                () => attached.database._tryResolveMainSchemaTable(
                  name,
                  parameters,
                ),
              );
        if (table != null) {
          if (_inTransaction)
            _transactionAttachedDatabases.add(attached.database);
          return _currentTable(table);
        }
      }
      throw PureSqlException('no such table: $name');
    }
    if (!_viewStack.add(key)) {
      throw PureSqlException('circular view reference: ${view.name}');
    }
    try {
      final table = _materializeQuery(
        name,
        _Cte(view.query, view.columns),
        parameters,
      );
      table.isTemporary = view.temporary;
      return table;
    } finally {
      _viewStack.remove(key);
    }
  }

  _Table _selectSchemaTable(
    String schema,
    String name,
    List<Object?> parameters,
  ) {
    final schemaKey = _key(schema);
    if (schemaKey == 'main') {
      final override = _schemaMainOverride;
      if (override != null) {
        return override._resolveMainSchemaTable(name, parameters);
      }
      return _resolveMainSchemaTable(name, parameters);
    }
    if (schemaKey == 'temp') {
      final override = _schemaTempOverride;
      if (override != null) {
        return override._selectSchemaTable('temp', name, parameters);
      }
      final table = _temporaryTables[_key(name)];
      if (table != null) return _currentTable(table);
      final view = _temporaryViews[_key(name)];
      if (view == null) throw PureSqlException('no such table: $schema.$name');
      return _materializeSchemaView(view, parameters);
    }
    final attached = _attachedDatabases[schemaKey];
    if (attached == null) {
      throw PureSqlException('no such table: $schema.$name');
    }
    if (_inTransaction) _transactionAttachedDatabases.add(attached.database);
    if (identical(attached.database, this) ||
        identical(attached.database, _activeAttachedWriteDatabase)) {
      return attached.database._resolveMainSchemaTable(name, parameters);
    }
    return attached.database._withCurrentFile(
      () => attached.database._resolveMainSchemaTable(name, parameters),
    );
  }

  _Table _resolveMainSchemaTable(String name, List<Object?> parameters) {
    final table = _tryResolveMainSchemaTable(name, parameters);
    if (table != null) return table;
    throw PureSqlException('no such table: $name');
  }

  _Table? _tryResolveMainSchemaTable(String name, List<Object?> parameters) {
    final table = _tables[_key(name)];
    if (table != null) return _currentTable(table);
    final view = _views[_key(name)];
    if (view == null) return null;
    return _materializeSchemaView(view, parameters);
  }

  _Table _materializeSchemaView(_CreateView view, List<Object?> parameters) {
    final key = _key(view.name);
    if (!_viewStack.add(key)) {
      throw PureSqlException('circular view reference: ${view.name}');
    }
    try {
      final table = _materializeQuery(
        view.name,
        _Cte(view.query, view.columns),
        parameters,
      );
      table.isTemporary = view.temporary;
      return table;
    } finally {
      _viewStack.remove(key);
    }
  }

  _Table _materializeQuery(String name, _Cte query, List<Object?> parameters) {
    if (query.recursive) {
      final key = _key(name);
      if (!_materializingRecursiveCtes.add(key)) {
        throw PureSqlException('circular recursive CTE: $name');
      }
      try {
        return _materializeRecursiveQuery(name, query, parameters);
      } finally {
        _materializingRecursiveCtes.remove(key);
      }
    }
    final rows = _select(query.query, parameters);
    final resultNames = _materializedColumnNames(query.query, rows, parameters);
    final names = query.columns ?? resultNames;
    if (resultNames.length != names.length) {
      throw PureSqlException('CTE column count does not match its query');
    }
    final definitions = _queryColumnDefinitions(query.query, parameters);
    return _Table(name, [
        for (var index = 0; index < names.length; index++)
          _ColumnDef(
            names[index],
            typeName: definitions.length == names.length
                ? definitions[index].typeName
                : null,
          ),
      ])
      ..rows.addAll([
        for (final row in rows)
          {
            for (var index = 0; index < names.length; index++)
              names[index]: row.values.elementAt(index),
          },
      ])
      ..rowIds.addAll(List<int>.generate(rows.length, (index) => index + 1));
  }

  _Table _materializeRecursiveQuery(
    String name,
    _Cte cte,
    List<Object?> parameters,
  ) {
    final query = cte.query;
    final anchorTerms = query.compoundTerms
        .take(cte.recursiveTermIndex)
        .toList();
    final recursiveTerms = query.compoundTerms
        .skip(cte.recursiveTermIndex)
        .toList();
    final recursiveOperator = recursiveTerms.first;
    if (recursiveOperator.operator != 'UNION' ||
        recursiveTerms.any(
          (term) =>
              term.operator != recursiveOperator.operator ||
              term.all != recursiveOperator.all,
        )) {
      throw PureSqlException(
        'recursive CTE arms must use the same UNION or UNION ALL operator',
      );
    }
    final seedQuery = _withoutCompoundTerms(query, anchorTerms);
    var rows = _select(seedQuery, parameters);
    final names =
        cte.columns ?? _materializedColumnNames(seedQuery, rows, parameters);
    if (rows.any((row) => row.length != names.length)) {
      throw PureSqlException('CTE column count does not match its query');
    }
    final queue = Queue<SqlRow>.from(_relabelRows(rows, names));
    if (!recursiveOperator.all) {
      final unique = _uniqueRows(queue.toList());
      queue
        ..clear()
        ..addAll(unique);
    }
    final seen = recursiveOperator.all ? <SqlRow>[] : List<SqlRow>.from(queue);
    final result = <SqlRow>[];
    var offset = query.offset == null
        ? 0
        : math
              .max(
                0,
                _asInt(
                  _evalQueryExpression(query.offset!, const {}, parameters),
                ),
              )
              .toInt();
    final limit = query.limit == null
        ? -1
        : _asInt(_evalQueryExpression(query.limit!, const {}, parameters));
    final key = _key(name);
    try {
      while (queue.isNotEmpty) {
        if (query.orderBy.isNotEmpty) {
          final orderedQueue = queue.toList()
            ..sort((left, right) {
              for (final order in query.orderBy) {
                final comparison = _compareOrderValues(
                  _compoundOrderValue(
                    order.expression,
                    left,
                    names,
                    parameters,
                  ),
                  _compoundOrderValue(
                    order.expression,
                    right,
                    names,
                    parameters,
                  ),
                  order,
                );
                if (comparison != 0) return comparison;
              }
              return 0;
            });
          queue
            ..clear()
            ..addAll(orderedQueue);
        }
        final current = queue.removeFirst();
        if (offset > 0) {
          offset--;
        } else {
          if (limit == 0 || limit > 0 && result.length >= limit) break;
          result.add(current);
          if (limit > 0 && result.length >= limit) break;
        }

        _recursiveCteTables[key] = _tableFromRows(name, names, [current]);
        for (final term in recursiveTerms) {
          for (final candidate in _relabelRows(
            _select(term.query, parameters),
            names,
          )) {
            if (!recursiveOperator.all) {
              if (seen.any(
                (row) => _compoundRowsEqual(row, candidate, names),
              )) {
                continue;
              }
              seen.add(candidate);
            }
            queue.add(candidate);
          }
        }
      }
    } finally {
      _recursiveCteTables.remove(key);
    }
    return _tableFromRows(name, names, result);
  }

  _Table _tableFromRows(String name, List<String> names, List<SqlRow> rows) =>
      _Table(name, [for (final column in names) _ColumnDef(column)])
        ..rows.addAll([
          for (final row in rows)
            {for (final column in names) column: row[column]},
        ])
        ..rowIds.addAll(List<int>.generate(rows.length, (index) => index + 1));

  _Select _withoutCompoundTerms(
    _Select query, [
    List<_CompoundTerm> compoundTerms = const [],
  ]) => _Select(
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
    tableFunction: query.tableFunction,
    compoundTerms: compoundTerms,
    namedWindows: query.namedWindows,
    startToken: query.startToken,
    endToken: query.endToken,
  );

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
        if (query.tableFunction != null) {
          return _tableFunctionColumns(
            query.tableFunction!.name,
          ).map((column) => column.name).toList();
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

  String _resultColumnName(_SelectItem item, List<(_Table, String?)> sources) {
    final expression = item.expression;
    if (item.explicitAlias ||
        expression is! _Column ||
        expression.name == '*' ||
        expression.name.endsWith('.*')) {
      return item.outputName;
    }
    final unqualifiedColumn = sources.any(
      (entry) =>
          entry.$1.columns.any(
            (column) => _key(column.name) == _key(expression.name),
          ) ||
          entry.$1.isRowIdAlias(expression.name),
    );
    final separator = unqualifiedColumn ? -1 : expression.name.lastIndexOf('.');
    final columnName = separator < 0
        ? expression.name
        : expression.name.substring(separator + 1);
    if (separator >= 0) {
      if (!_fullColumnNames && _shortColumnNames) return columnName;
      final qualifier = expression.name.substring(0, separator);
      final source = sources.where(
        (entry) =>
            _key(entry.$1.name) == _key(qualifier) ||
            _key(entry.$2 ?? '') == _key(qualifier),
      );
      return source.isEmpty
          ? item.outputName
          : '${source.first.$1.name}.$columnName';
    }
    if (_fullColumnNames) {
      for (final (table, _) in sources) {
        if (table.columns.any(
              (column) => _key(column.name) == _key(columnName),
            ) ||
            table.isRowIdAlias(columnName)) {
          return '${table.name}.$columnName';
        }
      }
    }
    return item.outputName;
  }

  SqlRow _projectGroup(
    List<SqlRow> group,
    List<_SelectItem> items,
    List<Object?> parameters, {
    List<(_Table, String?)> sources = const [],
    List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
  }) {
    final row = group.isEmpty ? <String, Object?>{} : group.first;
    return <String, Object?>{
      for (final item in items)
        _resultColumnName(item, sources): item.expression is _ScalarSubquery
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

  SqlRow _qualifiedRow(
    _Table table,
    SqlRow row,
    String? alias, {
    int? rowId,
    bool includeUnqualifiedOffset = true,
  }) {
    final result = <String, Object?>{...row};
    if (rowId != null) {
      for (final name in const ['rowid', '_rowid_', 'oid']) {
        if (table.columns.any((column) => _key(column.name) == name)) continue;
        result['@$name'] = rowId;
        result['@${table.name}.$name'] = rowId;
        if (alias != null) result['@$alias.$name'] = rowId;
      }
    }
    for (final column in table.columns) {
      final value = row[column.name];
      final offset = rowId == null ? null : table.recordOffsets[rowId];
      if (includeUnqualifiedOffset) {
        result['@@sqlite_offset:${_key(column.name)}'] = offset;
      }
      result['@@sqlite_offset:${_key(table.name)}.${_key(column.name)}'] =
          offset;
      if (alias != null) {
        result['@@sqlite_offset:${_key(alias)}.${_key(column.name)}'] = offset;
      }
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
          index.terms.length != 1 ||
          index.terms.single.expression is! _Column ||
          _key((index.terms.single.expression as _Column).name) !=
              _key(column) ||
          index.rootPage == null) {
        continue;
      }
      return {
        for (final entry in SqliteIndexBtree.readTree(_pager!, index.rootPage!))
          if (_compare(
                entry.values.single,
                value,
                noCase:
                    _indexTermCollation(table, index.terms.single) == 'NOCASE',
              ) ==
              0)
            entry.rowId,
      };
    }
    return null;
  }

  SqlRow _project(
    SqlRow row,
    List<_SelectItem> items,
    List<Object?> parameters, [
    List<(_Table, String?)> sources = const [],
  ]) {
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
        final value = expression is _ScalarSubquery
            ? _selectScalar(expression, row, parameters)
            : _evalQueryExpression(expression, row, parameters);
        if (value is _SqlRowValue) {
          throw PureSqlException('row value misused');
        }
        result[_resultColumnName(item, sources)] = value;
      }
    }
    return result;
  }

  bool _matches(_Expr? expression, SqlRow row, List<Object?> parameters) {
    if (expression == null) return true;
    return _truthy(_evalQueryExpression(expression, row, parameters));
  }

  _Table _table(String name, {String? schema}) {
    if (schema != null) {
      final key = _key(name);
      final table = switch (_key(schema)) {
        'main' => _tables[key],
        'temp' => _temporaryTables[key],
        _ => null,
      };
      if (table != null) return _currentTable(table);
      throw PureSqlException('no such table: $schema.$name');
    }
    final separator = name.indexOf('\u0000');
    if (separator >= 0) {
      final schema = name.substring(0, separator);
      final table = name.substring(separator + 1);
      if (_key(schema) == 'main') {
        if (_schemaMainOverride != null) {
          throw PureSqlException(
            'writes to main from attached-database triggers are not supported',
          );
        }
        final mainTable = _tables[_key(table)];
        if (mainTable != null) return _currentTable(mainTable);
      } else if (_key(schema) == 'temp') {
        if (_schemaTempOverride != null) {
          throw PureSqlException(
            'writes to temp from attached-database triggers are not supported',
          );
        }
        final temporaryTable = _temporaryTables[_key(table)];
        if (temporaryTable != null) return _currentTable(temporaryTable);
      } else if (_attachedDatabases.containsKey(_key(schema))) {
        throw PureSqlException(
          'writes to attached databases are not supported: $schema.$table',
        );
      }
      throw PureSqlException('no such table: $schema.$table');
    }
    final key = _key(name);
    final table = _temporaryTables[key] ?? _tables[key];
    if (table != null) return _currentTable(table);
    for (final attached in _attachedDatabases.values) {
      final exists = attached.database._withCurrentFile(
        () =>
            attached.database._tables.containsKey(key) ||
            attached.database._views.containsKey(key),
      );
      if (exists) {
        throw PureSqlException(
          'writes to attached databases are not supported: ${attached.name}.$name',
        );
      }
    }
    throw PureSqlException('no such table: $name');
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
      if (!_ignoreCheckConstraints) {
        for (final check in column.checkExpressions) {
          final result = _eval(check, row, const []);
          if (result != null && !_truthy(result)) {
            throw PureSqlException(
              'CHECK constraint failed: ${table.name}.${column.name}',
            );
          }
        }
      }
    }
    if (!_ignoreCheckConstraints) {
      for (final check in table.checkExpressions) {
        final result = _eval(check, row, const []);
        if (result != null && !_truthy(result)) {
          throw PureSqlException('CHECK constraint failed: ${table.name}');
        }
      }
    }
    if (_foreignKeys && !_deferForeignKeys) {
      _validateForeignKeys(table, row);
    }
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

  /// Runs a `SELECT`, read-only `PRAGMA`, or DML row-producing statement.
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
  final namedValues = <String, Object?>{};
  final positionalValues = <int, Object?>{};
  for (final entry in parameters.entries) {
    if (entry.key is! String) {
      throw PureSqlException('parameter map keys must be strings');
    }
    final key = _parameterName(entry.key as String);
    final position = int.tryParse(key);
    if (position != null) {
      if (position < 1 || positionalValues.containsKey(position)) {
        throw PureSqlException('duplicate or invalid parameter slot: $key');
      }
      positionalValues[position] = entry.value;
    } else {
      if (key.isEmpty || namedValues.containsKey(key)) {
        throw PureSqlException('duplicate or empty named parameter: $key');
      }
      namedValues[key] = entry.value;
    }
  }

  final usedNames = <String>{};
  final usedPositions = <int>{};
  final values = List<Object?>.filled(parser.parameterCount, null);
  for (final entry in parser.namedParameters.entries) {
    final name = _parameterName(entry.key);
    if (!namedValues.containsKey(name)) {
      throw PureSqlException('missing named parameter: $name');
    }
    usedNames.add(name);
    values[entry.value] = _value(namedValues[name]);
  }
  for (final slot in parser.positionalParameters) {
    final position = slot + 1;
    if (!positionalValues.containsKey(position)) {
      throw PureSqlException('missing positional parameter: $position');
    }
    if (parser.namedParameters.values.contains(slot)) {
      throw PureSqlException(
        'parameter slot $position is bound more than once',
      );
    }
    usedPositions.add(position);
    values[slot] = _value(positionalValues[position]);
  }
  final unused = namedValues.keys.where((name) => !usedNames.contains(name));
  if (unused.isNotEmpty) {
    throw PureSqlException('unknown named parameter: ${unused.first}');
  }
  final unusedPositions = positionalValues.keys.where(
    (position) => !usedPositions.contains(position),
  );
  if (unusedPositions.isNotEmpty) {
    throw PureSqlException(
      'unknown positional parameter: ${unusedPositions.first}',
    );
  }
  return values;
}

String _parameterName(String name) => name.replaceFirst(RegExp(r'^[:@$?]'), '');

Object? _pragmaInput(_Expr expression, List<Object?> parameters) =>
    expression is _Column && !expression.name.contains('.')
    ? expression.name
    : _eval(expression, const {}, parameters);

String _journalModeName(Object? value) =>
    value is num && value == 0 ? 'off' : value.toString().toLowerCase();

String _key(String name) => name.toLowerCase();

String _renameSqlIdentifiersAfter(
  String sql,
  String oldName,
  String newName,
  String context,
) {
  final tokens = _Tokenizer(sql).tokenize();
  final targets = <_Token>[];
  final triggerBegin = context == 'trigger' || context == 'triggerTarget'
      ? tokens.indexWhere(
          (token) =>
              token.type == _TokenType.word &&
              !token.quoted &&
              token.text.toUpperCase() == 'BEGIN',
        )
      : -1;
  for (var index = 0; index < tokens.length - 1; index++) {
    final token = tokens[index];
    if (token.type != _TokenType.word || token.quoted) continue;
    final keyword = token.text.toUpperCase();
    var targetIndex = index + 1;
    if (context == 'table') {
      final previous = index == 0 ? '' : tokens[index - 1].text.toUpperCase();
      final temporaryCreate =
          const ['TEMP', 'TEMPORARY'].contains(previous) &&
          index > 1 &&
          tokens[index - 2].text.toUpperCase() == 'CREATE';
      if (keyword != 'TABLE' || previous != 'CREATE' && !temporaryCreate) {
        continue;
      }
      if (tokens[targetIndex].text.toUpperCase() == 'IF') targetIndex += 3;
    } else if (context == 'index') {
      if (keyword != 'ON') continue;
    } else if (context == 'references') {
      if (keyword != 'REFERENCES') continue;
    } else if (context == 'source') {
      if (keyword != 'FROM' && keyword != 'JOIN') continue;
    } else if (context == 'triggerTarget') {
      if (keyword != 'ON' || index >= triggerBegin) continue;
    } else if (context == 'trigger') {
      if (keyword == 'ON' && index < triggerBegin ||
          keyword == 'INTO' ||
          keyword == 'FROM' ||
          keyword == 'JOIN') {
        // These keywords are followed by a table name in trigger SQL.
      } else if (keyword == 'UPDATE') {
        if (tokens[targetIndex].text.toUpperCase() == 'OR') targetIndex += 2;
        if (tokens[targetIndex].text.toUpperCase() == 'OF') continue;
      } else {
        continue;
      }
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

bool _triggerReferencesTable(String sql, String tableName) =>
    _renameSqlIdentifiersAfter(
      sql,
      tableName,
      '__trigger_table_probe__',
      'trigger',
    ) !=
    sql;

({bool safe, List<_Token> tokens}) _triggerColumnReferences(
  String sql,
  String column,
  bool belongsToTable,
  _CreateTrigger trigger,
  String alteredTable,
  bool Function(String sourceName) sourceHasColumn,
) {
  final tokens = _Tokenizer(sql).tokenize();
  final begin = tokens.indexWhere(
    (token) =>
        token.type == _TokenType.word &&
        !token.quoted &&
        token.text.toUpperCase() == 'BEGIN',
  );
  if (begin < 0) return (safe: false, tokens: const []);
  final triggerKeyword = tokens.indexWhere(
    (token) =>
        token.type == _TokenType.word &&
        !token.quoted &&
        token.text.toUpperCase() == 'TRIGGER',
  );
  var on = -1;
  for (var index = 0; index < begin; index++) {
    if (tokens[index].type == _TokenType.word &&
        !tokens[index].quoted &&
        tokens[index].text.toUpperCase() == 'ON') {
      on = index;
      break;
    }
  }
  if (triggerKeyword < 0 || on < 0 || on + 1 >= tokens.length) {
    return (safe: false, tokens: const []);
  }
  var triggerName = triggerKeyword + 1;
  if (tokens[triggerName].text.toUpperCase() == 'IF') triggerName += 3;
  final tableName = on + 1;
  final updateOf = <int>{};
  for (var index = triggerKeyword; index < on - 1; index++) {
    if (tokens[index].type != _TokenType.word ||
        tokens[index].text.toUpperCase() != 'UPDATE' ||
        tokens[index + 1].text.toUpperCase() != 'OF') {
      continue;
    }
    for (var item = index + 2; item < on; item++) {
      if (tokens[item].type == _TokenType.word &&
          _key(tokens[item].text) == _key(column)) {
        updateOf.add(item);
      }
    }
  }

  final bodyRanges = <({int start, int end, _Statement step})>[];
  var cursor = begin + 1;
  for (final step in trigger.steps) {
    while (cursor < tokens.length && tokens[cursor].text == ';') {
      cursor++;
    }
    final start = cursor;
    var depth = 0;
    var caseDepth = 0;
    var end = -1;
    while (cursor < tokens.length - 1) {
      final token = tokens[cursor];
      if (token.text == '(') depth++;
      if (token.text == ')') depth--;
      if (token.type == _TokenType.word && !token.quoted) {
        final word = token.text.toUpperCase();
        if (word == 'CASE') caseDepth++;
        if (word == 'END') {
          if (caseDepth > 0) {
            caseDepth--;
          } else if (depth == 0) {
            break;
          }
        }
      }
      if (token.text == ';' && depth == 0) {
        end = cursor;
        cursor++;
        break;
      }
      cursor++;
    }
    if (end < 0) end = cursor;
    bodyRanges.add((start: start, end: end, step: step));
  }

  final bodyColumnReferences = <int>{};
  final bodyAnalyzedQueryTokens = <int>{};
  final bodyTableTokens = <int>{};
  bool targetsAlteredTable(_Statement step) => switch (step) {
    _Insert(:final table) || _Update(:final table) || _Delete(:final table) =>
      _key(table.replaceAll('\u0000', '.')) == _key(alteredTable),
    _ => false,
  };
  final tokenIndicesByStart = {
    for (var index = 0; index < tokens.length; index++)
      tokens[index].start: index,
  };
  final nestedQueryRanges = <({int start, int end})>[];
  bool directlyReadsAlteredTable(_Select query) =>
      query.table != null &&
          _key(query.table!.replaceAll('\u0000', '.')) == _key(alteredTable) ||
      query.joins.any(
        (join) =>
            join.table != null &&
            _key(join.table!.replaceAll('\u0000', '.')) == _key(alteredTable),
      ) ||
      query.compoundTerms.any((term) => directlyReadsAlteredTable(term.query));
  bool addQueryColumnReferences(
    _Select query,
    int selectTokenIndex,
    int end, {
    List<({int start, int end})> nested = const [],
  }) {
    final startOffset = tokens[selectTokenIndex].start;
    final endOffset = tokens[end - 1].end;
    void markAnalyzed(int localStart, int localEnd) {
      final absoluteStart = startOffset + localStart;
      final absoluteEnd = startOffset + localEnd;
      for (var index = selectTokenIndex; index < end; index++) {
        if (tokens[index].start >= absoluteStart &&
            tokens[index].end <= absoluteEnd) {
          bodyAnalyzedQueryTokens.add(index);
        }
      }
    }

    final codeUnits = sql.substring(startOffset, endOffset).codeUnits.toList();
    for (final range in nested) {
      final from = tokens[range.start].start - startOffset;
      final to = tokens[range.end - 1].end - startOffset;
      if (from < 0 || to > codeUnits.length || from >= to) return false;
      for (var index = from; index < to; index++) {
        if (codeUnits[index] != 10 && codeUnits[index] != 13) {
          codeUnits[index] = 32;
        }
      }
    }
    final querySql = String.fromCharCodes(codeUnits);
    if (query.compoundTerms.isEmpty) {
      final result = _viewColumnRenameReferences(
        query,
        alteredTable,
        column,
        querySql,
        sourceHasColumn,
      );
      if (!result.safe) return false;
      markAnalyzed(0, endOffset - startOffset);
      for (final reference in result.tokens) {
        final absoluteStart = startOffset + reference.start;
        final tokenIndex = tokenIndicesByStart[absoluteStart];
        if (tokenIndex == null) return false;
        bodyColumnReferences.add(tokenIndex);
      }
      return true;
    }

    final queryTokens = _Tokenizer(querySql).tokenize();
    final separators = <_Token>[];
    var depth = 0;
    for (final token in queryTokens) {
      if (token.text == '(') depth++;
      if (token.text == ')') depth--;
      if (depth == 0 &&
          token.type == _TokenType.word &&
          !token.quoted &&
          const {
            'UNION',
            'INTERSECT',
            'EXCEPT',
          }.contains(token.text.toUpperCase())) {
        separators.add(token);
      }
    }
    if (separators.length != query.compoundTerms.length) return false;
    var segmentStart = 0;
    for (var index = 0; index <= separators.length; index++) {
      final segmentEnd = index == separators.length
          ? querySql.length
          : separators[index].start;
      final segment = querySql.substring(segmentStart, segmentEnd);
      final parsed = _Parser(segment).parse();
      if (parsed is! _Select || parsed.compoundTerms.isNotEmpty) return false;
      markAnalyzed(segmentStart, segmentEnd);
      if (directlyReadsAlteredTable(parsed)) {
        final result = _viewColumnRenameReferences(
          parsed,
          alteredTable,
          column,
          segment,
          sourceHasColumn,
        );
        if (!result.safe) return false;
        for (final reference in result.tokens) {
          final absoluteStart = startOffset + segmentStart + reference.start;
          final tokenIndex = tokenIndicesByStart[absoluteStart];
          if (tokenIndex == null) return false;
          bodyColumnReferences.add(tokenIndex);
        }
      }
      if (index < separators.length) {
        final separator = separators[index];
        segmentStart = separator.end;
        if (segmentStart < querySql.length) {
          final afterOperator = _Tokenizer(
            querySql.substring(segmentStart),
          ).tokenize().first;
          if (afterOperator.type == _TokenType.word &&
              !afterOperator.quoted &&
              const {
                'ALL',
                'DISTINCT',
              }.contains(afterOperator.text.toUpperCase())) {
            segmentStart += afterOperator.end;
          }
        }
      }
    }
    return true;
  }

  bool addNestedQueryReferences(int start, int end) {
    final openBySelect = <int, int>{};
    final closeByOpen = <int, int>{};
    final opens = <int>[];
    for (var index = start; index < end; index++) {
      final token = tokens[index];
      if (token.text == ')') {
        if (opens.isNotEmpty) closeByOpen[opens.removeLast()] = index;
      } else if (token.text == '(') {
        opens.add(index);
      } else if (token.type == _TokenType.word &&
          !token.quoted &&
          token.text.toUpperCase() == 'SELECT' &&
          opens.isNotEmpty) {
        openBySelect[index] = opens.last;
      }
    }
    final queryRanges = <({int start, int end})>{};
    for (final open in openBySelect.values.toSet()) {
      final close = closeByOpen[open];
      if (close == null || close <= open + 1) return false;
      queryRanges.add((start: open + 1, end: close));
    }
    final orderedRanges = queryRanges.toList()
      ..sort((left, right) {
        final leftSize = left.end - left.start;
        final rightSize = right.end - right.start;
        return leftSize.compareTo(rightSize);
      });
    for (final range in orderedRanges) {
      final queryStart = range.start;
      final queryEnd = range.end;
      final querySql = sql.substring(
        tokens[queryStart].start,
        tokens[queryEnd].start,
      );
      final parsed = _Parser(querySql).parse();
      if (parsed is! _Select) return false;
      nestedQueryRanges.add(range);
      if (directlyReadsAlteredTable(parsed) &&
          !addQueryColumnReferences(
            parsed,
            queryStart,
            queryEnd,
            nested: [
              for (final child in orderedRanges)
                if (child.start >= range.start &&
                    child.end <= range.end &&
                    child != range)
                  child,
            ],
          )) {
        return false;
      }
    }
    return true;
  }

  bool isNestedQueryToken(int index) => nestedQueryRanges.any(
    (range) => index >= range.start && index < range.end,
  );
  List<({int start, int end})> nestedQueriesWithin(int start, int end) => [
    for (final nested in nestedQueryRanges)
      if (nested.start > start && nested.end <= end) nested,
  ];

  for (final range in bodyRanges) {
    final start = range.start;
    final end = range.end;
    final step = range.step;
    if (!addNestedQueryReferences(start, end)) {
      return (safe: false, tokens: const []);
    }
    if (step is _Insert) {
      var targetIndex = start;
      while (targetIndex < end &&
          tokens[targetIndex].text.toUpperCase() != 'INTO') {
        targetIndex++;
      }
      if (targetIndex < end) {
        targetIndex++;
        bodyTableTokens.add(targetIndex);
        if (targetIndex + 2 < end && tokens[targetIndex + 1].text == '.') {
          bodyTableTokens
            ..add(targetIndex + 1)
            ..add(targetIndex + 2);
        }
      }
      if (targetsAlteredTable(step) && step.columns != null) {
        var open = targetIndex + 1;
        while (open < end &&
            tokens[open].text != '(' &&
            !const {
              'VALUES',
              'SELECT',
              'DEFAULT',
            }.contains(tokens[open].text.toUpperCase())) {
          open++;
        }
        if (open < end && tokens[open].text == '(') {
          for (
            var item = open + 1;
            item < end && tokens[item].text != ')';
            item++
          ) {
            if (tokens[item].type == _TokenType.word &&
                _key(tokens[item].text) == _key(column)) {
              bodyColumnReferences.add(item);
            }
          }
        }
      }
      if (step.select case final query? when directlyReadsAlteredTable(query)) {
        var select = start;
        while (select < end && tokens[select].text.toUpperCase() != 'SELECT') {
          select++;
        }
        if (select < end) {
          if (!addQueryColumnReferences(
            query,
            select,
            end,
            nested: nestedQueriesWithin(select, end),
          )) {
            return (safe: false, tokens: const []);
          }
        }
      }
    } else if (step is _Update || step is _Delete) {
      var targetIndex = start + 1;
      if (step is _Update && tokens[targetIndex].text.toUpperCase() == 'OR') {
        targetIndex += 2;
      } else if (step is _Delete) {
        while (targetIndex < end &&
            tokens[targetIndex].text.toUpperCase() != 'FROM') {
          targetIndex++;
        }
        targetIndex++;
      }
      if (targetIndex < end) {
        bodyTableTokens.add(targetIndex);
        if (targetIndex + 2 < end && tokens[targetIndex + 1].text == '.') {
          bodyTableTokens
            ..add(targetIndex + 1)
            ..add(targetIndex + 2);
        }
      }
      if (!targetsAlteredTable(step)) continue;
      for (var item = start; item < end; item++) {
        final token = tokens[item];
        if (token.type != _TokenType.word ||
            _key(token.text) != _key(column) ||
            isNestedQueryToken(item) ||
            item >= 2 &&
                tokens[item - 1].text == '.' &&
                const [
                  'OLD',
                  'NEW',
                ].contains(tokens[item - 2].text.toUpperCase())) {
          continue;
        }
        final previous = item == 0 ? '' : tokens[item - 1].text.toUpperCase();
        if (previous == 'AS' ||
            previous == 'COLLATE' ||
            tokens[item + 1].text == '(' ||
            tokens[item + 1].text == '.') {
          continue;
        }
        if (item >= 2 && tokens[item - 1].text == '.') {
          final qualifier = tokens[item - 2].text;
          if (_key(qualifier.replaceAll('\u0000', '.')) != _key(alteredTable)) {
            return (safe: false, tokens: const []);
          }
        }
        bodyColumnReferences.add(item);
      }
    } else if (step is _Select &&
        directlyReadsAlteredTable(step) &&
        !addQueryColumnReferences(
          step,
          start,
          end,
          nested: nestedQueriesWithin(start, end),
        )) {
      return (safe: false, tokens: const []);
    }
  }

  final references = <_Token>[];
  for (var index = 0; index < tokens.length - 1; index++) {
    final token = tokens[index];
    if (token.type != _TokenType.word || _key(token.text) != _key(column)) {
      continue;
    }
    if (index == triggerName || index == tableName) continue;
    if (bodyTableTokens.contains(index)) continue;
    if (bodyColumnReferences.contains(index)) {
      references.add(token);
      continue;
    }
    if (bodyAnalyzedQueryTokens.contains(index)) continue;
    final oldOrNewColumn =
        index >= 2 &&
        tokens[index - 1].text == '.' &&
        const ['OLD', 'NEW'].contains(tokens[index - 2].text.toUpperCase());
    if (oldOrNewColumn) {
      if (belongsToTable) references.add(token);
    } else if (updateOf.contains(index)) {
      if (belongsToTable) references.add(token);
    } else if (index >= begin && isNestedQueryToken(index)) {
      continue;
    } else if (index >= begin) {
      final range = bodyRanges.where(
        (range) => index >= range.start && index < range.end,
      );
      if (range.isNotEmpty && range.first.step is _Insert) {
        final insert = range.first.step as _Insert;
        if (insert.select case final query?
            when !directlyReadsAlteredTable(query)) {
          continue;
        }
      }
      if (range.isNotEmpty && !targetsAlteredTable(range.first.step)) {
        if (range.first.step is _Select) continue;
        if (isNestedQueryToken(index)) continue;
        if (tokens
            .skip(range.first.start)
            .take(index - range.first.start)
            .any(
              (candidate) =>
                  candidate.type == _TokenType.word &&
                  !candidate.quoted &&
                  candidate.text.toUpperCase() == 'SELECT',
            )) {
          return (safe: false, tokens: const []);
        }
        continue;
      }
      if (range.isNotEmpty && range.first.step is _Insert) {
        return (safe: false, tokens: const []);
      }
      if (range.isNotEmpty && range.first.step is _Select) {
        continue;
      }
      final previous = tokens[index - 1].text.toUpperCase();
      if (previous == 'AS' ||
          previous == 'COLLATE' ||
          tokens[index + 1].text == '(' ||
          tokens[index + 1].text == '.') {
        continue;
      }
    } else {
      return (safe: false, tokens: const []);
    }
  }
  return (safe: true, tokens: references);
}

String _replaceSqlTokens(String sql, List<_Token> targets, String newName) {
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

({bool safe, List<_Token> tokens}) _viewColumnRenameReferences(
  _Select query,
  String tableName,
  String columnName,
  String sql,
  bool Function(String sourceName) sourceHasColumn,
) {
  if (query.table == null ||
      query.tableFunction != null ||
      query.fromQuery != null ||
      query.ctes.isNotEmpty ||
      query.compoundTerms.isNotEmpty ||
      query.joins.any(
        (join) =>
            join.table == null ||
            join.tableFunction != null ||
            join.query != null,
      )) {
    return (safe: false, tokens: const []);
  }
  final sources = <({String name, String? alias})>[
    (name: query.table!, alias: query.alias),
    for (final join in query.joins) (name: join.table!, alias: join.alias),
  ];
  if (sources.any((source) => source.name.contains('\u0000'))) {
    return (safe: false, tokens: const []);
  }
  final targetSources = sources
      .where((source) => _key(source.name) == _key(tableName))
      .toList();
  if (targetSources.length != 1) {
    return (safe: false, tokens: const []);
  }
  final qualifiers = sources.map((source) => _key(source.alias ?? source.name));
  final qualifierSet = qualifiers.toSet();
  if (qualifierSet.length != sources.length) {
    return (safe: false, tokens: const []);
  }
  final targetQualifier = _key(
    targetSources.single.alias ?? targetSources.single.name,
  );
  final naturalJoin = query.joins.any((join) => join.natural);
  final usingJoin = query.joins.any(
    (join) => join.usingColumns.any((name) => _key(name) == _key(columnName)),
  );
  final aliasedColumnCollision = query.items.any((item) {
    if (_key(item.outputName) != _key(columnName)) return false;
    final expression = item.expression;
    return expression is! _Column ||
        _key(expression.name.split('.').last) != _key(columnName);
  });
  bool usesUnqualifiedName(_Expr? expression) =>
      expression is _Column &&
      !expression.name.contains('.') &&
      _key(expression.name) == _key(columnName);
  if (aliasedColumnCollision &&
      (query.orderBy.any((order) => usesUnqualifiedName(order.expression)) ||
          query.groupBy.any(usesUnqualifiedName) ||
          usesUnqualifiedName(query.having))) {
    return (safe: false, tokens: const []);
  }
  final tokens = _Tokenizer(sql).tokenize();
  final selectIndexes = <int>[];
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.type == _TokenType.word &&
        !token.quoted &&
        token.text.toUpperCase() == 'SELECT') {
      selectIndexes.add(index);
    }
  }
  if (selectIndexes.length != 1) {
    return (safe: false, tokens: const []);
  }
  final selectIndex = selectIndexes.single;
  var fromIndex = -1;
  for (var index = selectIndex + 1; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.type == _TokenType.word &&
        !token.quoted &&
        token.text.toUpperCase() == 'FROM') {
      fromIndex = index;
      break;
    }
  }
  if (fromIndex < 0) return (safe: false, tokens: const []);
  const fromClauseEnd = {
    'GROUP',
    'HAVING',
    'LIMIT',
    'OFFSET',
    'ORDER',
    'WHERE',
    'WINDOW',
  };
  final sourceTokens = <int>{};
  const sourceTerminators = {
    'CROSS',
    'FULL',
    'GROUP',
    'HAVING',
    'INNER',
    'JOIN',
    'LEFT',
    'LIMIT',
    'NATURAL',
    'OFFSET',
    'ON',
    'ORDER',
    'OUTER',
    'RIGHT',
    'USING',
    'WHERE',
    'WINDOW',
  };
  bool markSource(int sourceIndex) {
    if (sourceIndex >= tokens.length ||
        tokens[sourceIndex].type != _TokenType.word) {
      return false;
    }
    sourceTokens.add(sourceIndex);
    if (sourceIndex + 2 < tokens.length &&
        tokens[sourceIndex + 1].text == '.') {
      sourceTokens
        ..add(sourceIndex + 1)
        ..add(sourceIndex + 2);
      sourceIndex += 2;
    }
    final aliasIndex = sourceIndex + 1;
    if (aliasIndex >= tokens.length) return true;
    if (tokens[aliasIndex].type == _TokenType.word &&
        !tokens[aliasIndex].quoted &&
        tokens[aliasIndex].text.toUpperCase() == 'AS') {
      if (aliasIndex + 1 >= tokens.length ||
          tokens[aliasIndex + 1].type != _TokenType.word) {
        return false;
      }
      sourceTokens
        ..add(aliasIndex)
        ..add(aliasIndex + 1);
    } else if (tokens[aliasIndex].type == _TokenType.word &&
        (tokens[aliasIndex].quoted ||
            !sourceTerminators.contains(
              tokens[aliasIndex].text.toUpperCase(),
            ))) {
      sourceTokens.add(aliasIndex);
    }
    return true;
  }

  var depth = 0;
  var inFromClause = false;
  for (var index = selectIndex + 1; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.text == '(') {
      depth++;
      continue;
    }
    if (token.text == ')') {
      depth--;
      continue;
    }
    if (depth != 0) continue;
    if (token.type == _TokenType.word && !token.quoted) {
      final word = token.text.toUpperCase();
      if (word == 'FROM') {
        inFromClause = true;
        if (!markSource(index + 1)) return (safe: false, tokens: const []);
        continue;
      }
      if (inFromClause && fromClauseEnd.contains(word)) {
        inFromClause = false;
        continue;
      }
      if (inFromClause && word == 'JOIN') {
        if (!markSource(index + 1)) return (safe: false, tokens: const []);
        continue;
      }
    }
    if (inFromClause && token.text == ',') {
      if (!markSource(index + 1)) return (safe: false, tokens: const []);
    }
  }
  const keywords = {
    'ALL',
    'AND',
    'AS',
    'BETWEEN',
    'CASE',
    'CAST',
    'COLLATE',
    'DISTINCT',
    'ELSE',
    'END',
    'ESCAPE',
    'FALSE',
    'FROM',
    'GLOB',
    'IN',
    'IS',
    'LIKE',
    'NOT',
    'NULL',
    'OR',
    'REGEXP',
    'SELECT',
    'THEN',
    'TRUE',
    'WHEN',
    'WHERE',
  };
  final usingColumnTokens = <int>{};
  for (var index = 0; index < tokens.length - 2; index++) {
    if (tokens[index].type != _TokenType.word ||
        tokens[index].text.toUpperCase() != 'USING' ||
        tokens[index + 1].text != '(') {
      continue;
    }
    for (
      var cursor = index + 2;
      cursor < tokens.length && tokens[cursor].text != ')';
      cursor++
    ) {
      if (tokens[cursor].type == _TokenType.word) {
        usingColumnTokens.add(cursor);
      }
    }
  }
  final references = <_Token>[];
  for (var index = selectIndex + 1; index < tokens.length - 1; index++) {
    if (sourceTokens.contains(index) || usingColumnTokens.contains(index)) {
      continue;
    }
    final token = tokens[index];
    if (token.type != _TokenType.word ||
        _key(token.text) != _key(columnName) ||
        !token.quoted && keywords.contains(token.text.toUpperCase())) {
      continue;
    }
    final previous = index == 0 ? '' : tokens[index - 1].text.toUpperCase();
    final next = tokens[index + 1].text;
    if (previous == 'AS' ||
        previous == 'COLLATE' ||
        next == '(' ||
        next == '.') {
      continue;
    }
    if (index >= 2 && tokens[index - 1].text == '.') {
      final qualifier = _key(tokens[index - 2].text);
      if (qualifier == targetQualifier) {
        references.add(token);
      } else if (!qualifierSet.contains(qualifier)) {
        return (safe: false, tokens: const []);
      }
    } else {
      final matchingSources = sources
          .where((source) => sourceHasColumn(source.name))
          .toList();
      if (matchingSources.length == 1 &&
          _key(matchingSources.single.name) ==
              _key(targetSources.single.name)) {
        references.add(token);
      } else if (usingJoin &&
          sources.length == 2 &&
          query.joins.length == 1 &&
          matchingSources.length == 2) {
        if (_key(matchingSources.first.name) ==
            _key(targetSources.single.name)) {
          references.add(token);
        }
      } else if (naturalJoin &&
          query.joins.every((join) => join.natural) &&
          matchingSources.isNotEmpty) {
        if (_key(matchingSources.first.name) ==
            _key(targetSources.single.name)) {
          references.add(token);
        }
      } else {
        return (safe: false, tokens: const []);
      }
    }
  }
  return (safe: true, tokens: references);
}

String _renameIndexColumnToken(String sql, String oldName, String newName) {
  final tokens = _Tokenizer(sql).tokenize();
  var onIndex = -1;
  for (var index = 0; index < tokens.length; index++) {
    if (tokens[index].type == _TokenType.word &&
        !tokens[index].quoted &&
        tokens[index].text.toUpperCase() == 'ON') {
      onIndex = index;
      break;
    }
  }
  if (onIndex < 0) throw SqliteFormatException('invalid CREATE INDEX SQL');
  var openIndex = onIndex + 1;
  while (openIndex < tokens.length && tokens[openIndex].text != '(') {
    openIndex++;
  }
  if (openIndex == tokens.length) {
    throw SqliteFormatException('invalid CREATE INDEX SQL');
  }
  var depth = 0;
  var closeIndex = -1;
  for (var index = openIndex; index < tokens.length; index++) {
    if (tokens[index].text == '(') depth++;
    if (tokens[index].text == ')') {
      depth--;
      if (depth == 0) {
        closeIndex = index;
        break;
      }
    }
  }
  if (closeIndex < 0) throw SqliteFormatException('invalid CREATE INDEX SQL');
  var whereIndex = closeIndex + 1;
  while (whereIndex < tokens.length - 1 &&
      !(tokens[whereIndex].type == _TokenType.word &&
          !tokens[whereIndex].quoted &&
          tokens[whereIndex].text.toUpperCase() == 'WHERE')) {
    whereIndex++;
  }
  final reservedWords = {
    'AND',
    'AS',
    'ASC',
    'BETWEEN',
    'CASE',
    'CAST',
    'COLLATE',
    'DESC',
    'ELSE',
    'END',
    'ESCAPE',
    'FALSE',
    'GLOB',
    'IN',
    'IS',
    'LIKE',
    'NOT',
    'NULL',
    'OR',
    'REGEXP',
    'THEN',
    'TRUE',
    'WHEN',
  };
  final references = <_Token>[];
  for (var index = openIndex + 1; index < tokens.length; index++) {
    final inIndexExpression = index < closeIndex;
    final inPredicate = whereIndex < tokens.length - 1 && index > whereIndex;
    if (!inIndexExpression && !inPredicate) continue;
    final token = tokens[index];
    if (token.type != _TokenType.word ||
        _key(token.text) != _key(oldName) ||
        !token.quoted && reservedWords.contains(token.text.toUpperCase())) {
      continue;
    }
    final previous = index == 0 ? '' : tokens[index - 1].text.toUpperCase();
    final next = index + 1 < tokens.length ? tokens[index + 1].text : '';
    if (previous == 'AS' ||
        previous == 'COLLATE' ||
        next == '(' ||
        next == '.') {
      continue;
    }
    references.add(token);
  }
  if (references.isEmpty) {
    throw PureSqlException('cannot safely rename indexed column: $oldName');
  }
  return _replaceSqlTokens(sql, references, newName);
}

String _renameForeignKeyTargetColumn(
  String sql,
  String tableName,
  String oldName,
  String newName,
) {
  final tokens = _Tokenizer(sql).tokenize();
  final references = <_Token>[];
  for (var index = 0; index < tokens.length - 1; index++) {
    if (tokens[index].type != _TokenType.word ||
        tokens[index].quoted ||
        tokens[index].text.toUpperCase() != 'REFERENCES') {
      continue;
    }
    var target = index + 1;
    if (target + 2 < tokens.length && tokens[target + 1].text == '.') {
      target += 2;
    }
    if (_key(tokens[target].text) != _key(tableName)) continue;
    var open = target + 1;
    while (open < tokens.length - 1 &&
        tokens[open].text != '(' &&
        tokens[open].text != ',') {
      open++;
    }
    if (open >= tokens.length - 1 || tokens[open].text != '(') continue;
    var depth = 0;
    var close = -1;
    for (var cursor = open; cursor < tokens.length; cursor++) {
      if (tokens[cursor].text == '(') depth++;
      if (tokens[cursor].text == ')') {
        depth--;
        if (depth == 0) {
          close = cursor;
          break;
        }
      }
    }
    if (close < 0) throw SqliteFormatException('invalid REFERENCES clause');
    for (var cursor = open + 1; cursor < close; cursor++) {
      if (tokens[cursor].type == _TokenType.word &&
          _key(tokens[cursor].text) == _key(oldName)) {
        references.add(tokens[cursor]);
      }
    }
  }
  if (references.isEmpty) {
    throw PureSqlException('cannot safely update foreign-key target: $oldName');
  }
  return _replaceSqlTokens(sql, references, newName);
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
    if (tokens[index].text.toUpperCase() != 'CREATE') continue;
    var typeIndex = index + 1;
    if (const [
      'TEMP',
      'TEMPORARY',
    ].contains(tokens[typeIndex].text.toUpperCase())) {
      typeIndex++;
    }
    if (typeIndex >= tokens.length - 1 ||
        tokens[typeIndex].text.toUpperCase() != 'TABLE') {
      continue;
    }
    var nameIndex = typeIndex + 1;
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
  final declarationMatches = <_Token>[];
  final references = <_Token>[];
  final commas = <int>[];
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
    if (token.text == ',' && depth == 1) commas.add(index);
  }
  if (closeIndex < 0) {
    throw PureSqlException('cannot safely rename column: $oldName');
  }
  final segmentStarts = [openIndex + 1, for (final comma in commas) comma + 1];
  final segmentEnds = [...commas, closeIndex];
  for (var segment = 0; segment < segmentStarts.length; segment++) {
    final first = segmentStarts[segment];
    if (first < segmentEnds[segment] &&
        tokens[first].type == _TokenType.word &&
        _key(tokens[first].text) == _key(oldName)) {
      declarationMatches.add(tokens[first]);
    }
  }
  int closingParen(int open) {
    var nested = 0;
    for (var index = open; index < closeIndex; index++) {
      if (tokens[index].text == '(') nested++;
      if (tokens[index].text == ')') {
        nested--;
        if (nested == 0) return index;
      }
    }
    return -1;
  }

  void addColumnList(int open) {
    final close = closingParen(open);
    if (close < 0) return;
    for (var index = open + 1; index < close; index++) {
      final token = tokens[index];
      if (token.type == _TokenType.word &&
          _key(token.text) == _key(oldName) &&
          !(index > 0 && tokens[index - 1].text.toUpperCase() == 'COLLATE')) {
        references.add(token);
      }
    }
  }

  for (var index = openIndex + 1; index < closeIndex; index++) {
    final word = tokens[index].type == _TokenType.word && !tokens[index].quoted
        ? tokens[index].text.toUpperCase()
        : '';
    var listIndex = -1;
    if (word == 'UNIQUE' && tokens[index + 1].text == '(') {
      listIndex = index + 1;
    } else if ((word == 'PRIMARY' || word == 'FOREIGN') &&
        index + 2 < closeIndex &&
        tokens[index + 1].text.toUpperCase() == 'KEY' &&
        tokens[index + 2].text == '(') {
      listIndex = index + 2;
    }
    if (listIndex >= 0) addColumnList(listIndex);

    if (word == 'REFERENCES' && index + 1 < closeIndex) {
      var target = index + 1;
      if (target + 2 < closeIndex && tokens[target + 1].text == '.') {
        target += 2;
      }
      if (_key(tokens[target].text) == _key(tableName)) {
        var open = target + 1;
        while (open < closeIndex && tokens[open].text != '(') {
          if (tokens[open].text == ',') break;
          open++;
        }
        if (open < closeIndex && tokens[open].text == '(') {
          addColumnList(open);
        }
      }
    }
  }
  for (var index = openIndex + 1; index < closeIndex; index++) {
    final token = tokens[index];
    if (token.type != _TokenType.word ||
        _key(token.text) != _key(oldName) ||
        index + 1 < tokens.length && tokens[index + 1].text == '.' ||
        index > 0 && tokens[index - 1].text.toUpperCase() == 'COLLATE') {
      continue;
    }
    if (declarationMatches.any(
      (declaration) => declaration.start == token.start,
    )) {
      continue;
    }
    var insideCheck = false;
    for (var check = openIndex + 1; check < index; check++) {
      if (tokens[check].type != _TokenType.word ||
          tokens[check].quoted ||
          tokens[check].text.toUpperCase() != 'CHECK' ||
          check + 1 >= tokens.length ||
          tokens[check + 1].text != '(') {
        continue;
      }
      var checkDepth = 0;
      for (var end = check + 1; end <= index; end++) {
        if (tokens[end].text == '(') checkDepth++;
        if (tokens[end].text == ')') checkDepth--;
        if (checkDepth == 0) break;
      }
      if (checkDepth > 0) {
        insideCheck = true;
        break;
      }
    }
    if (insideCheck &&
        !(index + 1 < tokens.length && tokens[index + 1].text == '(')) {
      references.add(token);
    }
  }
  if (declarationMatches.length != 1) {
    throw PureSqlException('cannot safely rename column: $oldName');
  }
  final targets = [...declarationMatches, ...references]
    ..sort((left, right) => left.start.compareTo(right.start));
  final uniqueTargets = <_Token>[];
  for (final target in targets) {
    if (uniqueTargets.isEmpty || uniqueTargets.last.start != target.start) {
      uniqueTargets.add(target);
    }
  }
  return _replaceSqlTokens(sql, uniqueTargets, newName);
}

String _dropSingleColumnDefinition(
  String sql,
  String tableName,
  String columnName,
) {
  final tokens = _Tokenizer(sql).tokenize();
  var tableIndex = -1;
  for (var index = 0; index < tokens.length - 1; index++) {
    if (tokens[index].text.toUpperCase() != 'CREATE') continue;
    var typeIndex = index + 1;
    if (const [
      'TEMP',
      'TEMPORARY',
    ].contains(tokens[typeIndex].text.toUpperCase())) {
      typeIndex++;
    }
    if (typeIndex >= tokens.length - 1 ||
        tokens[typeIndex].text.toUpperCase() != 'TABLE') {
      continue;
    }
    var nameIndex = typeIndex + 1;
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

String _sqliteAsciiUpper(String value) => value.replaceAllMapped(
  RegExp('[a-z]'),
  (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 32),
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

bool _sameExpression(_Expr left, _Expr right) {
  if (left is _Literal && right is _Literal) {
    return _valueEqual(left.value, right.value);
  }
  if (left is _Column && right is _Column) {
    return _key(left.name) == _key(right.name);
  }
  if (left is _Param && right is _Param) return left.index == right.index;
  if (left is _Function && right is _Function) {
    return _key(left.name) == _key(right.name) &&
        left.distinct == right.distinct &&
        _sameExpressions(left.arguments, right.arguments);
  }
  if (left is _Binary && right is _Binary) {
    return left.operator == right.operator &&
        _sameExpression(left.left, right.left) &&
        _sameExpression(left.right, right.right);
  }
  if (left is _Unary && right is _Unary) {
    return left.operator == right.operator &&
        _sameExpression(left.expression, right.expression);
  }
  if (left is _Cast && right is _Cast) {
    return _key(left.type) == _key(right.type) &&
        _sameExpression(left.expression, right.expression);
  }
  if (left is _Between && right is _Between) {
    return left.negated == right.negated &&
        _sameExpression(left.expression, right.expression) &&
        _sameExpression(left.lower, right.lower) &&
        _sameExpression(left.upper, right.upper);
  }
  if (left is _PatternMatch && right is _PatternMatch) {
    return left.operator == right.operator &&
        left.negated == right.negated &&
        _sameExpression(left.expression, right.expression) &&
        _sameExpression(left.pattern, right.pattern) &&
        (left.escape == null
            ? right.escape == null
            : right.escape != null &&
                  _sameExpression(left.escape!, right.escape!));
  }
  if (left is _Case && right is _Case) {
    return left.branches.length == right.branches.length &&
        List.generate(left.branches.length, (index) {
          final a = left.branches[index];
          final b = right.branches[index];
          return _sameExpression(a.$1, b.$1) && _sameExpression(a.$2, b.$2);
        }).every((same) => same) &&
        (left.otherwise == null
            ? right.otherwise == null
            : right.otherwise != null &&
                  _sameExpression(left.otherwise!, right.otherwise!));
  }
  if (left is _In && right is _In) {
    return left.negated == right.negated &&
        left.query == null &&
        right.query == null &&
        _sameExpression(left.expression, right.expression) &&
        _sameExpressions(left.values, right.values);
  }
  if (left is _RowValue && right is _RowValue) {
    return _sameExpressions(left.values, right.values);
  }
  return false;
}

bool _sameExpressions(List<_Expr> left, List<_Expr> right) =>
    left.length == right.length &&
    List.generate(
      left.length,
      (index) => _sameExpression(left[index], right[index]),
    ).every((same) => same);

Object? _eval(
  _Expr expression,
  SqlRow row,
  List<Object?> parameters, {
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) => switch (expression) {
  _Literal(:final value) => value,
  _RowValue(:final values) => _SqlRowValue([
    for (final value in values)
      _eval(value, row, parameters, selectSubquery: selectSubquery),
  ]),
  _Param(:final index) =>
    index < parameters.length
        ? parameters[index]
        : throw PureSqlException('missing parameter ${index + 1}'),
  _Column(:final name) => _readColumn(row, name),
  _Function(:final name, :final arguments, filter: _?)
      when !_isAggregateFunction(name, arguments.length) =>
    throw PureSqlException('FILTER may only be used with aggregate functions'),
  _Function(:final name, :final arguments)
      when (name.toUpperCase() == 'IIF' || name.toUpperCase() == 'IF') &&
          _registeredSqlFunction(name, arguments.length) == null =>
    _evalIif(name, arguments, row, parameters, selectSubquery: selectSubquery),
  _Function(:final name, :final arguments) => _evalFunction(
    name,
    arguments,
    row,
    parameters,
    selectSubquery: selectSubquery,
  ),
  _WindowFunction(:final id) =>
    row.containsKey('@window:$id')
        ? row['@window:$id']
        : throw PureSqlException('window function used outside SELECT'),
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
  if (value is _SqlRowValue) throw PureSqlException('row value misused');
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

String _ctasDeclaredType(String declaredType) {
  final type = declaredType.toUpperCase();
  if (type.contains('INT')) return 'INT';
  if (type.contains('CHAR') || type.contains('CLOB') || type.contains('TEXT')) {
    return 'TEXT';
  }
  if (type.contains('BLOB') || type.isEmpty) return '';
  if (type.contains('REAL') || type.contains('FLOA') || type.contains('DOUB')) {
    return 'REAL';
  }
  return 'NUM';
}

String _sourceLeaf(String name) => name.substring(
  name.lastIndexOf(name.contains('\u0000') ? '\u0000' : '.') + 1,
);

Object? _evalBetween(
  Object? value,
  Object? lower,
  Object? upper,
  bool negated,
) {
  if (value is _SqlRowValue || lower is _SqlRowValue || upper is _SqlRowValue) {
    throw PureSqlException('row value misused');
  }
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
  if (value is _SqlRowValue ||
      pattern is _SqlRowValue ||
      escape is _SqlRowValue) {
    throw PureSqlException('row value misused');
  }
  final custom = _registeredSqlFunction(operator, escape == null ? 2 : 3);
  if (custom != null) {
    final result = _normalizeSqlFunctionResult(
      custom(List.unmodifiable([pattern, value, if (escape != null) escape])),
    );
    return negated
        ? (result == null ? null : (_truthy(result) ? 0 : 1))
        : result;
  }
  if (value == null || pattern == null) return null;
  final text = value.toString();
  final source = pattern.toString();
  final matched = switch (operator) {
    'LIKE' => _like(
      text,
      source,
      escape: escape?.toString(),
      caseSensitive: Zone.current[_sqlCaseSensitiveLikeZoneKey] == true,
    ),
    'GLOB' => _glob(text, source),
    'REGEXP' => _matchesRegexp(text, source),
    'MATCH' => throw PureSqlException('no such function: match'),
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
  return _binary(operator, left, right, noCase: collation == 'NOCASE');
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
  int? queryWidth;
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
          final wildcard =
              query.items.length == 1 &&
              query.items.single.expression is _Column &&
              ((query.items.single.expression as _Column).name == '*' ||
                  (query.items.single.expression as _Column).name.endsWith(
                    '.*',
                  ));
          final width = wildcard
              ? (rows.isEmpty ? null : rows.first.length)
              : query.items.length;
          queryWidth = width;
          return [
            for (final result in rows)
              if (wildcard)
                width == 1
                    ? result.values.first
                    : _SqlRowValue(result.values.toList())
              else if (width == 1)
                result[query.items.single.outputName]
              else
                _SqlRowValue([
                  for (final item in query.items) result[item.outputName],
                ]),
          ];
        }();
  if (evaluatedValues.isEmpty && queryWidth == null) return negated;
  final value = _eval(
    expression,
    row,
    parameters,
    selectSubquery: selectSubquery,
  );
  if (queryWidth != null) {
    final valueWidth = value is _SqlRowValue ? value.values.length : 1;
    if (valueWidth != queryWidth) {
      throw PureSqlException('IN operands have mismatched column count');
    }
  }
  if (evaluatedValues.isEmpty) return negated;
  if (value == null) return null;
  var unknown = false;
  for (final item in evaluatedValues) {
    if (value is! _SqlRowValue && item == null) {
      unknown = true;
      continue;
    }
    final equal = _binary('=', value, item);
    if (equal == true) return !negated;
    if (equal == null) unknown = true;
  }
  return unknown ? null : negated;
}

Object? _evalFunction(
  String name,
  List<_Expr> arguments,
  SqlRow row,
  List<Object?> parameters, {
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  if (name.toUpperCase() == 'SQLITE_OFFSET' &&
      _registeredSqlFunction(name, arguments.length) == null &&
      _registeredSqlAggregateFunction(name, arguments.length) == null) {
    if (arguments.length != 1) {
      throw PureSqlException('sqlite_offset expects one argument');
    }
    final argument = arguments.single;
    if (argument is! _Column) return null;
    _readColumn(row, argument.name);
    return _readSqliteOffset(row: row, name: argument.name);
  }
  if (name.toUpperCase() == 'RAISE') {
    final triggerDepth = Zone.current[_sqlTriggerExecutionDepthZoneKey];
    if (triggerDepth is! int) {
      throw PureSqlException('RAISE() may only be used within a trigger');
    }
    final action = (arguments.first as _Literal).value as String;
    final message = arguments.length == 1
        ? 'constraint failed'
        : _eval(
                arguments[1],
                row,
                parameters,
                selectSubquery: selectSubquery,
              )?.toString() ??
              'constraint failed';
    throw _TriggerRaiseException(
      action,
      SqliteException(message),
      triggerDepth,
      before: Zone.current[_sqlTriggerTimingZoneKey] == 'BEFORE',
    );
  }
  if (name.toUpperCase() == 'SUBTYPE' &&
      _registeredSqlFunction(name, arguments.length) == null) {
    if (arguments.length != 1) {
      throw PureSqlException('subtype expects one argument');
    }
    return _evalExpressionWithSubtype(
      arguments.single,
      (expression) =>
          _eval(expression, row, parameters, selectSubquery: selectSubquery),
    ).subtype;
  }
  final values = arguments
      .map(
        (argument) =>
            _eval(argument, row, parameters, selectSubquery: selectSubquery),
      )
      .toList();
  if (values.any((value) => value is _SqlRowValue)) {
    throw PureSqlException('row value misused');
  }
  return _applySqlFunction(name, values);
}

({Object? value, int subtype}) _evalExpressionWithSubtype(
  _Expr expression,
  Object? Function(_Expr) evaluate,
) {
  if (expression is _Function) {
    final name = expression.name.toUpperCase();
    final arguments = expression.arguments;
    if (name == 'SUBTYPE' &&
        _registeredSqlFunction(name, arguments.length) == null) {
      if (arguments.length != 1) {
        throw PureSqlException('subtype expects one argument');
      }
      final nested = _evalExpressionWithSubtype(arguments.single, evaluate);
      return (value: nested.subtype, subtype: 0);
    }
    if (_isAggregateFunction(name, arguments.length) &&
        _registeredSqlAggregateFunction(name, arguments.length) == null) {
      final value = evaluate(expression);
      final subtype =
          value != null &&
              value is String &&
              const {'JSON_GROUP_ARRAY', 'JSON_GROUP_OBJECT'}.contains(name)
          ? 74
          : 0;
      return (value: value, subtype: subtype);
    }
    if (_registeredSqlFunction(name, arguments.length) != null) {
      return (value: evaluate(expression), subtype: 0);
    }
    if (name == 'COALESCE' || name == 'IFNULL') {
      if (name == 'IFNULL' && arguments.length != 2 ||
          name == 'COALESCE' && arguments.length < 2) {
        return (value: evaluate(expression), subtype: 0);
      }
      for (final argument in arguments) {
        final result = _evalExpressionWithSubtype(argument, evaluate);
        if (result.value != null) return result;
      }
      return (value: null, subtype: 0);
    }
    if (name == 'IF' || name == 'IIF') {
      if (arguments.length < 2)
        return (value: evaluate(expression), subtype: 0);
      for (var index = 0; index + 1 < arguments.length; index += 2) {
        if (_truthy(evaluate(arguments[index]))) {
          return _evalExpressionWithSubtype(arguments[index + 1], evaluate);
        }
      }
      return arguments.length.isOdd
          ? _evalExpressionWithSubtype(arguments.last, evaluate)
          : (value: null, subtype: 0);
    }
    if (const {'LIKELY', 'UNLIKELY', 'LIKELIHOOD', 'NULLIF'}.contains(name)) {
      final values = <Object?>[];
      final first = arguments.isEmpty
          ? null
          : _evalExpressionWithSubtype(arguments.first, evaluate);
      if (first != null) values.add(first.value);
      values.addAll(arguments.skip(1).map(evaluate));
      final value = _applySqlFunction(expression.name, values);
      return (
        value: value,
        subtype: value != null && value == first?.value ? first!.subtype : 0,
      );
    }
    final values = arguments.map(evaluate).toList();
    final value = _applySqlFunction(expression.name, values);
    return (
      value: value,
      subtype: _sqlFunctionResultSubtype(name, values, value),
    );
  }
  if (expression is _Binary &&
      (expression.operator == '->' || expression.operator == '->>')) {
    final value = _binary(
      expression.operator,
      evaluate(expression.left),
      evaluate(expression.right),
    );
    return (
      value: value,
      subtype: expression.operator == '->' && value != null ? 74 : 0,
    );
  }
  if (expression is _Cast) {
    final result = _evalExpressionWithSubtype(expression.expression, evaluate);
    final value = _castSqlValue(result.value, expression.type);
    return (value: value, subtype: value == null ? 0 : result.subtype);
  }
  if (expression is _Case) {
    for (final (condition, result) in expression.branches) {
      if (_truthy(evaluate(condition))) {
        return _evalExpressionWithSubtype(result, evaluate);
      }
    }
    return expression.otherwise == null
        ? (value: null, subtype: 0)
        : _evalExpressionWithSubtype(expression.otherwise!, evaluate);
  }
  return (value: evaluate(expression), subtype: 0);
}

int _sqlFunctionResultSubtype(
  String name,
  List<Object?> arguments,
  Object? value,
) {
  if (value == null) return 0;
  if (const {
    'JSON',
    'JSON_ARRAY',
    'JSON_ARRAY_INSERT',
    'JSON_OBJECT',
    'JSON_INSERT',
    'JSON_PATCH',
    'JSON_PRETTY',
    'JSON_QUOTE',
    'JSON_REMOVE',
    'JSON_REPLACE',
    'JSON_SET',
  }.contains(name)) {
    return value is String ? 74 : 0;
  }
  if (name == 'JSON_EXTRACT' && value is String && arguments.isNotEmpty) {
    if (arguments.length > 2) return 74;
    if (arguments.length == 2 && arguments[1] != null) {
      final selected = _jsonPathValue(
        _decodeSqlJson(arguments.first),
        arguments[1].toString(),
      );
      return selected is List || selected is Map ? 74 : 0;
    }
  }
  return 0;
}

SqlScalarFunction? _registeredSqlFunction(String name, int argumentCount) {
  final functions = Zone.current[_sqlFunctionsZoneKey];
  if (functions is! Map<String, Map<int, SqlScalarFunction>>) return null;
  final overloads = functions[_key(name)];
  return overloads?[argumentCount] ?? overloads?[-1];
}

SqlAggregateFunction? _registeredSqlAggregateFunction(
  String name,
  int argumentCount,
) {
  final functions = Zone.current[_sqlAggregateFunctionsZoneKey];
  if (functions is! Map<String, Map<int, SqlAggregateFunction>>) return null;
  final overloads = functions[_key(name)];
  return overloads?[argumentCount] ?? overloads?[-1];
}

SqlWindowFunction? _registeredSqlWindowFunction(
  String name,
  int argumentCount,
) {
  final functions = Zone.current[_sqlWindowFunctionsZoneKey];
  if (functions is! Map<String, Map<int, SqlWindowFunction>>) return null;
  final overloads = functions[_key(name)];
  return overloads?[argumentCount] ?? overloads?[-1];
}

Object? _applySqlFunction(String name, List<Object?> values) {
  final function = _registeredSqlFunction(name, values.length);
  return function == null
      ? _applyFunction(name, values)
      : _normalizeSqlFunctionResult(function(List.unmodifiable(values)));
}

Object? _normalizeSqlFunctionResult(Object? value) {
  if (value is bool) return value ? 1 : 0;
  if (value is double && value.isNaN) return null;
  if (value == null || value is num || value is String) return value;
  if (value is List<int>) return List<int>.from(value);
  throw PureSqlException(
    'unsupported SQL function result: ' + value.runtimeType.toString(),
  );
}

List<int> _builtinSqlFunctionArities(String name) => switch (name) {
  'ABS' ||
  'ACOS' ||
  'ACOSH' ||
  'ASIN' ||
  'ASINH' ||
  'ATAN' ||
  'ATANH' ||
  'CEIL' ||
  'CEILING' ||
  'COS' ||
  'COSH' ||
  'DEGREES' ||
  'EXP' ||
  'FLOOR' ||
  'HEX' ||
  'LENGTH' ||
  'LN' ||
  'LOG10' ||
  'LOG2' ||
  'LOWER' ||
  'OCTET_LENGTH' ||
  'QUOTE' ||
  'RADIANS' ||
  'SIGN' ||
  'SIN' ||
  'SINH' ||
  'SOUNDEX' ||
  'SQRT' ||
  'SUBTYPE' ||
  'TAN' ||
  'TANH' ||
  'TRUNC' ||
  'TYPEOF' ||
  'UNICODE' ||
  'UNISTR' ||
  'UNISTR_QUOTE' ||
  'UPPER' ||
  'ZEROBLOB' ||
  'JSON' ||
  'JSONB' ||
  'JSON_ERROR_POSITION' ||
  'JSON_QUOTE' ||
  'LIKELY' ||
  'RANDOMBLOB' => const [1],
  'ATAN2' ||
  'GLOB' ||
  'INSTR' ||
  'MOD' ||
  'NULLIF' ||
  'POW' ||
  'POWER' ||
  'PERCENTILE' ||
  'PERCENTILE_CONT' ||
  'PERCENTILE_DISC' ||
  'SQLITE_LOG' ||
  'STRING_AGG' ||
  'TIMEDIFF' => const [2],
  'REPLACE' => const [3],
  'AVG' || 'MEDIAN' || 'SUM' || 'TOTAL' => const [1],
  'CHAR' ||
  'DATE' ||
  'DATETIME' ||
  'JULIANDAY' ||
  'JSON_ARRAY' ||
  'JSON_ARRAY_INSERT' ||
  'JSONB_ARRAY' ||
  'JSONB_ARRAY_INSERT' ||
  'JSONB_EXTRACT' ||
  'JSONB_INSERT' ||
  'JSONB_OBJECT' ||
  'JSONB_REMOVE' ||
  'JSONB_REPLACE' ||
  'JSONB_SET' ||
  'JSON_EXTRACT' ||
  'JSON_INSERT' ||
  'JSON_OBJECT' ||
  'JSON_REMOVE' ||
  'JSON_REPLACE' ||
  'JSON_SET' ||
  'PRINTF' ||
  'STRFTIME' ||
  'TIME' ||
  'UNIXEPOCH' => const [-1],
  'CHANGES' ||
  'CURRENT_DATE' ||
  'CURRENT_TIME' ||
  'CURRENT_TIMESTAMP' ||
  'LAST_INSERT_ROWID' ||
  'PI' ||
  'RANDOM' ||
  'SQLITE_SOURCE_ID' ||
  'SQLITE_VERSION' ||
  'TOTAL_CHANGES' => const [0],
  'COALESCE' || 'CONCAT_WS' || 'IF' || 'IIF' => const [-4],
  'CONCAT' => const [-3],
  'COUNT' => const [0, 1],
  'GROUP_CONCAT' => const [1, 2],
  'IFNULL' ||
  'LIKELIHOOD' ||
  'LOG' ||
  'JSON_PATCH' ||
  'JSONB_PATCH' => name == 'LOG' ? const [1, 2] : const [2],
  'JSON_ARRAY_LENGTH' ||
  'JSON_PRETTY' ||
  'JSON_TYPE' ||
  'JSON_VALID' ||
  'LTRIM' ||
  'ROUND' ||
  'RTRIM' ||
  'TRIM' => const [1, 2],
  'LIKE' => const [2, 3],
  'SUBSTR' || 'SUBSTRING' => const [2, 3],
  'MAX' || 'MIN' => const [-3, 1],
  'UNHEX' => const [1, 2],
  'FORMAT' => const [-1],
  'SQLITE_COMPILEOPTION_GET' || 'SQLITE_COMPILEOPTION_USED' => const [1],
  'JSON_GROUP_ARRAY' || 'JSONB_GROUP_ARRAY' => const [1],
  'JSON_GROUP_OBJECT' || 'JSONB_GROUP_OBJECT' => const [2],
  _ => const [1],
};

int _sqliteFunctionFlags(String name, int arity, {required bool aggregate}) {
  if (aggregate) return 0x200000;
  if ((name == 'MAX' || name == 'MIN') && arity == 1) return 0x200000;
  if (const {
    'CHANGES',
    'CURRENT_DATE',
    'CURRENT_TIME',
    'CURRENT_TIMESTAMP',
    'LAST_INSERT_ROWID',
    'RANDOM',
    'RANDOMBLOB',
    'SQLITE_COMPILEOPTION_GET',
    'SQLITE_COMPILEOPTION_USED',
    'SQLITE_OFFSET',
    'SQLITE_SOURCE_ID',
    'SQLITE_VERSION',
    'TOTAL_CHANGES',
  }.contains(name)) {
    return 0x200000;
  }
  return 0x200800;
}

Object? _evalIif(
  String name,
  List<_Expr> arguments,
  SqlRow row,
  List<Object?> parameters, {
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  return _evaluateIif(
    name,
    arguments,
    (expression) =>
        _eval(expression, row, parameters, selectSubquery: selectSubquery),
  );
}

Object? _evaluateIif(
  String name,
  List<_Expr> arguments,
  Object? Function(_Expr) evaluate,
) {
  if (arguments.length < 2) {
    throw PureSqlException('$name expects at least two arguments');
  }
  for (var index = 0; index + 1 < arguments.length; index += 2) {
    if (_truthy(evaluate(arguments[index])))
      return evaluate(arguments[index + 1]);
  }
  return arguments.length.isOdd ? evaluate(arguments.last) : null;
}

Object? _applyFunction(String name, List<Object?> values) {
  final normalizedName = name.toUpperCase();
  if (normalizedName == 'JSONB') {
    _requireArity(name, values, 1);
    final value = values.single;
    if (value == null) return null;
    if (value is List<int>) {
      try {
        _readSqlJsonb(value, deep: false);
        return List<int>.from(value);
      } on FormatException {
        // Non-JSONB blobs are handled as JSON text by the regular JSON path.
      }
    }
    return _encodeSqlJsonb(_decodeSqlJson(value));
  }
  if (normalizedName.startsWith('JSONB_') &&
      !const {
        'JSONB_GROUP_ARRAY',
        'JSONB_GROUP_OBJECT',
      }.contains(normalizedName)) {
    return _applyJsonbFunction(normalizedName, values);
  }
  switch (name.toUpperCase()) {
    case 'CURRENT_DATE':
    case 'CURRENT_TIME':
    case 'CURRENT_TIMESTAMP':
      _requireArity(name, values, 0);
      final now =
          Zone.current[_sqlCurrentTimestampZoneKey] as DateTime? ??
          DateTime.now().toUtc();
      final date =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final time =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      return switch (name.toUpperCase()) {
        'CURRENT_DATE' => date,
        'CURRENT_TIME' => time,
        _ => '$date $time',
      };
    case 'SQLITE_VERSION':
      _requireArity(name, values, 0);
      return _sqliteCompatibilityVersion;
    case 'LOAD_EXTENSION':
      if (values.length < 1 || values.length > 2) {
        throw PureSqlException('load_extension expects one or two arguments');
      }
      throw PureSqlException('not authorized');
    case 'SQLITE_SOURCE_ID':
      _requireArity(name, values, 0);
      return _sqliteCompatibilitySourceId;
    case 'SQLITE_COMPILEOPTION_GET':
      _requireArity(name, values, 1);
      return null;
    case 'SQLITE_COMPILEOPTION_USED':
      _requireArity(name, values, 1);
      return 0;
    case 'SQLITE_LOG':
      _requireArity(name, values, 2);
      final callback = Zone.current[_sqlLogZoneKey] as SqlLogCallback?;
      if (callback != null) {
        try {
          callback(_sqliteLogCode(values[0]), _sqliteLogMessage(values[1]));
        } catch (_) {
          // A C SQLite log callback cannot throw into the running statement.
        }
      }
      return null;
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
      if (values.length < 2) {
        throw PureSqlException('COALESCE requires at least two arguments');
      }
      for (final value in values) {
        if (value != null) return value;
      }
      return null;
    case 'IFNULL':
      _requireArity(name, values, 2);
      return values.first ?? values.last;
    case 'LIKE':
      if (values.length < 2 || values.length > 3) {
        throw PureSqlException('LIKE expects two or three arguments');
      }
      if (values.take(2).any((value) => value == null) ||
          values.length == 3 && values[2] == null) {
        return null;
      }
      return _like(
        values[1].toString(),
        values[0].toString(),
        escape: values.length == 3 ? values[2].toString() : null,
        caseSensitive: Zone.current[_sqlCaseSensitiveLikeZoneKey] == true,
      );
    case 'GLOB':
      _requireArity(name, values, 2);
      return values.any((value) => value == null)
          ? null
          : _glob(values[1].toString(), values[0].toString());
    case 'FORMAT':
    case 'PRINTF':
      return _formatSql(values);
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
      return values.single == null
          ? null
          : _sqliteNoCase(values.single.toString());
    case 'UPPER':
      _requireArity(name, values, 1);
      return values.single == null
          ? null
          : _sqliteAsciiUpper(values.single.toString());
    case 'SOUNDEX':
      _requireArity(name, values, 1);
      return _sqliteSoundex(values.single);
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
    case 'OCTET_LENGTH':
      _requireArity(name, values, 1);
      final value = values.single;
      return value == null
          ? null
          : value is List<int>
          ? value.length
          : utf8.encode(value.toString()).length;
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
    case 'BASE64':
      return _applyBase64(values);
    case 'BASE85':
      return _applyBase85(values);
    case 'UNHEX':
      if (values.isEmpty || values.length > 2) {
        throw PureSqlException('UNHEX expects one or two arguments');
      }
      if (values.any((value) => value == null)) return null;
      final ignored = values.length == 1
          ? const <int>{}
          : values[1]
                .toString()
                .runes
                .where(
                  (rune) =>
                      int.tryParse(String.fromCharCode(rune), radix: 16) ==
                      null,
                )
                .toSet();
      final bytes = <int>[];
      int? highNibble;
      for (final rune in values.first.toString().runes) {
        final digit = int.tryParse(String.fromCharCode(rune), radix: 16);
        if (digit != null) {
          if (highNibble == null) {
            highNibble = digit;
          } else {
            bytes.add((highNibble << 4) | digit);
            highNibble = null;
          }
        } else if (!ignored.contains(rune) || highNibble != null) {
          return null;
        }
      }
      return highNibble == null ? bytes : null;
    case 'UNISTR':
      _requireArity(name, values, 1);
      return values.single == null
          ? null
          : _decodeSqlUnistr(values.single.toString());
    case 'UNISTR_QUOTE':
      _requireArity(name, values, 1);
      final value = values.single;
      if (value == null || value is List<int> || value is! String) {
        return _applyFunction('QUOTE', values);
      }
      if (!value.runes.any((rune) => rune >= 1 && rune <= 0x1f)) {
        return _applyFunction('QUOTE', values);
      }
      final escaped = StringBuffer();
      for (final rune in value.runes) {
        switch (rune) {
          case 0x5c:
            escaped.write('\\\\');
          case 0x27:
            escaped.write("''");
          case 0x08:
            escaped.write('\\b');
          case 0x09:
            escaped.write('\\t');
          case 0x0a:
            escaped.write('\\n');
          case 0x0c:
            escaped.write('\\f');
          case 0x0d:
            escaped.write('\\r');
          default:
            if (rune >= 1 && rune <= 0x1f) {
              escaped.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
            } else {
              escaped.writeCharCode(rune);
            }
        }
      }
      return "unistr('${escaped.toString()}')";
    case 'QUOTE':
      _requireArity(name, values, 1);
      final value = values.single;
      if (value == null) return 'NULL';
      if (value is List<int>) return "X'${_applyFunction('HEX', [value])}'";
      if (value is num) return value.toString();
      return "'${value.toString().split('\u0000').first.replaceAll("'", "''")}'";
    case 'CHAR':
      return String.fromCharCodes(
        values.whereType<num>().map((v) => v.toInt().clamp(0, 0x10ffff)),
      );
    case 'CHANGES':
      _requireArity(name, values, 0);
      return Zone.current[_sqlChangesZoneKey] as int? ?? 0;
    case 'TOTAL_CHANGES':
      _requireArity(name, values, 0);
      return Zone.current[_sqlTotalChangesZoneKey] as int? ?? 0;
    case 'LAST_INSERT_ROWID':
      _requireArity(name, values, 0);
      return Zone.current[_sqlLastInsertRowIdZoneKey] as int? ?? 0;
    case 'UNICODE':
      _requireArity(name, values, 1);
      final runes = values.single?.toString().runes;
      return runes == null || runes.isEmpty ? null : runes.first;
    case 'CONCAT':
      if (values.isEmpty) {
        throw PureSqlException('CONCAT requires at least one argument');
      }
      return values
          .where((value) => value != null)
          .map((value) => value.toString())
          .join();
    case 'CONCAT_WS':
      if (values.length < 2) {
        throw PureSqlException('CONCAT_WS requires a separator and value');
      }
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
    case 'TIMEDIFF':
      _requireArity(name, values, 2);
      if (values.any((value) => value == null)) return null;
      final target = _dateTimeValue(values[0]);
      final source = _dateTimeValue(values[1]);
      return target == null || source == null
          ? null
          : _formatSqlTimeDifference(target, source);
    case 'JULIANDAY':
      final date = _dateTimeFromValues(values);
      return date == null
          ? null
          : date.millisecondsSinceEpoch / Duration.millisecondsPerDay +
                2440587.5;
    case 'UNIXEPOCH':
      final date = _dateTimeFromValues(values);
      if (date == null) return null;
      final timestamp = date.millisecondsSinceEpoch;
      return values
              .skip(1)
              .any(
                (modifier) => const {
                  'subsec',
                  'subsecond',
                }.contains(modifier?.toString().toLowerCase()),
              )
          ? timestamp / 1000
          : timestamp ~/ 1000;
    // ponytail: JSON results are text; subtype propagation needs typed values
    // through expression evaluation and storage to match nested JSON calls.
    case 'JSON':
      _requireArity(name, values, 1);
      return values.single == null
          ? null
          : _encodeSqlJson(_decodeSqlJson(values.single));
    case 'JSON_PRETTY':
      if (values.isEmpty || values.length > 2) {
        throw PureSqlException('json_pretty expects one or two arguments');
      }
      if (values.first == null) return null;
      final indent = values.length == 2 && values[1] != null
          ? values[1].toString()
          : '    ';
      return _prettySqlJson(_decodeSqlJson(values.first), indent);
    case 'JSON_ERROR_POSITION':
      _requireArity(name, values, 1);
      return _jsonErrorPosition(values.single);
    case 'JSON_ARRAY':
      return _encodeSqlJson(values.map(_jsonSqlValue).toList());
    case 'JSON_OBJECT':
      if (values.length.isOdd) {
        throw PureSqlException(
          'json_object requires an even number of arguments',
        );
      }
      final members = <String>[];
      for (var index = 0; index < values.length; index += 2) {
        final key = values[index];
        if (key == null) {
          throw PureSqlException('json_object labels must not be NULL');
        }
        members.add(
          '${jsonEncode(key.toString())}:${_encodeSqlJson(_jsonSqlValue(values[index + 1]))}',
        );
      }
      return '{${members.join(',')}}';
    case 'JSON_ARRAY_INSERT':
      if (values.isEmpty || values.length.isEven) {
        throw PureSqlException('$name requires path/value pairs');
      }
      if (values.first == null) return null;
      var json = _decodeSqlJson(values.first);
      for (var index = 1; index < values.length; index += 2) {
        final path = values[index];
        if (path == null) return null;
        json = _jsonArrayInsert(
          json,
          _parseJsonPath(path.toString()),
          _jsonSqlValue(values[index + 1]),
        );
      }
      return _encodeSqlJson(json);
    case 'JSON_INSERT':
    case 'JSON_REPLACE':
    case 'JSON_SET':
      if (values.isEmpty || values.length.isEven) {
        throw PureSqlException('$name requires path/value pairs');
      }
      if (values.first == null) return null;
      var json = _decodeSqlJson(values.first);
      final mode = name.toLowerCase().substring(5);
      for (var index = 1; index < values.length; index += 2) {
        final path = values[index];
        if (path == null) continue;
        json = _jsonModify(
          json,
          _parseJsonPath(path.toString()),
          _jsonSqlValue(values[index + 1]),
          mode,
        );
      }
      return _encodeSqlJson(json);
    case 'JSON_REMOVE':
      if (values.isEmpty) {
        throw PureSqlException('json_remove requires at least one argument');
      }
      if (values.first == null || values.skip(1).any((path) => path == null)) {
        return null;
      }
      var json = _decodeSqlJson(values.first);
      for (final path in values.skip(1)) {
        final parts = _parseJsonPath(path!.toString());
        if (parts.isEmpty) return null;
        _jsonRemove(json, parts);
      }
      return _encodeSqlJson(json);
    case 'JSON_PATCH':
      _requireArity(name, values, 2);
      if (values.any((value) => value == null)) return null;
      return _encodeSqlJson(
        _jsonMergePatch(_decodeSqlJson(values[0]), _decodeSqlJson(values[1])),
      );
    case 'JSON_VALID':
      if (values.isEmpty || values.length > 2) {
        throw PureSqlException('json_valid expects one or two arguments');
      }
      if (values.length == 2 && values[1] == null) return null;
      final flags = values.length == 1 ? 1 : _asInt(values[1]);
      if (flags < 1 || flags > 15) {
        throw PureSqlException(
          'FLAGS parameter to json_valid() must be between 1 and 15',
        );
      }
      if (values.first == null || values.length == 2 && values[1] == null) {
        return null;
      }
      if (values.first is List<int> && flags & 0x0c != 0) {
        try {
          _readSqlJsonb(values.first as List<int>, deep: flags & 0x08 != 0);
          return 1;
        } on FormatException {
          // Continue with text validation if the flags allow it.
        }
      }
      if (flags & 0x01 != 0 || flags & 0x02 != 0) {
        try {
          final text = _jsonText(values.first);
          if (flags & 0x01 != 0) {
            try {
              jsonDecode(text);
              return 1;
            } on FormatException {
              // JSON5 may still be accepted by bit 0x02.
              if (flags & 0x02 == 0) return 0;
            }
          }
          if (flags & 0x02 != 0) {
            _Json5Parser(text).parse();
            return 1;
          }
          return 0;
        } on FormatException {
          return 0;
        }
      }
      return 0;
    case 'JSON_TYPE':
      if (values.isEmpty || values.length > 2) {
        throw PureSqlException('json_type expects one or two arguments');
      }
      if (values.first == null || values.length == 2 && values[1] == null) {
        return null;
      }
      final json = _decodeSqlJson(values.first);
      final value = values.length == 1
          ? json
          : _jsonPathValue(json, values[1]!.toString());
      return value == _missingJsonPath ? null : _jsonType(value);
    case 'JSON_ARRAY_LENGTH':
      if (values.isEmpty || values.length > 2) {
        throw PureSqlException(
          'json_array_length expects one or two arguments',
        );
      }
      if (values.first == null || values.length == 2 && values[1] == null) {
        return null;
      }
      final json = _decodeSqlJson(values.first);
      final value = values.length == 1
          ? json
          : _jsonPathValue(json, values[1]!.toString());
      if (value == _missingJsonPath) return null;
      return value is List ? value.length : 0;
    case 'JSON_EXTRACT':
      if (values.length < 2) {
        throw PureSqlException('json_extract expects at least two arguments');
      }
      if (values.first == null || values.skip(1).any((path) => path == null)) {
        return null;
      }
      final json = _decodeSqlJson(values.first);
      final extracted = [
        for (final path in values.skip(1))
          _jsonPathValue(json, path!.toString()),
      ];
      if (extracted.length > 1) {
        return _encodeSqlJson([
          for (final value in extracted)
            if (value == _missingJsonPath) null else value,
        ]);
      }
      final value = extracted.single;
      if (value == _missingJsonPath || value == null) return null;
      if (value is bool) return value ? 1 : 0;
      if (value is List || value is Map) return _encodeSqlJson(value);
      return value;
    case 'JSON_QUOTE':
      _requireArity(name, values, 1);
      final value = values.single;
      if (value == null) return 'null';
      return _encodeSqlJson(_jsonSqlValue(value));
    case 'STRFTIME':
      if (values.length < 2 || values.first is! String) return null;
      final date = _dateTimeFromValues(values.skip(1).toList());
      return date == null
          ? null
          : _formatSqlDate(
              values.first! as String,
              date,
              subsecond: values
                  .skip(2)
                  .any(
                    (modifier) => const {
                      'subsec',
                      'subsecond',
                    }.contains(modifier?.toString().toLowerCase()),
                  ),
            );
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

String _sqliteSoundex(Object? value) {
  final text = switch (value) {
    null => '',
    bool value => value ? '1' : '0',
    List<int> bytes => utf8.decode(bytes, allowMalformed: true),
    _ => value.toString(),
  };
  final characters = text.runes.toList();
  int codeFor(int character) {
    final upper = character >= 97 && character <= 122
        ? character - 32
        : character;
    return switch (upper) {
      66 || 70 || 80 || 86 => 1,
      67 || 71 || 74 || 75 || 81 || 83 || 88 || 90 => 2,
      68 || 84 => 3,
      76 => 4,
      77 || 78 => 5,
      82 => 6,
      _ => 0,
    };
  }

  var first = 0;
  while (first < characters.length &&
      !(characters[first] >= 65 && characters[first] <= 90 ||
          characters[first] >= 97 && characters[first] <= 122)) {
    first++;
  }
  if (first == characters.length) return '?000';

  final initial = characters[first] >= 97
      ? characters[first] - 32
      : characters[first];
  final result = StringBuffer()..writeCharCode(initial);
  var previousCode = codeFor(characters[first]);
  for (
    var index = first;
    index < characters.length && result.length < 4;
    index++
  ) {
    final code = codeFor(characters[index]);
    if (code == 0) {
      previousCode = 0;
    } else if (code != previousCode) {
      result.writeCharCode(code + 48);
      previousCode = code;
    }
  }
  while (result.length < 4) {
    result.write('0');
  }
  return result.toString();
}

const _missingJsonPath = Object();

Object? _decodeSqlJson(Object? value) {
  if (value == null) return null;
  if (value is List<int>) {
    try {
      return _readSqlJsonb(value);
    } on FormatException {
      // SQLite also accepts legacy text JSON stored in a BLOB.
    }
  }
  late final String text;
  try {
    text = _jsonText(value);
  } on FormatException {
    throw PureSqlException('malformed JSON');
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    try {
      return _Json5Parser(text).parse();
    } on FormatException {
      throw PureSqlException('malformed JSON');
    }
  }
}

Object? _applyJsonbFunction(String name, List<Object?> values) {
  if (name == 'JSONB_EXTRACT') {
    final result = _applyFunction('JSON_EXTRACT', values);
    if (result == null) return null;
    if (values.length > 2) return _encodeSqlJsonb(_decodeSqlJson(result));
    if (values.length < 2 || values.first == null || values[1] == null) {
      return result;
    }
    final extracted = _jsonPathValue(
      _decodeSqlJson(values.first),
      values[1].toString(),
    );
    return extracted is List || extracted is Map
        ? _encodeSqlJsonb(extracted)
        : result;
  }
  final jsonName = name.replaceFirst('JSONB_', 'JSON_');
  final result = _applyFunction(jsonName, values);
  return result == null ? null : _encodeSqlJsonb(_decodeSqlJson(result));
}

Object? _readSqlJsonb(List<int> bytes, {bool deep = true}) {
  final reader = _SqlJsonbReader(bytes);
  final value = reader.read(deep: deep);
  if (reader.position != bytes.length) {
    throw const FormatException('malformed JSONB');
  }
  return value;
}

List<int> _encodeSqlJsonb(Object? value) {
  List<int> element(Object? item) {
    late final int type;
    late final List<int> payload;
    if (item == null) {
      type = 0;
      payload = const [];
    } else if (item == true) {
      type = 1;
      payload = const [];
    } else if (item == false) {
      type = 2;
      payload = const [];
    } else if (item is int) {
      type = 3;
      payload = ascii.encode(item.toString());
    } else if (item is num) {
      type = 5;
      payload = ascii.encode(_encodeSqlJson(item));
    } else if (item is String) {
      final quoted = jsonEncode(item);
      final escaped = quoted.substring(1, quoted.length - 1);
      type = escaped == item ? 7 : 8;
      payload = utf8.encode(escaped);
    } else if (item is List) {
      type = 11;
      payload = [for (final child in item) ...element(child)];
    } else if (item is Map) {
      type = 12;
      payload = [
        for (final entry in item.entries) ...[
          ...element(entry.key.toString()),
          ...element(entry.value),
        ],
      ];
    } else {
      throw PureSqlException('unsupported JSONB value: ${item.runtimeType}');
    }
    final length = payload.length;
    if (length <= 11) return [(length << 4) | type, ...payload];
    final width = length <= 0xff
        ? 1
        : length <= 0xffff
        ? 2
        : length <= 0xffffffff
        ? 4
        : 8;
    final header = switch (width) {
      1 => 12,
      2 => 13,
      4 => 14,
      _ => 15,
    };
    return [
      (header << 4) | type,
      for (var shift = (width - 1) * 8; shift >= 0; shift -= 8)
        (length >> shift) & 0xff,
      ...payload,
    ];
  }

  return element(value);
}

class _SqlJsonbReader {
  _SqlJsonbReader(this.bytes);

  final List<int> bytes;
  var position = 0;

  Object? read({bool deep = true, int limit = -1}) {
    final boundary = limit < 0 ? bytes.length : limit;
    if (position >= boundary) throw const FormatException('malformed JSONB');
    final header = bytes[position++];
    final type = header & 0x0f;
    final sizeCode = header >> 4;
    var size = sizeCode;
    if (sizeCode >= 12) {
      final width = 1 << (sizeCode - 12);
      if (position + width > boundary) {
        throw const FormatException('malformed JSONB');
      }
      size = 0;
      for (var index = 0; index < width; index++) {
        size = (size << 8) | bytes[position++];
      }
    }
    final start = position;
    final end = start + size;
    if (end < start || end > boundary || type > 12) {
      throw const FormatException('malformed JSONB');
    }
    if (!deep) {
      position = end;
      return null;
    }
    Object? value;
    switch (type) {
      case 0:
        value = null;
      case 1:
        value = true;
      case 2:
        value = false;
      case 3:
      case 4:
      case 5:
      case 6:
        final text = ascii.decode(bytes.sublist(start, end));
        if (type == 3) {
          value = int.tryParse(text);
          value ??= num.tryParse(text);
        } else if (type == 5) {
          value = double.tryParse(text);
        } else {
          value = _Json5Parser(text).parse();
        }
        if (value is! num) throw const FormatException('malformed JSONB');
      case 7:
      case 10:
        value = utf8.decode(bytes.sublist(start, end));
      case 8:
        value = jsonDecode('"${utf8.decode(bytes.sublist(start, end))}"');
      case 9:
        value = _Json5Parser(
          '"${utf8.decode(bytes.sublist(start, end))}"',
        ).parse();
      case 11:
        final items = <Object?>[];
        while (position < end) {
          items.add(read(limit: end));
        }
        value = items;
      case 12:
        final items = <String, Object?>{};
        while (position < end) {
          final key = read(limit: end);
          if (key is! String || position >= end) {
            throw const FormatException('malformed JSONB');
          }
          items[key] = read(limit: end);
        }
        value = items;
    }
    if (type < 11) position = end;
    if (position != end) throw const FormatException('malformed JSONB');
    return value;
  }
}

String _jsonText(Object? value) => switch (value) {
  List<int>() => utf8.decode(value, allowMalformed: false),
  bool() => value ? '1' : '0',
  _ => value.toString(),
};

class _Json5Parser {
  _Json5Parser(this.source) : _units = source.codeUnits;

  final String source;
  final List<int> _units;
  var _position = 0;
  var _depth = 0;

  Object? parse() {
    _skipSpace();
    final value = _value();
    _skipSpace();
    if (_position != _units.length) _fail();
    return value;
  }

  Object? _value() {
    _skipSpace();
    if (_position == _units.length) _fail();
    return switch (_units[_position]) {
      0x7b => _object(),
      0x5b => _array(),
      0x22 || 0x27 => _string(),
      _ => _numberOrLiteral(),
    };
  }

  Map<String, Object?> _object() {
    if (++_depth > 1000) _fail();
    try {
      _position++;
      _skipSpace();
      final result = <String, Object?>{};
      if (_take(0x7d)) return result;
      while (true) {
        _skipSpace();
        final key =
            _position < _units.length &&
                (_units[_position] == 0x22 || _units[_position] == 0x27)
            ? _string()
            : _identifier();
        _skipSpace();
        if (!_take(0x3a)) _fail();
        result[key] = _value();
        _skipSpace();
        if (_take(0x7d)) return result;
        if (!_take(0x2c)) _fail();
        _skipSpace();
        if (_take(0x7d)) return result;
      }
    } finally {
      _depth--;
    }
  }

  List<Object?> _array() {
    if (++_depth > 1000) _fail();
    try {
      _position++;
      _skipSpace();
      final result = <Object?>[];
      if (_take(0x5d)) return result;
      while (true) {
        result.add(_value());
        _skipSpace();
        if (_take(0x5d)) return result;
        if (!_take(0x2c)) _fail();
        _skipSpace();
        if (_take(0x5d)) return result;
      }
    } finally {
      _depth--;
    }
  }

  String _string() {
    final quote = _units[_position++];
    final result = StringBuffer();
    while (_position < _units.length) {
      final unit = _units[_position++];
      if (unit == quote) return result.toString();
      if (unit == 0x5c) {
        if (_position == _units.length) _fail();
        final escaped = _units[_position++];
        if (escaped == 0x0a || escaped == 0x2028 || escaped == 0x2029) {
          continue;
        }
        if (escaped == 0x0d) {
          if (_position < _units.length && _units[_position] == 0x0a) {
            _position++;
          }
          continue;
        }
        switch (escaped) {
          case 0x62:
            result.writeCharCode(0x08);
          case 0x66:
            result.writeCharCode(0x0c);
          case 0x6e:
            result.writeCharCode(0x0a);
          case 0x72:
            result.writeCharCode(0x0d);
          case 0x74:
            result.writeCharCode(0x09);
          case 0x76:
            result.writeCharCode(0x0b);
          case 0x78:
            result.writeCharCode(_hexEscape(2));
          case 0x75:
            result.writeCharCode(_hexEscape(4));
          case 0x30:
            if (_position < _units.length &&
                _units[_position] >= 0x30 &&
                _units[_position] <= 0x39) {
              _fail();
            }
            result.writeCharCode(0);
          default:
            result.writeCharCode(escaped);
        }
      } else {
        if (unit < 0x20 || unit == 0x2028 || unit == 0x2029) _fail();
        result.writeCharCode(unit);
      }
    }
    _fail();
  }

  int _hexEscape(int count) {
    if (_position + count > _units.length) _fail();
    final digits = source.substring(_position, _position + count);
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(digits)) _fail();
    _position += count;
    return int.parse(digits, radix: 16);
  }

  String _identifier() {
    final result = StringBuffer();
    var first = true;
    while (_position < _units.length) {
      final unit = _units[_position];
      final escaped = unit == 0x5c;
      final codePoint = escaped ? _escapedIdentifierCodePoint() : unit;
      final asciiLetter =
          codePoint >= 0x41 && codePoint <= 0x5a ||
          codePoint >= 0x61 && codePoint <= 0x7a;
      final digit = codePoint >= 0x30 && codePoint <= 0x39;
      final identifierStart =
          asciiLetter ||
          codePoint == 0x24 ||
          codePoint == 0x5f ||
          codePoint > 0x7f && !_isSpace(codePoint);
      if (identifierStart || !first && digit) {
        if (!escaped) _position++;
        result.writeCharCode(codePoint);
        first = false;
      } else {
        if (escaped) _fail();
        break;
      }
    }
    if (first) _fail();
    return result.toString();
  }

  int _escapedIdentifierCodePoint() {
    _position++;
    if (_position == _units.length || _units[_position++] != 0x75) _fail();
    return _hexEscape(4);
  }

  Object? _numberOrLiteral() {
    final start = _position;
    while (_position < _units.length && !_isDelimiter(_units[_position])) {
      _position++;
    }
    final token = source.substring(start, _position);
    if (token == 'true') return true;
    if (token == 'false') return false;
    if (token == 'null') return null;
    final unsigned = token.startsWith('+') || token.startsWith('-')
        ? token.substring(1)
        : token;
    final special = unsigned.toLowerCase();
    if (const {'nan', 'qnan', 'snan'}.contains(special)) return null;
    if (const {'inf', 'infinity'}.contains(special)) {
      return token.startsWith('-') ? double.negativeInfinity : double.infinity;
    }
    final hex = RegExp(r'^([+-]?)0[xX]([0-9a-fA-F]+)$').firstMatch(token);
    if (hex != null) {
      final value = int.parse(hex[2]!, radix: 16);
      return hex[1] == '-' ? -value : value;
    }
    if (RegExp(r'^0\d').hasMatch(unsigned)) _fail(start);
    if (!RegExp(
      r'^[+-]?(?:(?:\d+\.?\d*)|(?:\.\d+))(?:[eE][+-]?\d+)?$',
    ).hasMatch(token)) {
      _fail(start);
    }
    final normalized = token.startsWith('+') ? token.substring(1) : token;
    if (normalized.contains('.') || normalized.contains(RegExp('[eE]'))) {
      return double.parse(normalized);
    }
    return int.tryParse(normalized) ?? double.parse(normalized);
  }

  void _skipSpace() {
    while (_position < _units.length) {
      final unit = _units[_position];
      if (_isSpace(unit)) {
        _position++;
      } else if (unit == 0x2f &&
          _position + 1 < _units.length &&
          _units[_position + 1] == 0x2f) {
        _position += 2;
        while (_position < _units.length && !_isLineBreak(_units[_position])) {
          _position++;
        }
      } else if (unit == 0x2f &&
          _position + 1 < _units.length &&
          _units[_position + 1] == 0x2a) {
        _position += 2;
        while (_position + 1 < _units.length &&
            !(_units[_position] == 0x2a && _units[_position + 1] == 0x2f)) {
          _position++;
        }
        if (_position + 1 == _units.length) _fail();
        _position += 2;
      } else {
        return;
      }
    }
  }

  bool _take(int unit) {
    if (_position < _units.length && _units[_position] == unit) {
      _position++;
      return true;
    }
    return false;
  }

  bool _isDelimiter(int unit) =>
      _isSpace(unit) || const [0x2c, 0x5d, 0x7d, 0x2f].contains(unit);

  bool _isLineBreak(int unit) =>
      unit == 0x0a || unit == 0x0d || unit == 0x2028 || unit == 0x2029;

  bool _isSpace(int unit) =>
      unit <= 0x20 ||
      const [
        0x00a0,
        0x1680,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        0xfeff,
      ].contains(unit) ||
      unit >= 0x2000 && unit <= 0x200a;

  Never _fail([int? position]) =>
      throw FormatException('Invalid JSON5', source, position ?? _position);
}

Object? _jsonErrorPosition(Object? value) {
  if (value == null) return null;
  if (value is List<int>) {
    try {
      _readSqlJsonb(value);
      return 0;
    } on FormatException {
      // Treat non-JSONB blobs as legacy text JSON when possible.
    }
  }
  late final String text;
  try {
    text = _jsonText(value);
  } on FormatException {
    return 1;
  }
  try {
    jsonDecode(text);
    return 0;
  } on FormatException {
    try {
      _Json5Parser(text).parse();
      return 0;
    } on FormatException catch (json5Error) {
      return _jsonErrorOffset(json5Error);
    }
  }
}

Object? _jsonErrorOffset(FormatException error) {
  final offset = error.offset ?? -1;
  final source = error.source;
  if (source is String && offset >= 0) {
    return source
            .substring(0, math.min(offset, source.length).toInt())
            .runes
            .length +
        1;
  }
  return offset < 0 ? 1 : offset + 1;
}

String _encodeSqlJson(Object? value) => switch (value) {
  null => 'null',
  bool() => value ? 'true' : 'false',
  int() => value.toString(),
  double() when value.isNaN => 'null',
  double() when value == double.infinity => '9e999',
  double() when value == double.negativeInfinity => '-9e999',
  num() => jsonEncode(value),
  String() => jsonEncode(value),
  List() => '[${value.map(_encodeSqlJson).join(',')}]',
  Map() =>
    '{${value.entries.map((entry) => '${jsonEncode(entry.key.toString())}:${_encodeSqlJson(entry.value)}').join(',')}}',
  _ => throw PureSqlException('unsupported JSON value: ${value.runtimeType}'),
};

String _prettySqlJson(Object? value, String indent, [int depth = 0]) {
  final padding = List.filled(depth, indent).join();
  if (value is List) {
    if (value.isEmpty) return '[]';
    final childPadding = '$padding$indent';
    return '[\n${value.map((item) => '$childPadding${_prettySqlJson(item, indent, depth + 1)}').join(',\n')}\n$padding]';
  }
  if (value is Map) {
    if (value.isEmpty) return '{}';
    final childPadding = '$padding$indent';
    return '{\n${value.entries.map((entry) => '$childPadding${jsonEncode(entry.key.toString())}: ${_prettySqlJson(entry.value, indent, depth + 1)}').join(',\n')}\n$padding}';
  }
  return _encodeSqlJson(value);
}

Object? _jsonSqlValue(Object? value) {
  if (value is List<int>) {
    try {
      return _readSqlJsonb(value);
    } on FormatException {
      // Ordinary SQL blobs remain unsupported JSON values.
    }
    throw PureSqlException('JSON functions cannot encode BLOB values');
  }
  return value is bool ? (value ? 1 : 0) : value;
}

String _jsonType(Object? value) => switch (value) {
  null => 'null',
  bool() => value ? 'true' : 'false',
  int() => 'integer',
  num() => 'real',
  String() => 'text',
  List() => 'array',
  Map() => 'object',
  _ => 'null',
};

List<_ColumnDef> _jsonTableFunctionColumns(String name) {
  if (!const {
    'json_each',
    'json_tree',
    'jsonb_each',
    'jsonb_tree',
  }.contains(name.toLowerCase())) {
    throw PureSqlException('unsupported table-valued function: $name');
  }
  return [
    for (final column in const [
      'key',
      'value',
      'type',
      'atom',
      'id',
      'parent',
      'fullkey',
      'path',
    ])
      _ColumnDef(column),
  ];
}

List<_ColumnDef> _tableFunctionColumns(String name) {
  final normalized = name.toLowerCase();
  if (!normalized.startsWith('pragma_')) {
    return _jsonTableFunctionColumns(normalized);
  }
  final columns =
      _pragmaTableFunctionColumns[normalized.substring('pragma_'.length)];
  if (columns == null) {
    throw PureSqlException('unsupported table-valued function: $name');
  }
  return [for (final column in columns) _ColumnDef(column)];
}

List<SqlRow> _jsonTableFunctionRows(
  String name,
  Object? selected,
  List<Object> selectedPath,
) {
  String fullKey(List<Object> path) => path.fold<String>(r'$', (result, part) {
    if (part is int) return '$result[$part]';
    final key = part as String;
    return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)
        ? '$result.$key'
        : '$result.${jsonEncode(key)}';
  });

  Object? keyFor(List<Object> path) => path.isEmpty ? null : path.last;
  final rootFullKey = fullKey(selectedPath);
  final rootPath = selectedPath.isEmpty
      ? r'$'
      : fullKey(selectedPath.take(selectedPath.length - 1).toList());
  final rows = <SqlRow>[];
  var nextId = 0;

  void append(
    Object? value,
    Object? key,
    int? parent,
    String fullkey,
    String path,
  ) {
    final id = nextId++;
    final container = value is Map || value is List;
    rows.add({
      'key': key,
      'value': container
          ? name.toLowerCase().startsWith('jsonb_')
                ? _encodeSqlJsonb(value)
                : _encodeSqlJson(value)
          : _jsonSqlValue(value),
      'type': _jsonType(value),
      'atom': container ? null : _jsonSqlValue(value),
      'id': id,
      'parent': parent,
      'fullkey': fullkey,
      'path': path,
    });
    if (name.toLowerCase() != 'json_tree') return;
    if (value is Map) {
      for (final entry in value.entries) {
        final childKey = entry.key.toString();
        final childPath = [..._parseJsonPath(fullkey), childKey];
        append(entry.value, childKey, id, fullKey(childPath), fullkey);
      }
    } else if (value is List) {
      for (var index = 0; index < value.length; index++) {
        final childPath = [..._parseJsonPath(fullkey), index];
        append(value[index], index, id, fullKey(childPath), fullkey);
      }
    }
  }

  if (name.toLowerCase().endsWith('tree')) {
    append(
      selected,
      keyFor(selectedPath),
      null,
      rootFullKey,
      selected is Map || selected is List ? rootPath : rootFullKey,
    );
  } else if (selected is Map) {
    for (final entry in selected.entries) {
      final childKey = entry.key.toString();
      final childPath = [...selectedPath, childKey];
      append(entry.value, childKey, null, fullKey(childPath), rootFullKey);
    }
  } else if (selected is List) {
    for (var index = 0; index < selected.length; index++) {
      final childPath = [...selectedPath, index];
      append(selected[index], index, null, fullKey(childPath), rootFullKey);
    }
  } else {
    append(selected, null, null, rootFullKey, rootFullKey);
  }
  return rows;
}

Object? _jsonPathValue(Object? root, String path) {
  final parts = _parseJsonPath(path);
  var value = root;
  for (final part in parts) {
    if (part is String) {
      if (value is! Map || !value.containsKey(part)) return _missingJsonPath;
      value = value[part];
    } else if (part is _JsonAppend) {
      return _missingJsonPath;
    } else {
      if (value is! List) return _missingJsonPath;
      final arrayIndex = part as int;
      final index = arrayIndex < 0 ? value.length + arrayIndex : arrayIndex;
      if (index < 0 || index >= value.length) return _missingJsonPath;
      value = value[index];
    }
  }
  return value;
}

class _JsonAppend {
  const _JsonAppend();
}

const _jsonAppend = _JsonAppend();

Object? _jsonModify(
  Object? root,
  List<Object> parts,
  Object? replacement,
  String mode,
) {
  if (parts.isEmpty) return mode == 'insert' ? root : replacement;
  Object? parent = root;
  for (final part in parts.take(parts.length - 1)) {
    parent = _jsonChild(parent, part);
    if (parent == _missingJsonPath) return root;
  }
  final target = parts.last;
  if (target is String) {
    if (parent is! Map) return root;
    final exists = parent.containsKey(target);
    if (mode == 'insert' && exists || mode == 'replace' && !exists) {
      return root;
    }
    parent[target] = replacement;
  } else if (parent is List) {
    final index = switch (target) {
      _JsonAppend() => parent.length,
      int() => target < 0 ? parent.length + target : target,
      _ => parent.length,
    };
    if (index < 0 || index > parent.length) return root;
    final exists = index < parent.length;
    if (mode == 'insert' && exists || mode == 'replace' && !exists) {
      return root;
    }
    if (exists) {
      parent[index] = replacement;
    } else {
      parent.add(replacement);
    }
  }
  return root;
}

Object? _jsonArrayInsert(Object? root, List<Object> parts, Object? value) {
  if (parts.isEmpty || parts.last is! int && parts.last is! _JsonAppend) {
    throw PureSqlException('json_array_insert path must end at an array index');
  }
  Object? parent = root;
  for (final part in parts.take(parts.length - 1)) {
    parent = _jsonChild(parent, part);
    if (parent == _missingJsonPath) return root;
  }
  if (parent is! List) return root;
  final target = parts.last;
  final index = switch (target) {
    _JsonAppend() => parent.length,
    int() => target < 0 ? parent.length + target : target,
    _ => parent.length,
  };
  if (index >= 0 && index <= parent.length) parent.insert(index, value);
  return root;
}

Object? _jsonChild(Object? parent, Object part) {
  if (part is String) {
    return parent is Map && parent.containsKey(part)
        ? parent[part]
        : _missingJsonPath;
  }
  if (part is! int || parent is! List) return _missingJsonPath;
  final index = part < 0 ? parent.length + part : part;
  return index < 0 || index >= parent.length ? _missingJsonPath : parent[index];
}

void _jsonRemove(Object? root, List<Object> parts) {
  Object? parent = root;
  for (final part in parts.take(parts.length - 1)) {
    parent = _jsonChild(parent, part);
    if (parent == _missingJsonPath) return;
  }
  final target = parts.last;
  if (target is String && parent is Map) {
    parent.remove(target);
  } else if (target is int && parent is List) {
    final index = target < 0 ? parent.length + target : target;
    if (index >= 0 && index < parent.length) parent.removeAt(index);
  }
}

Object? _jsonMergePatch(Object? target, Object? patch) {
  if (patch is! Map) return patch;
  final result = <String, Object?>{
    if (target is Map)
      for (final entry in target.entries) entry.key: entry.value,
  };
  for (final entry in patch.entries) {
    final key = entry.key.toString();
    if (entry.value == null) {
      result.remove(key);
    } else {
      result[key] = _jsonMergePatch(result[key], entry.value);
    }
  }
  return result;
}

List<Object> _parseJsonPath(String path) {
  if (path.isEmpty || path.codeUnitAt(0) != 0x24) {
    throw PureSqlException('invalid JSON path: $path');
  }
  final parts = <Object>[];
  var index = 1;
  while (index < path.length) {
    final marker = path.codeUnitAt(index++);
    if (marker == 0x2e) {
      if (index == path.length) {
        throw PureSqlException('invalid JSON path: $path');
      }
      if (path.codeUnitAt(index) == 0x22) {
        final start = index++;
        var escaped = false;
        while (index < path.length) {
          final code = path.codeUnitAt(index++);
          if (escaped) {
            escaped = false;
          } else if (code == 0x5c) {
            escaped = true;
          } else if (code == 0x22) {
            break;
          }
        }
        if (path.codeUnitAt(index - 1) != 0x22) {
          throw PureSqlException('invalid JSON path: $path');
        }
        try {
          parts.add(jsonDecode(path.substring(start, index)) as String);
        } on FormatException {
          throw PureSqlException('invalid JSON path: $path');
        }
      } else {
        final start = index;
        while (index < path.length &&
            path.codeUnitAt(index) != 0x2e &&
            path.codeUnitAt(index) != 0x5b) {
          if (path.codeUnitAt(index) == 0x22) {
            throw PureSqlException('invalid JSON path: $path');
          }
          index++;
        }
        if (start == index) throw PureSqlException('invalid JSON path: $path');
        parts.add(path.substring(start, index));
      }
    } else if (marker == 0x5b) {
      final close = path.indexOf(']', index);
      if (close < 0) throw PureSqlException('invalid JSON path: $path');
      final component = path.substring(index, close);
      if (component == '#') {
        parts.add(_jsonAppend);
        index = close + 1;
        continue;
      }
      final arrayIndex = int.tryParse(component);
      final fromEnd = RegExp(r'^#-[1-9]\d*$').hasMatch(component)
          ? int.tryParse(component.substring(1))
          : null;
      if (arrayIndex == null && fromEnd == null ||
          arrayIndex != null && arrayIndex < 0) {
        throw PureSqlException('invalid JSON path: $path');
      }
      parts.add(fromEnd == null ? arrayIndex! : -fromEnd);
      index = close + 1;
    } else {
      throw PureSqlException('invalid JSON path: $path');
    }
  }
  return parts;
}

String? _formatSql(List<Object?> values) {
  if (values.isEmpty || values.first == null) return null;
  final format = values.first.toString();
  final arguments = values.skip(1).toList();
  final runes = format.runes.toList();
  final output = StringBuffer();
  var argumentIndex = 0;
  var index = 0;

  Object? nextArgument() =>
      argumentIndex < arguments.length ? arguments[argumentIndex++] : null;

  int? readNumber() {
    final start = index;
    while (index < runes.length &&
        runes[index] >= 0x30 &&
        runes[index] <= 0x39) {
      index++;
    }
    return start == index
        ? null
        : int.tryParse(String.fromCharCodes(runes.sublist(start, index)));
  }

  while (index < runes.length) {
    if (runes[index] != 0x25) {
      output.writeCharCode(runes[index++]);
      continue;
    }
    index++;
    if (index == runes.length) {
      output.write('%');
      break;
    }
    if (runes[index] == 0x25) {
      output.write('%');
      index++;
      continue;
    }

    final flags = <int>{};
    while (index < runes.length &&
        const [
          0x2d,
          0x2b,
          0x20,
          0x23,
          0x30,
          0x2c,
          0x21,
        ].contains(runes[index])) {
      flags.add(runes[index++]);
    }
    var leftJustify = flags.contains(0x2d);
    int? width;
    if (index < runes.length && runes[index] == 0x2a) {
      final rawWidth = nextArgument();
      width = rawWidth is num
          ? rawWidth.toInt()
          : int.tryParse(rawWidth?.toString() ?? '') ?? 0;
      if (width < 0) {
        width = -width;
        leftJustify = true;
      }
      index++;
    } else {
      width = readNumber();
    }
    if (width != null && width > 1000000) {
      // ponytail: bound SQL-controlled output; use a streaming formatter if this ceiling must grow.
      throw PureSqlException('format width exceeds the 1,000,000 limit');
    }

    int? precision;
    if (index < runes.length && runes[index] == 0x2e) {
      index++;
      if (index < runes.length && runes[index] == 0x2a) {
        final rawPrecision = nextArgument();
        final parsed = rawPrecision is num
            ? rawPrecision.toInt()
            : int.tryParse(rawPrecision?.toString() ?? '') ?? 0;
        precision = parsed < 0 ? null : parsed;
        index++;
      } else {
        precision = readNumber() ?? 0;
      }
      if (precision != null && precision > 1000000) {
        // ponytail: bound SQL-controlled output; use a streaming formatter if this ceiling must grow.
        throw PureSqlException('format precision exceeds the 1,000,000 limit');
      }
    }
    while (index < runes.length &&
        const [0x68, 0x6c, 0x7a, 0x74, 0x6a, 0x4c].contains(runes[index])) {
      index++;
    }
    if (index == runes.length) {
      output.write('%');
      break;
    }
    final type = String.fromCharCode(runes[index++]);
    if (type == 'n') continue;
    if (type == '%') {
      output.write(_padSqlFormat('%', width, leftJustify, false, false));
      continue;
    }
    if (!'diuoxXpcsqQwzfFeEgG'.contains(type)) {
      output.write('%$type');
      continue;
    }

    final value = nextArgument();
    var text = '';
    var numeric = false;
    var allowZeroPadding = false;
    if ('diuoxXp'.contains(type)) {
      numeric = true;
      allowZeroPadding = precision == null;
      final integer = _formatSqlInteger(value);
      final signed = type == 'd' || type == 'i';
      final negative = signed && integer.isNegative;
      final unsigned = integer.toUnsigned(64);
      final radix = switch (type) {
        'o' => 8,
        'x' || 'p' => 16,
        'X' => 16,
        _ => 10,
      };
      var digits = (signed ? integer.abs() : unsigned).toRadixString(radix);
      if (type == 'X' || type == 'p') digits = digits.toUpperCase();
      if (precision != null) digits = digits.padLeft(precision, '0');
      if (flags.contains(0x23)) {
        if (type == 'x' && unsigned != BigInt.zero) digits = '0x$digits';
        if (type == 'X' && unsigned != BigInt.zero) digits = '0X$digits';
        if (type == 'p' && unsigned != BigInt.zero) {
          digits = '0x$digits';
        }
        if (type == 'o' && !digits.startsWith('0')) digits = '0$digits';
      }
      if (flags.contains(0x2c) && (type == 'd' || type == 'i' || type == 'u')) {
        digits = _groupSqlDecimal(digits);
      }
      text = negative
          ? '-$digits'
          : signed && flags.contains(0x2b)
          ? '+$digits'
          : signed && flags.contains(0x20)
          ? ' $digits'
          : digits;
    } else if ('fFeEgG'.contains(type)) {
      numeric = true;
      allowZeroPadding = true;
      final number = _formatSqlDouble(value);
      final digits = precision ?? 6;
      final alternateOne = flags.contains(0x23);
      final alternateTwo = flags.contains(0x21);
      final significantLimit = alternateTwo ? 26 : 16;
      var sign = '';
      if (number.isNaN) {
        text = flags.contains(0x30) ? 'null' : 'NaN';
      } else if (!number.isFinite) {
        text = flags.contains(0x30) ? '9.0e+999' : 'Inf';
      } else {
        text = switch (type.toLowerCase()) {
          'f' => _formatSqlFloatFixed(
            number.abs(),
            digits,
            significantLimit,
            trimTrailingZeros: alternateTwo,
          ),
          'e' => _formatSqlFloatExponential(
            number.abs(),
            digits,
            significantLimit,
            trimTrailingZeros: alternateTwo,
          ),
          _ => _formatSqlFloatGeneral(
            number.abs(),
            digits,
            significantLimit,
            trimTrailingZeros: !alternateOne || alternateTwo,
          ),
        };
        if (alternateOne && !alternateTwo && !text.contains('.')) {
          final exponent = text.indexOf(RegExp('[eE]'));
          text = exponent < 0
              ? '$text.'
              : '${text.substring(0, exponent)}.${text.substring(exponent)}';
        } else if (alternateTwo && !text.contains('.')) {
          final exponent = text.indexOf(RegExp('[eE]'));
          text = exponent < 0
              ? '$text.0'
              : '${text.substring(0, exponent)}.0${text.substring(exponent)}';
        }
        if (flags.contains(0x2c)) text = _groupSqlDecimal(text);
        if (number.isNegative && number != 0) {
          sign = '-';
        } else if (flags.contains(0x2b)) {
          sign = '+';
        } else if (flags.contains(0x20)) {
          sign = ' ';
        }
        text = '$sign$text';
      }
      if (number.isNaN || !number.isFinite) {
        if (type == 'E' || type == 'G') text = text.toUpperCase();
        if (number.isNegative) {
          text = '-$text';
        } else if (flags.contains(0x2b)) {
          text = '+$text';
        } else if (flags.contains(0x20)) {
          text = ' $text';
        }
      } else if (type == 'E' || type == 'G') {
        text = text.toUpperCase();
      }
    } else {
      var raw = _formatSqlText(value).split('\u0000').first;
      if (type == 'c') {
        final characters = raw.runes.toList();
        raw = characters.isEmpty
            ? '\u0000'
            : String.fromCharCode(characters.first);
        if (precision != null && precision > 1) {
          raw = List.filled(precision, raw).join();
        }
        text = raw;
      } else {
        raw = _truncateSqlFormatText(
          raw,
          precision,
          characters: flags.contains(0x21),
        );
        if (type == 'q' || type == 'Q' || type == 'w') {
          if (type == 'w') {
            text = raw.replaceAll('"', '""');
          } else if (type == 'Q' && value == null) {
            text = 'NULL';
          } else if (flags.contains(0x23)) {
            final quoted = _applyFunction('UNISTR_QUOTE', [raw]) as String;
            if (type == 'q') {
              text = quoted.startsWith("unistr('")
                  ? quoted.substring(8, quoted.length - 2)
                  : raw.replaceAll('\\', '\\\\').replaceAll("'", "''");
            } else {
              text = quoted;
            }
          } else {
            final escaped = raw.replaceAll("'", "''");
            text = type == 'Q' ? "'$escaped'" : escaped;
          }
        } else {
          text = raw;
        }
      }
    }
    output.write(
      _padSqlFormat(
        text,
        width,
        leftJustify,
        numeric && flags.contains(0x30) && allowZeroPadding,
        flags.contains(0x21),
      ),
    );
  }
  return output.toString();
}

BigInt _formatSqlInteger(Object? value) {
  if (value is num) {
    return value.isFinite ? BigInt.from(value.toInt()) : BigInt.zero;
  }
  final match = RegExp(r'^\s*[+-]?\d+').firstMatch(_formatSqlText(value));
  return match == null
      ? BigInt.zero
      : BigInt.tryParse(match.group(0)!.trim()) ?? BigInt.zero;
}

double _formatSqlDouble(Object? value) {
  if (value is num) return value.toDouble();
  final match = RegExp(
    r'^\s*[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?',
  ).firstMatch(_formatSqlText(value));
  return match == null ? 0 : double.tryParse(match.group(0)!.trim()) ?? 0;
}

String _formatSqlFloatFixed(
  double value,
  int precision,
  int significantLimit, {
  required bool trimTrailingZeros,
}) {
  if (value == 0) {
    return precision == 0 || trimTrailingZeros
        ? '0'
        : '0.${List.filled(precision, '0').join()}';
  }
  final exponent = _sqlDecimalExponent(value);
  final decimalPlaces = math.min(
    precision,
    math.max(0, significantLimit - exponent - 1),
  );
  var result = _roundSqlDecimal(value, decimalPlaces);
  if (precision > decimalPlaces) {
    final zeros = List.filled(
      precision - math.max(0, decimalPlaces),
      '0',
    ).join();
    result = result.contains('.') ? '$result$zeros' : '$result.$zeros';
  }
  if (trimTrailingZeros && result.contains('.')) {
    result = result
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  return result;
}

String _formatSqlFloatExponential(
  double value,
  int precision,
  int significantLimit, {
  required bool trimTrailingZeros,
}) {
  final digitCount = math.min(precision + 1, significantLimit);
  final rounded = _roundSqlSignificant(value, digitCount);
  var fraction = rounded.digits.substring(1);
  if (precision > fraction.length) {
    fraction += List.filled(precision - fraction.length, '0').join();
  }
  if (trimTrailingZeros) fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  final mantissa = fraction.isEmpty
      ? rounded.digits[0]
      : '${rounded.digits[0]}.$fraction';
  final exponent = rounded.exponent;
  return '$mantissa'
      'e${exponent < 0 ? '-' : '+'}${exponent.abs().toString().padLeft(2, '0')}';
}

String _formatSqlFloatGeneral(
  double value,
  int precision,
  int significantLimit, {
  required bool trimTrailingZeros,
}) {
  final digitCount = math.min(math.max(precision, 1), significantLimit);
  final rounded = _roundSqlSignificant(value, digitCount);
  final useExponent = rounded.exponent < -4 || rounded.exponent >= digitCount;
  String mantissa;
  if (useExponent) {
    var fraction = rounded.digits.substring(1);
    if (trimTrailingZeros) {
      fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
    }
    mantissa = fraction.isEmpty
        ? rounded.digits[0]
        : '${rounded.digits[0]}.$fraction';
    final exponent = rounded.exponent;
    mantissa +=
        'e${exponent < 0 ? '-' : '+'}${exponent.abs().toString().padLeft(2, '0')}';
  } else if (rounded.exponent < 0) {
    mantissa =
        '0.${List.filled(-rounded.exponent - 1, '0').join()}${rounded.digits}';
  } else {
    final point = rounded.exponent + 1;
    mantissa = point >= rounded.digits.length
        ? '${rounded.digits}${List.filled(point - rounded.digits.length, '0').join()}'
        : '${rounded.digits.substring(0, point)}.${rounded.digits.substring(point)}';
  }
  if (!trimTrailingZeros) return mantissa;
  final exponentPosition = mantissa.indexOf(RegExp('[eE]'));
  final number = exponentPosition < 0
      ? mantissa
      : mantissa.substring(0, exponentPosition);
  if (!number.contains('.')) return mantissa;
  final trimmed = number
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return exponentPosition < 0
      ? trimmed
      : '$trimmed${mantissa.substring(exponentPosition)}';
}

({String digits, int exponent}) _roundSqlSignificant(
  double value,
  int digitCount,
) {
  if (value == 0) {
    return (digits: List.filled(digitCount, '0').join(), exponent: 0);
  }
  final exponent = _sqlDecimalExponent(value);
  final rounded = _roundSqlDecimal(value, digitCount - exponent - 1);
  final point = rounded.indexOf('.');
  final integerDigits = point < 0 ? rounded : rounded.substring(0, point);
  final digits = point < 0
      ? rounded
      : '$integerDigits${rounded.substring(point + 1)}';
  final firstNonzero = digits.indexOf(RegExp('[1-9]'));
  if (firstNonzero < 0) {
    return (digits: List.filled(digitCount, '0').join(), exponent: 0);
  }
  return (
    digits: digits
        .substring(firstNonzero)
        .padRight(digitCount, '0')
        .substring(0, digitCount),
    exponent: integerDigits.length - firstNonzero - 1,
  );
}

String _roundSqlDecimal(double value, int decimalPlaces) {
  if (value == 0) {
    return decimalPlaces > 0
        ? '0.${List.filled(decimalPlaces, '0').join()}'
        : '0';
  }
  final (numerator, denominator) = _sqlDoubleRational(value);
  final scale = BigInt.from(10).pow(decimalPlaces.abs());
  var scaledNumerator = numerator;
  var scaledDenominator = denominator;
  if (decimalPlaces >= 0) {
    scaledNumerator *= scale;
  } else {
    scaledDenominator *= scale;
  }
  var rounded = scaledNumerator ~/ scaledDenominator;
  final remainder = scaledNumerator % scaledDenominator;
  if (remainder * BigInt.from(2) >= scaledDenominator) {
    rounded += BigInt.one;
  }
  if (decimalPlaces < 0) rounded *= scale;
  final digits = rounded.toString();
  if (decimalPlaces <= 0) return digits;
  final padded = digits.padLeft(decimalPlaces + 1, '0');
  final split = padded.length - decimalPlaces;
  return '${padded.substring(0, split)}.${padded.substring(split)}';
}

(BigInt, BigInt) _sqlDoubleRational(double value) {
  final bytes = ByteData(8)..setFloat64(0, value.abs(), Endian.big);
  final bits = bytes.getUint64(0, Endian.big);
  final exponentBits = (bits >> 52) & 0x7ff;
  final fraction = bits & 0x000fffffffffffff;
  if (exponentBits == 0 && fraction == 0) return (BigInt.zero, BigInt.one);
  final significand = exponentBits == 0 ? fraction : fraction | (1 << 52);
  final binaryExponent =
      (exponentBits == 0 ? 1 - 1023 : exponentBits - 1023) - 52;
  final numerator = BigInt.from(significand);
  return binaryExponent >= 0
      ? (numerator << binaryExponent, BigInt.one)
      : (numerator, BigInt.one << -binaryExponent);
}

int _sqlDecimalExponent(double value) {
  final match = RegExp(
    r'[eE]([+-]?\d+)$',
  ).firstMatch(value.abs().toStringAsExponential());
  return int.tryParse(match?.group(1) ?? '') ?? 0;
}

String _formatSqlText(Object? value) => value == null
    ? ''
    : value is List<int>
    ? utf8.decode(value, allowMalformed: true)
    : value.toString();

String _truncateSqlFormatText(
  String value,
  int? precision, {
  required bool characters,
}) {
  if (precision == null) return value;
  final result = StringBuffer();
  var length = 0;
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    final nextLength = characters ? 1 : utf8.encode(character).length;
    if (length + nextLength > precision) break;
    result.write(character);
    length += nextLength;
  }
  return result.toString();
}

String _padSqlFormat(
  String value,
  int? width,
  bool left,
  bool zero,
  bool characters,
) {
  if (width == null) return value;
  final length = characters ? value.runes.length : utf8.encode(value).length;
  final count = width - length;
  if (count <= 0) return value;
  final spaces = List.filled(count, ' ').join();
  if (left) return '$value$spaces';
  if (!zero) return '$spaces$value';
  var prefix = 0;
  if (value.startsWith('-') || value.startsWith('+') || value.startsWith(' ')) {
    prefix++;
  }
  if (value.startsWith('0x', prefix) || value.startsWith('0X', prefix)) {
    prefix += 2;
  }
  return '${value.substring(0, prefix)}${List.filled(count, '0').join()}${value.substring(prefix)}';
}

String _groupSqlDecimal(String value) {
  final exponentIndex = value.indexOf(RegExp('[eE]'));
  final mantissa = exponentIndex < 0
      ? value
      : value.substring(0, exponentIndex);
  final exponent = exponentIndex < 0 ? '' : value.substring(exponentIndex);
  final point = mantissa.indexOf('.');
  final whole = point < 0 ? mantissa : mantissa.substring(0, point);
  final fraction = point < 0 ? '' : mantissa.substring(point);
  final sign =
      whole.startsWith('-') || whole.startsWith('+') || whole.startsWith(' ')
      ? whole.substring(0, 1)
      : '';
  final digits = whole.substring(sign.length);
  final grouped = StringBuffer(sign);
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) grouped.write(',');
    grouped.write(digits[index]);
  }
  return '${grouped.toString()}$fraction$exponent';
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
    'MOD' => numbers[1] == 0 ? double.nan : numbers[0].remainder(numbers[1]),
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

String _decodeSqlUnistr(String value) {
  final runes = value.runes.toList();
  final output = StringBuffer();
  for (var index = 0; index < runes.length; index++) {
    if (runes[index] != 0x5c || index + 1 == runes.length) {
      output.writeCharCode(runes[index]);
      continue;
    }
    final next = runes[index + 1];
    if (next == 0x5c) {
      output.writeCharCode(0x5c);
      index++;
      continue;
    }
    final digitStart = switch (next) {
      0x2b => index + 2,
      0x75 || 0x55 => index + 2,
      _ => index + 1,
    };
    final digitCount = next == 0x2b
        ? 6
        : next == 0x75
        ? 4
        : next == 0x55
        ? 8
        : 4;
    if (digitStart + digitCount > runes.length) {
      output.writeCharCode(0x5c);
      continue;
    }
    final digits = runes.sublist(digitStart, digitStart + digitCount);
    final hex = String.fromCharCodes(digits);
    final codePoint =
        digits.every(
          (rune) => int.tryParse(String.fromCharCode(rune), radix: 16) != null,
        )
        ? int.tryParse(hex, radix: 16)
        : null;
    if (codePoint == null ||
        codePoint > 0x10ffff ||
        codePoint >= 0xd800 && codePoint <= 0xdfff) {
      output.writeCharCode(0x5c);
      continue;
    }
    output.writeCharCode(codePoint);
    index = digitStart + digitCount - 1;
  }
  return output.toString();
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
  final capturedNow =
      Zone.current[_sqlCurrentTimestampZoneKey] as DateTime? ??
      DateTime.now().toUtc();
  if (values.isEmpty) return capturedNow;
  final value = values.first;
  if (value == null) return null;
  final modifiers = values
      .skip(1)
      .map((value) => value?.toString().toLowerCase())
      .toList();
  final firstModifier = modifiers.isEmpty ? null : modifiers.first;
  late DateTime result;
  try {
    if (value is num) {
      final asUnixEpoch =
          firstModifier == 'unixepoch' ||
          firstModifier == 'auto' && (value < 0 || value >= 5373484.5);
      final milliseconds = asUnixEpoch
          ? (value * 1000).round()
          : ((value - 2440587.5) * 86400000).round();
      result = DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    } else {
      var text = value.toString();
      if (text.toLowerCase() == 'now') {
        result = capturedNow;
      } else {
        if (RegExp(r'^\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$').hasMatch(text)) {
          text = '2000-01-01T$text';
        } else if (text.contains(' ') && !text.contains('T')) {
          text = text.replaceFirst(' ', 'T');
        }
        final parsed = DateTime.tryParse(text);
        if (parsed == null) return null;
        final hasZone = RegExp(
          r'[Tt ].*(?:[Zz]|[+-]\d{2}(?::?\d{2})?)$',
        ).hasMatch(text);
        result = hasZone
            ? parsed.toUtc()
            : DateTime.utc(
                parsed.year,
                parsed.month,
                parsed.day,
                parsed.hour,
                parsed.minute,
                parsed.second,
                parsed.millisecond,
                parsed.microsecond,
              );
      }
    }
  } on RangeError {
    return null;
  }
  if (modifiers.indexed.any(
    (entry) =>
        const {'auto', 'julianday', 'unixepoch'}.contains(entry.$2) &&
        (entry.$1 != 0 || value is! num),
  )) {
    return null;
  }

  DateTime? floorCandidate;
  for (final modifier in modifiers) {
    if (modifier == null) return null;
    if (modifier == 'floor') {
      if (floorCandidate != null) result = floorCandidate;
      floorCandidate = null;
      continue;
    }
    if (modifier == 'ceiling') {
      floorCandidate = null;
      continue;
    }
    floorCandidate = null;
    if (const {
      'unixepoch',
      'julianday',
      'auto',
      'utc',
      'subsec',
      'subsecond',
    }.contains(modifier)) {
      if (modifier == 'utc') result = result.toUtc();
      continue;
    }
    if (modifier == 'localtime') {
      result = result.toLocal();
      continue;
    }
    if (modifier.startsWith('start of ')) {
      final current = result;
      final start = switch (modifier.substring(9)) {
        'day' => _dateTimeInZone(
          current,
          current.year,
          current.month,
          current.day,
        ),
        'month' => _dateTimeInZone(current, current.year, current.month),
        'year' => _dateTimeInZone(current, current.year),
        _ => null,
      };
      if (start == null) return null;
      result = start;
      continue;
    }
    final weekday = RegExp(r'^weekday\s+(\d+)$').firstMatch(modifier);
    if (weekday != null) {
      final day = int.tryParse(weekday.group(1)!);
      if (day == null || day > 6) return null;
      final current = result;
      result = current.add(Duration(days: (day - current.weekday % 7 + 7) % 7));
      continue;
    }
    final shift = RegExp(
      r'^([+-]?\d+(?:\.\d+)?)\s+(seconds?|minutes?|hours?|days?|weeks?|months?|years?)$',
    ).firstMatch(modifier);
    if (shift == null) return null;
    final amount = double.tryParse(shift.group(1)!);
    if (amount == null || !amount.isFinite) return null;
    final unit = shift.group(2)!;
    if (unit.startsWith('month') || unit.startsWith('year')) {
      final months = amount * (unit.startsWith('year') ? 12 : 1);
      if (months != months.roundToDouble()) return null;
      final current = result;
      final targetMonth = _dateTimeInZone(
        current,
        current.year,
        current.month + months.toInt(),
        1,
        current.hour,
        current.minute,
        current.second,
        current.millisecond,
        current.microsecond,
      );
      final lastDay = DateTime(targetMonth.year, targetMonth.month + 1, 0).day;
      result = _dateTimeInZone(
        current,
        targetMonth.year,
        targetMonth.month,
        current.day,
        current.hour,
        current.minute,
        current.second,
        current.millisecond,
        current.microsecond,
      );
      if (current.day > lastDay) {
        floorCandidate = _dateTimeInZone(
          current,
          targetMonth.year,
          targetMonth.month,
          lastDay,
          current.hour,
          current.minute,
          current.second,
          current.millisecond,
          current.microsecond,
        );
      }
      continue;
    }
    final factor = switch (unit) {
      'second' || 'seconds' => 1000.0,
      'minute' || 'minutes' => 60000.0,
      'hour' || 'hours' => 3600000.0,
      'day' || 'days' => 86400000.0,
      'week' || 'weeks' => 604800000.0,
      _ => 0.0,
    };
    try {
      result = result.add(Duration(milliseconds: (amount * factor).round()));
    } on RangeError {
      return null;
    }
  }
  return result;
}

DateTime _dateTimeInZone(
  DateTime reference,
  int year, [
  int month = 1,
  int day = 1,
  int hour = 0,
  int minute = 0,
  int second = 0,
  int millisecond = 0,
  int microsecond = 0,
]) => reference.isUtc
    ? DateTime.utc(
        year,
        month,
        day,
        hour,
        minute,
        second,
        millisecond,
        microsecond,
      )
    : DateTime(
        year,
        month,
        day,
        hour,
        minute,
        second,
        millisecond,
        microsecond,
      );

DateTime? _dateTimeValue(Object? value) {
  if (value is num) {
    final milliseconds = ((value - 2440587.5) * 86400000).round();
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }
  if (value is! String) return null;
  if (value.toLowerCase() == 'now') {
    return Zone.current[_sqlCurrentTimestampZoneKey] as DateTime? ??
        DateTime.now().toUtc();
  }
  final text =
      RegExp(
        r'^\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}(?::?\d{2})?)?$',
        caseSensitive: false,
      ).hasMatch(value)
      ? '2000-01-01T$value'
      : value.contains(' ') && !value.contains('T')
      ? value.replaceFirst(' ', 'T')
      : value;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  if (RegExp(
    r'[Tt].*(?:Z|[+-]\d{2}(?::?\d{2})?)$',
    caseSensitive: false,
  ).hasMatch(text)) {
    return parsed.toUtc();
  }
  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
  );
}

String _formatSqlTimeDifference(DateTime target, DateTime source) {
  final negative = target.isBefore(source);
  final direction = negative ? -1 : 1;
  var months = (target.year - source.year) * 12 + target.month - source.month;
  var shifted = _shiftSqlMonths(source, months);
  while (negative ? shifted.isBefore(target) : shifted.isAfter(target)) {
    months -= direction;
    shifted = _shiftSqlMonths(source, months);
  }
  final remainder =
      target.millisecondsSinceEpoch - shifted.millisecondsSinceEpoch;
  var milliseconds = remainder.abs();
  final days = milliseconds ~/ Duration.millisecondsPerDay;
  milliseconds %= Duration.millisecondsPerDay;
  final hours = milliseconds ~/ Duration.millisecondsPerHour;
  milliseconds %= Duration.millisecondsPerHour;
  final minutes = milliseconds ~/ Duration.millisecondsPerMinute;
  milliseconds %= Duration.millisecondsPerMinute;
  final seconds = milliseconds ~/ Duration.millisecondsPerSecond;
  final fraction = milliseconds % Duration.millisecondsPerSecond;
  final absoluteMonths = months.abs();
  final years = (absoluteMonths ~/ 12).toString().padLeft(4, '0');
  final monthRemainder = (absoluteMonths % 12).toString().padLeft(2, '0');
  final dayText = days.toString().padLeft(2, '0');
  final hourText = hours.toString().padLeft(2, '0');
  final minuteText = minutes.toString().padLeft(2, '0');
  final secondText = seconds.toString().padLeft(2, '0');
  final fractionText = fraction.toString().padLeft(3, '0');
  return '${negative ? '-' : '+'}$years-$monthRemainder-$dayText '
      '$hourText:$minuteText:$secondText.$fractionText';
}

DateTime _shiftSqlMonths(DateTime date, int months) => DateTime.utc(
  date.year,
  date.month + months,
  date.day,
  date.hour,
  date.minute,
  date.second,
  date.millisecond,
);

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
      ':${date.second.toString().padLeft(2, '0')}'
      '${values.skip(1).any((value) => const {'subsec', 'subsecond'}.contains(value?.toString().toLowerCase())) ? '.${date.millisecond.toString().padLeft(3, '0')}' : ''}';
  return switch (name) {
    'DATE' => '$year-$month-$day',
    'TIME' => time,
    _ => '$year-$month-$day $time',
  };
}

String? _formatSqlDate(String format, DateTime date, {bool subsecond = false}) {
  final output = StringBuffer();
  final calendarDate = DateTime.utc(date.year, date.month, date.day);
  final dayOfYear = calendarDate.difference(DateTime.utc(date.year)).inDays + 1;
  final (isoYear, isoWeek) = _isoWeek(date);
  for (var index = 0; index < format.length; index++) {
    final char = format[index];
    if (char != '%') {
      output.write(char);
      continue;
    }
    if (++index >= format.length) return null;
    final hour12 = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final value = switch (format[index]) {
      '%' => '%',
      'F' =>
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      'G' => isoYear.toString().padLeft(4, '0'),
      'g' => (isoYear % 100).toString().padLeft(2, '0'),
      'Y' => date.year.toString().padLeft(4, '0'),
      'm' => date.month.toString().padLeft(2, '0'),
      'd' => date.day.toString().padLeft(2, '0'),
      'e' => date.day.toString().padLeft(2, ' '),
      'H' => date.hour.toString().padLeft(2, '0'),
      'I' => hour12.toString().padLeft(2, '0'),
      'k' => date.hour.toString().padLeft(2, ' '),
      'l' => hour12.toString().padLeft(2, ' '),
      'M' => date.minute.toString().padLeft(2, '0'),
      'p' => date.hour < 12 ? 'AM' : 'PM',
      'P' => date.hour < 12 ? 'am' : 'pm',
      'R' =>
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
      'S' => date.second.toString().padLeft(2, '0'),
      'T' =>
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}',
      'f' =>
        '${date.second.toString().padLeft(2, '0')}.${date.millisecond.toString().padLeft(3, '0')}',
      'j' => dayOfYear.toString().padLeft(3, '0'),
      'u' => date.weekday.toString(),
      'w' => (date.weekday % 7).toString(),
      's' =>
        subsecond
            ? '${date.millisecondsSinceEpoch.isNegative ? '-' : ''}${date.millisecondsSinceEpoch.abs() ~/ 1000}.${(date.millisecondsSinceEpoch.abs() % 1000).toString().padLeft(3, '0')}'
            : (date.millisecondsSinceEpoch ~/ 1000).toString(),
      'J' =>
        (date.millisecondsSinceEpoch / 86400000 + 2440587.5)
            .toStringAsPrecision(16),
      'U' => _weekOfYear(
        date,
        firstWeekday: DateTime.sunday,
      ).toString().padLeft(2, '0'),
      'V' => isoWeek.toString().padLeft(2, '0'),
      'W' => _weekOfYear(
        date,
        firstWeekday: DateTime.monday,
      ).toString().padLeft(2, '0'),
      _ => null,
    };
    if (value == null) return null;
    output.write(value);
  }
  return output.toString();
}

int _weekOfYear(DateTime date, {required int firstWeekday}) {
  final januaryFirst = DateTime.utc(date.year, 1, 1);
  final currentDate = DateTime.utc(date.year, date.month, date.day);
  final firstDay = firstWeekday == DateTime.sunday ? 0 : firstWeekday - 1;
  final januaryFirstWeekday = januaryFirst.weekday % 7;
  final daysUntilFirstWeek = (firstDay - januaryFirstWeekday + 7) % 7;
  final dayOfYear = currentDate.difference(januaryFirst).inDays + 1;
  if (dayOfYear <= daysUntilFirstWeek) return 0;
  return (dayOfYear - daysUntilFirstWeek - 1) ~/ 7 + 1;
}

(int, int) _isoWeek(DateTime date) {
  final calendarDate = DateTime.utc(date.year, date.month, date.day);
  final thursday = calendarDate.add(
    Duration(days: DateTime.thursday - date.weekday),
  );
  final isoYear = thursday.year;
  final januaryFourth = DateTime.utc(isoYear, 1, 4);
  final firstMonday = januaryFourth.subtract(
    Duration(days: januaryFourth.weekday - DateTime.monday),
  );
  final currentMonday = calendarDate.subtract(
    Duration(days: date.weekday - DateTime.monday),
  );
  return (isoYear, currentMonday.difference(firstMonday).inDays ~/ 7 + 1);
}

bool _deterministicIndexExpression(_Expr expression) => switch (expression) {
  _Literal() || _Column() => true,
  _Param() || _ScalarSubquery() || _Exists() || _WindowFunction() => false,
  _Function(:final name, :final arguments, :final distinct, :final filter) =>
    !distinct &&
        filter == null &&
        !const {
          'RANDOM',
          'RANDOMBLOB',
          'CHANGES',
          'LAST_INSERT_ROWID',
          'TOTAL_CHANGES',
          'SQLITE_LOG',
          'SQLITE_OFFSET',
          'SQLITE_VERSION',
          'SQLITE_SOURCE_ID',
          'CURRENT_DATE',
          'CURRENT_TIME',
          'CURRENT_TIMESTAMP',
        }.contains(name.toUpperCase()) &&
        !(const {
              'DATE',
              'TIME',
              'DATETIME',
              'JULIANDAY',
              'UNIXEPOCH',
              'STRFTIME',
              'TIMEDIFF',
            }.contains(name.toUpperCase()) &&
            (arguments.isEmpty ||
                arguments.any(
                  (argument) =>
                      argument is _Literal &&
                      argument.value is String &&
                      const {
                        'now',
                        'localtime',
                        'utc',
                      }.contains((argument.value as String).toLowerCase()),
                ))) &&
        _registeredSqlFunction(name, arguments.length) == null &&
        _registeredSqlAggregateFunction(name, arguments.length) == null &&
        _registeredSqlWindowFunction(name, arguments.length) == null &&
        !_isAggregateFunction(name, arguments.length) &&
        arguments.every(_deterministicIndexExpression),
  _Binary(:final left, :final right) =>
    _deterministicIndexExpression(left) && _deterministicIndexExpression(right),
  _Unary(:final expression) ||
  _Cast(:final expression) => _deterministicIndexExpression(expression),
  _Between(:final expression, :final lower, :final upper) =>
    _deterministicIndexExpression(expression) &&
        _deterministicIndexExpression(lower) &&
        _deterministicIndexExpression(upper),
  _PatternMatch(:final expression, :final pattern, :final escape) =>
    _deterministicIndexExpression(expression) &&
        _deterministicIndexExpression(pattern) &&
        (escape == null || _deterministicIndexExpression(escape)),
  _Case(:final branches, :final otherwise) =>
    branches.every(
          (branch) =>
              _deterministicIndexExpression(branch.$1) &&
              _deterministicIndexExpression(branch.$2),
        ) &&
        (otherwise == null || _deterministicIndexExpression(otherwise)),
  _In(:final expression, :final values, :final query) =>
    query == null &&
        _deterministicIndexExpression(expression) &&
        values.every(_deterministicIndexExpression),
  _RowValue(:final values) => values.every(_deterministicIndexExpression),
};

bool _containsAggregate(_Expr expression) => switch (expression) {
  _Function(:final name, :final arguments, :final filter) =>
    _isAggregateFunction(name, arguments.length) ||
        arguments.any(_containsAggregate) ||
        (filter != null && _containsAggregate(filter)),
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

bool _referencesColumn(_Expr expression, String name) => switch (expression) {
  _Column(name: final reference) =>
    _key(reference.split('.').last) == _key(name),
  _Function(:final arguments, :final filter) =>
    arguments.any((argument) => _referencesColumn(argument, name)) ||
        (filter != null && _referencesColumn(filter, name)),
  _WindowFunction(:final function, :final partitionBy, :final orderBy) =>
    function.arguments.any((argument) => _referencesColumn(argument, name)) ||
        partitionBy.any((value) => _referencesColumn(value, name)) ||
        orderBy.any((value) => _referencesColumn(value.expression, name)),
  _Binary(:final left, :final right) =>
    _referencesColumn(left, name) || _referencesColumn(right, name),
  _In(:final expression, :final values, :final query) =>
    _referencesColumn(expression, name) ||
        values.any((value) => _referencesColumn(value, name)) ||
        (query != null && _selectReferencesColumn(query, name)),
  _ScalarSubquery(:final query) ||
  _Exists(:final query) => _selectReferencesColumn(query, name),
  _RowValue(:final values) => values.any(
    (value) => _referencesColumn(value, name),
  ),
  _Unary(:final expression) ||
  _Cast(:final expression) => _referencesColumn(expression, name),
  _Between(:final expression, :final lower, :final upper) =>
    _referencesColumn(expression, name) ||
        _referencesColumn(lower, name) ||
        _referencesColumn(upper, name),
  _PatternMatch(:final expression, :final pattern, :final escape) =>
    _referencesColumn(expression, name) ||
        _referencesColumn(pattern, name) ||
        (escape != null && _referencesColumn(escape, name)),
  _Case(:final branches, :final otherwise) =>
    branches.any(
          (branch) =>
              _referencesColumn(branch.$1, name) ||
              _referencesColumn(branch.$2, name),
        ) ||
        (otherwise != null && _referencesColumn(otherwise, name)),
  _ => false,
};

bool _selectReferencesColumn(_Select query, String name) =>
    query.items.any((item) => _referencesColumn(item.expression, name)) ||
    query.groupBy.any((expression) => _referencesColumn(expression, name)) ||
    query.where != null && _referencesColumn(query.where!, name) ||
    query.having != null && _referencesColumn(query.having!, name) ||
    query.orderBy.any((order) => _referencesColumn(order.expression, name)) ||
    query.limit != null && _referencesColumn(query.limit!, name) ||
    query.offset != null && _referencesColumn(query.offset!, name) ||
    query.joins.any(
      (join) =>
          join.natural ||
          join.usingColumns.any((column) => _key(column) == _key(name)) ||
          join.on != null && _referencesColumn(join.on!, name) ||
          join.query != null && _selectReferencesColumn(join.query!, name),
    ) ||
    query.fromQuery != null &&
        _selectReferencesColumn(query.fromQuery!, name) ||
    query.compoundTerms.any(
      (term) => _selectReferencesColumn(term.query, name),
    );

bool _constantRangeOffset(_Expr expression) => switch (expression) {
  _Literal(:final value) => value is num,
  _Param() => true,
  _Unary(:final operator, :final expression) =>
    const {'+', '-'}.contains(operator) && _constantRangeOffset(expression),
  _Binary(:final left, :final operator, :final right) =>
    const {'+', '-', '*', '/', '%'}.contains(operator) &&
        _constantRangeOffset(left) &&
        _constantRangeOffset(right),
  _Cast(:final expression) => _constantRangeOffset(expression),
  _ => false,
};

bool _isAggregateFunction(String name, int argumentCount) =>
    switch (name.toUpperCase()) {
      'COUNT' ||
      'SUM' ||
      'AVG' ||
      'TOTAL' ||
      'GROUP_CONCAT' ||
      'STRING_AGG' ||
      'JSON_GROUP_ARRAY' ||
      'JSON_GROUP_OBJECT' ||
      'JSONB_GROUP_ARRAY' ||
      'JSONB_GROUP_OBJECT' ||
      'MEDIAN' ||
      'PERCENTILE' ||
      'PERCENTILE_CONT' ||
      'PERCENTILE_DISC' => true,
      'MIN' || 'MAX' => argumentCount == 1,
      _ => _registeredSqlAggregateFunction(name, argumentCount) != null,
    };

Set<_WindowFunction> _windowFunctions(_Expr expression) => switch (expression) {
  _WindowFunction(:final function) => {
    expression,
    for (final argument in function.arguments) ..._windowFunctions(argument),
  },
  _Function(:final arguments, :final filter) => {
    for (final argument in arguments) ..._windowFunctions(argument),
    if (filter != null) ..._windowFunctions(filter),
  },
  _Binary(:final left, :final right) => {
    ..._windowFunctions(left),
    ..._windowFunctions(right),
  },
  _In(:final expression, :final values) => {
    ..._windowFunctions(expression),
    for (final value in values) ..._windowFunctions(value),
  },
  _RowValue(:final values) => {
    for (final value in values) ..._windowFunctions(value),
  },
  _Unary(:final expression) ||
  _Cast(:final expression) => _windowFunctions(expression),
  _Between(:final expression, :final lower, :final upper) => {
    ..._windowFunctions(expression),
    ..._windowFunctions(lower),
    ..._windowFunctions(upper),
  },
  _PatternMatch(:final expression, :final pattern, :final escape) => {
    ..._windowFunctions(expression),
    ..._windowFunctions(pattern),
    if (escape != null) ..._windowFunctions(escape),
  },
  _Case(:final branches, :final otherwise) => {
    for (final branch in branches) ..._windowFunctions(branch.$1),
    for (final branch in branches) ..._windowFunctions(branch.$2),
    if (otherwise != null) ..._windowFunctions(otherwise),
  },
  _ => {},
};

void _evaluateWindowFunction(
  _WindowFunction window,
  List<SqlRow> rows,
  List<Object?> parameters,
  Object? Function(_Expr, SqlRow, List<Object?>) evaluate,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>) selectSubquery, {
  Object? Function(_Function, List<SqlRow>, SqlRow, List<Object?>)?
  evaluateAggregate,
}) {
  final function = window.function;
  final name = function.name.toUpperCase();
  const builtins = {
    'ROW_NUMBER',
    'RANK',
    'DENSE_RANK',
    'PERCENT_RANK',
    'CUME_DIST',
    'NTILE',
    'LAG',
    'LEAD',
    'FIRST_VALUE',
    'LAST_VALUE',
    'NTH_VALUE',
  };
  final aggregate = _isAggregateFunction(name, function.arguments.length);
  final windowFunction = _registeredSqlWindowFunction(
    name,
    function.arguments.length,
  );
  final customAggregate =
      _registeredSqlAggregateFunction(name, function.arguments.length) != null;
  if (!builtins.contains(name) && !aggregate && windowFunction == null) {
    throw PureSqlException('unsupported window function: ${function.name}');
  }
  if (function.filter != null && !aggregate) {
    throw PureSqlException('FILTER may only be used with aggregate functions');
  }
  if (function.filter != null &&
      (_containsAggregate(function.filter!) ||
          _windowFunctions(function.filter!).isNotEmpty)) {
    throw PureSqlException('aggregate FILTER cannot contain aggregates');
  }
  final argumentCount = function.arguments.length;
  if (windowFunction == null &&
      aggregate &&
      !customAggregate &&
      (name == 'GROUP_CONCAT'
          ? argumentCount < 1 || argumentCount > 2
          : name == 'STRING_AGG'
          ? argumentCount != 2
          : name == 'MEDIAN'
          ? argumentCount != 1
          : name == 'JSON_GROUP_ARRAY' || name == 'JSONB_GROUP_ARRAY'
          ? argumentCount != 1
          : name == 'JSON_GROUP_OBJECT' || name == 'JSONB_GROUP_OBJECT'
          ? argumentCount != 2
          : const {
              'PERCENTILE',
              'PERCENTILE_CONT',
              'PERCENTILE_DISC',
            }.contains(name)
          ? argumentCount != 2
          : argumentCount != 1)) {
    throw PureSqlException('${function.name} has an invalid argument count');
  }
  if (windowFunction == null &&
      (const {
                'ROW_NUMBER',
                'RANK',
                'DENSE_RANK',
                'PERCENT_RANK',
                'CUME_DIST',
              }.contains(name) &&
              argumentCount != 0 ||
          name == 'NTILE' && argumentCount != 1 ||
          const {'LAG', 'LEAD'}.contains(name) &&
              (argumentCount < 1 || argumentCount > 3) ||
          const {'FIRST_VALUE', 'LAST_VALUE'}.contains(name) &&
              argumentCount != 1 ||
          name == 'NTH_VALUE' && argumentCount != 2)) {
    throw PureSqlException('${function.name} has an invalid argument count');
  }
  if (function.arguments.any(
        (argument) => _windowFunctions(argument).isNotEmpty,
      ) ||
      window.partitionBy.any(
        (expression) => _windowFunctions(expression).isNotEmpty,
      ) ||
      window.orderBy.any(
        (order) => _windowFunctions(order.expression).isNotEmpty,
      )) {
    throw PureSqlException('nested window functions are not supported');
  }

  final partitions = <List<SqlRow>>[];
  for (final row in rows) {
    final values = [
      for (final expression in window.partitionBy)
        evaluate(expression, row, parameters),
    ];
    List<SqlRow>? partition;
    for (final candidate in partitions) {
      if (window.partitionBy.indexed.every(
        (entry) => _equal(
          evaluate(entry.$2, candidate.first, parameters),
          values[entry.$1],
        ),
      )) {
        partition = candidate;
        break;
      }
    }
    if (partition == null) {
      partitions.add([row]);
    } else {
      partition.add(row);
    }
  }

  bool peers(SqlRow left, SqlRow right) => window.orderBy.every((order) {
    final comparison = _compare(
      evaluate(order.expression, left, parameters),
      evaluate(order.expression, right, parameters),
      noCase: order.noCase,
    );
    return comparison == 0;
  });

  for (final partition in partitions) {
    final ordered = List<SqlRow>.from(partition);
    ordered.sort((left, right) {
      for (final order in window.orderBy) {
        final comparison = _compareOrderValues(
          evaluate(order.expression, left, parameters),
          evaluate(order.expression, right, parameters),
          order,
        );
        if (comparison != 0) return comparison;
      }
      return 0;
    });
    final partitionArguments = windowFunction == null
        ? null
        : List<List<Object?>>.unmodifiable([
            for (final row in ordered)
              List<Object?>.unmodifiable([
                for (final argument in function.arguments)
                  evaluate(argument, row, parameters),
              ]),
          ]);
    final rangeValues =
        window.frame?.type == 'RANGE' && window.orderBy.length == 1
        ? [
            for (final row in ordered)
              evaluate(window.orderBy.single.expression, row, parameters),
          ]
        : const <Object?>[];
    final ranks = List<int>.filled(ordered.length, 1);
    final denseRanks = List<int>.filled(ordered.length, 1);
    final peerEnds = List<int>.filled(ordered.length, 0);
    final peerGroupStarts = <int>[0];
    final peerGroupEnds = <int>[];
    var groupStart = 0;
    var denseRank = 1;
    for (var index = 1; index < ordered.length; index++) {
      if (peers(ordered[index - 1], ordered[index])) {
        ranks[index] = ranks[index - 1];
        denseRanks[index] = denseRanks[index - 1];
        continue;
      }
      for (var peer = groupStart; peer < index; peer++) {
        peerEnds[peer] = index - 1;
      }
      peerGroupEnds.add(index - 1);
      peerGroupStarts.add(index);
      groupStart = index;
      denseRank++;
      ranks[index] = index + 1;
      denseRanks[index] = denseRank;
    }
    for (var peer = groupStart; peer < ordered.length; peer++) {
      peerEnds[peer] = ordered.length - 1;
    }
    if (ordered.isNotEmpty) peerGroupEnds.add(ordered.length - 1);

    for (var index = 0; index < ordered.length; index++) {
      final row = ordered[index];
      final (frameStart, frameEnd) = _windowFrameRange(
        window.frame,
        index,
        peerEnds[index],
        ordered.length,
        row,
        parameters,
        evaluate,
        denseRanks[index] - 1,
        peerGroupStarts,
        peerGroupEnds,
        window.orderBy,
        rangeValues,
      );
      final exclusion = window.frame?.exclude ?? 'noOthers';
      final frameRows = <SqlRow>[
        for (var frameIndex = frameStart; frameIndex <= frameEnd; frameIndex++)
          if (switch (exclusion) {
            'currentRow' => frameIndex != index,
            'group' => !peers(ordered[frameIndex], row),
            'ties' => frameIndex == index || !peers(ordered[frameIndex], row),
            _ => true,
          })
            ordered[frameIndex],
      ];
      final aggregateRows = function.filter == null
          ? frameRows
          : [
              for (final frameRow in frameRows)
                if (_truthy(evaluate(function.filter!, frameRow, parameters)))
                  frameRow,
            ];
      final value = switch (name) {
        _ when windowFunction != null => _normalizeSqlFunctionResult(
          windowFunction(
            partitionArguments!,
            index,
            List<List<Object?>>.unmodifiable([
              for (final frameRow in frameRows)
                List<Object?>.unmodifiable([
                  for (final argument in function.arguments)
                    evaluate(argument, frameRow, parameters),
                ]),
            ]),
          ),
        ),
        'ROW_NUMBER' => index + 1,
        'RANK' => ranks[index],
        'DENSE_RANK' => denseRanks[index],
        'PERCENT_RANK' =>
          ordered.length == 1 ? 0.0 : (ranks[index] - 1) / (ordered.length - 1),
        'CUME_DIST' => (peerEnds[index] + 1) / ordered.length,
        'NTILE' => _windowNtile(
          function,
          row,
          index,
          ordered.length,
          parameters,
          evaluate,
        ),
        'LAG' => _windowOffset(
          function,
          ordered,
          index,
          -1,
          parameters,
          evaluate,
        ),
        'LEAD' => _windowOffset(
          function,
          ordered,
          index,
          1,
          parameters,
          evaluate,
        ),
        'FIRST_VALUE' =>
          function.arguments.length != 1
              ? throw PureSqlException('FIRST_VALUE expects one argument')
              : frameRows.isEmpty
              ? null
              : evaluate(
                  function.arguments.single,
                  frameRows.first,
                  parameters,
                ),
        'LAST_VALUE' =>
          function.arguments.length != 1
              ? throw PureSqlException('LAST_VALUE expects one argument')
              : frameRows.isEmpty
              ? null
              : evaluate(function.arguments.single, frameRows.last, parameters),
        'NTH_VALUE' => _windowNthValue(
          function,
          row,
          frameRows,
          parameters,
          evaluate,
        ),
        _ when aggregate =>
          evaluateAggregate == null
              ? _evalGroup(
                  function,
                  aggregateRows,
                  row,
                  parameters,
                  selectSubquery: selectSubquery,
                )
              : evaluateAggregate(function, aggregateRows, row, parameters),
        _ => throw PureSqlException(
          'unsupported window function: ${function.name}',
        ),
      };
      row['@window:${window.id}'] = value;
    }
  }
}

(int, int) _windowFrameRange(
  _WindowFrame? frame,
  int index,
  int peerEnd,
  int rowCount,
  SqlRow row,
  List<Object?> parameters,
  Object? Function(_Expr, SqlRow, List<Object?>) evaluate,
  int peerGroupIndex,
  List<int> peerGroupStarts,
  List<int> peerGroupEnds,
  List<_Order> orderBy,
  List<Object?> rangeValues,
) {
  if (frame == null) return (0, peerEnd);
  final isGroups = frame.type == 'GROUPS';
  final isRange = frame.type == 'RANGE';
  final groupCount = peerGroupStarts.length;

  int rowOrGroupBoundary(_WindowFrameBound bound) {
    final offset = bound.offset == null
        ? 0
        : _asInt(evaluate(bound.offset!, row, parameters));
    if (offset < 0)
      throw PureSqlException('window frame offset must not be negative');
    final base = isGroups ? peerGroupIndex : index;
    return switch (bound.kind) {
      'unboundedPreceding' => 0,
      'preceding' => base - offset,
      'current' => base,
      'following' => base + offset,
      'unboundedFollowing' => (isGroups ? groupCount : rowCount) - 1,
      _ => throw PureSqlException('invalid window frame boundary'),
    };
  }

  int rangeBoundary(_WindowFrameBound bound, {required bool start}) {
    if (bound.kind == 'unboundedPreceding') return 0;
    if (bound.kind == 'unboundedFollowing') return rowCount - 1;
    if (bound.kind == 'current') {
      return start
          ? peerGroupStarts[peerGroupIndex]
          : peerGroupEnds[peerGroupIndex];
    }
    if (orderBy.length != 1 || bound.offset == null) {
      throw PureSqlException(
        'RANGE offsets require exactly one ORDER BY expression',
      );
    }
    final current = rangeValues[index];
    final rawOffset = evaluate(bound.offset!, row, parameters);
    if (rawOffset is! num || !rawOffset.isFinite || rawOffset < 0) {
      throw PureSqlException('RANGE offset must be a non-negative number');
    }
    if (current is! num) {
      return start
          ? peerGroupStarts[peerGroupIndex]
          : peerGroupEnds[peerGroupIndex];
    }
    final descending = orderBy.single.descending;
    final before = bound.kind == 'preceding';
    final threshold = switch ((descending, before)) {
      (false, true) => current - rawOffset,
      (false, false) => current + rawOffset,
      (true, true) => current + rawOffset,
      (true, false) => current - rawOffset,
    };
    bool beyondBoundary(int position) {
      final value = rangeValues[position];
      if (value is! num) return _equal(value, current);
      if (start) return descending ? value <= threshold : value >= threshold;
      return descending ? value >= threshold : value <= threshold;
    }

    if (start) {
      for (var position = 0; position < rowCount; position++) {
        if (beyondBoundary(position)) return position;
      }
      return rowCount;
    }
    var end = -1;
    for (var position = 0; position < rowCount; position++) {
      if (beyondBoundary(position)) end = position;
    }
    return end;
  }

  if (isRange) {
    return (
      rangeBoundary(frame.start, start: true).clamp(0, rowCount).toInt(),
      rangeBoundary(frame.end, start: false).clamp(-1, rowCount - 1).toInt(),
    );
  }
  final unitCount = isGroups ? groupCount : rowCount;
  final start = rowOrGroupBoundary(frame.start).clamp(0, unitCount).toInt();
  final end = rowOrGroupBoundary(frame.end).clamp(-1, unitCount - 1).toInt();
  if (isGroups) {
    return (
      start == groupCount ? rowCount : peerGroupStarts[start],
      end < 0 ? -1 : peerGroupEnds[end],
    );
  }
  return (start, end);
}

Object? _windowOffset(
  _Function function,
  List<SqlRow> ordered,
  int index,
  int direction,
  List<Object?> parameters,
  Object? Function(_Expr, SqlRow, List<Object?>) evaluate,
) {
  if (function.arguments.isEmpty || function.arguments.length > 3) {
    throw PureSqlException('${function.name} expects one to three arguments');
  }
  final offset = function.arguments.length < 2
      ? 1
      : _asInt(evaluate(function.arguments[1], ordered[index], parameters));
  if (offset < 0) throw PureSqlException('window offset must not be negative');
  final target = index + direction * offset;
  if (target >= 0 && target < ordered.length) {
    return evaluate(function.arguments.first, ordered[target], parameters);
  }
  return function.arguments.length == 3
      ? evaluate(function.arguments[2], ordered[index], parameters)
      : null;
}

Object? _windowNthValue(
  _Function function,
  SqlRow currentRow,
  List<SqlRow> frameRows,
  List<Object?> parameters,
  Object? Function(_Expr, SqlRow, List<Object?>) evaluate,
) {
  if (function.arguments.length != 2) {
    throw PureSqlException('NTH_VALUE expects two arguments');
  }
  final nth = _asInt(evaluate(function.arguments[1], currentRow, parameters));
  if (nth < 1) throw PureSqlException('NTH_VALUE index must be positive');
  return nth <= frameRows.length
      ? evaluate(function.arguments.first, frameRows[nth - 1], parameters)
      : null;
}

int _windowNtile(
  _Function function,
  SqlRow row,
  int index,
  int rowCount,
  List<Object?> parameters,
  Object? Function(_Expr, SqlRow, List<Object?>) evaluate,
) {
  if (function.arguments.length != 1) {
    throw PureSqlException('NTILE expects one argument');
  }
  final buckets = _asInt(evaluate(function.arguments.single, row, parameters));
  if (buckets < 1) throw PureSqlException('NTILE argument must be positive');
  final baseSize = rowCount ~/ buckets;
  final largerBuckets = rowCount % buckets;
  if (baseSize == 0) return index + 1;
  final largerRows = (baseSize + 1) * largerBuckets;
  return index < largerRows
      ? index ~/ (baseSize + 1) + 1
      : largerBuckets + (index - largerRows) ~/ baseSize + 1;
}

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

  if (expression is _Function && expression.filter != null) {
    final filter = expression.filter!;
    if (!_isAggregateFunction(expression.name, expression.arguments.length)) {
      throw PureSqlException(
        'FILTER may only be used with aggregate functions',
      );
    }
    if (_containsAggregate(filter) || _windowFunctions(filter).isNotEmpty) {
      throw PureSqlException('aggregate FILTER cannot contain aggregates');
    }
    return _evalGroupWithSubqueries(
      _Function(
        expression.name,
        expression.arguments,
        distinct: expression.distinct,
      ),
      [
        for (final inputRow in group)
          if (_truthy(
            _eval(filter, inputRow, parameters, selectSubquery: selectSubquery),
          ))
            inputRow,
      ],
      row,
      parameters,
      selectSubquery,
    );
  }

  if (expression case _Function(:final name, :final arguments)
      when name.toUpperCase() == 'SUBTYPE' &&
          _registeredSqlFunction(name, arguments.length) == null) {
    if (arguments.length != 1) {
      throw PureSqlException('subtype expects one argument');
    }
    return _evalExpressionWithSubtype(arguments.single, evaluate).subtype;
  }

  if (expression case _Function(
    :final name,
    :final arguments,
    :final distinct,
  )) {
    final aggregate = _registeredSqlAggregateFunction(name, arguments.length);
    if (aggregate != null) {
      if (distinct && arguments.length != 1) {
        throw PureSqlException('DISTINCT aggregates must have one argument');
      }
      if (arguments.any(
        (argument) => argument is _Column && argument.name == '*',
      )) {
        throw PureSqlException('only COUNT may use *');
      }
      final values = <List<Object?>>[];
      for (final inputRow in group) {
        final rowValues = [
          for (final argument in arguments)
            _eval(
              argument,
              inputRow,
              parameters,
              selectSubquery: selectSubquery,
            ),
        ];
        if (rowValues.any((value) => value is _SqlRowValue)) {
          throw PureSqlException('row value misused');
        }
        if (distinct &&
            values.any(
              (previous) => _equal(previous.single, rowValues.single),
            )) {
          continue;
        }
        values.add(rowValues);
      }
      return _normalizeSqlFunctionResult(
        aggregate(
          List<List<Object?>>.unmodifiable([
            for (final value in values) List<Object?>.unmodifiable(value),
          ]),
        ),
      );
    }
  }

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
        when const {
          'JSON_GROUP_ARRAY',
          'JSON_GROUP_OBJECT',
          'JSONB_GROUP_ARRAY',
          'JSONB_GROUP_OBJECT',
        }.contains(name.toUpperCase()) =>
      _jsonAggregateGroup(
        name,
        arguments,
        group,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
      ),
    _Function(:final name, :final arguments, :final distinct)
        when const {
          'MEDIAN',
          'PERCENTILE',
          'PERCENTILE_CONT',
          'PERCENTILE_DISC',
        }.contains(name.toUpperCase()) =>
      _percentileGroup(
        name,
        arguments,
        group,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
      ),
    _Function(:final name, :final arguments, :final distinct)
        when name.toUpperCase() == 'GROUP_CONCAT' ||
            name.toUpperCase() == 'STRING_AGG' =>
      _groupConcat(
        arguments,
        group,
        row,
        parameters,
        distinct: distinct,
        selectSubquery: selectSubquery,
        functionName: name.toLowerCase(),
        minimumArguments: name.toUpperCase() == 'STRING_AGG' ? 2 : 1,
      ),
    _Function(:final name, :final arguments)
        when (name.toUpperCase() == 'IIF' || name.toUpperCase() == 'IF') &&
            _registeredSqlFunction(name, arguments.length) == null =>
      _evaluateIif(name, arguments, evaluate),
    _Function(:final name, :final arguments) => _applySqlFunction(
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

Object? _jsonAggregateGroup(
  String functionName,
  List<_Expr> arguments,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  final name = functionName.toUpperCase();
  final array = name.endsWith('_ARRAY');
  if (arguments.length != (array ? 1 : 2)) {
    throw PureSqlException('$functionName has an invalid argument count');
  }
  if (distinct && !array) {
    throw PureSqlException('DISTINCT aggregates must have one argument');
  }
  final values = <Object?>[];
  final seen = <Object?>[];
  final members = <String>[];
  for (final row in group) {
    final keyOrValue = _eval(
      arguments.first,
      row,
      parameters,
      selectSubquery: selectSubquery,
    );
    if (!array && keyOrValue == null) continue;
    if (distinct && seen.any((value) => _equal(value, keyOrValue))) continue;
    if (distinct) seen.add(keyOrValue);
    if (array) {
      values.add(_jsonSqlValue(keyOrValue));
    } else {
      final value = _eval(
        arguments[1],
        row,
        parameters,
        selectSubquery: selectSubquery,
      );
      members.add(
        '${jsonEncode(keyOrValue.toString())}:${_encodeSqlJson(_jsonSqlValue(value))}',
      );
    }
  }
  final result = array ? _encodeSqlJson(values) : '{${members.join(',')}}';
  return name.startsWith('JSONB_')
      ? _encodeSqlJsonb(_decodeSqlJson(result))
      : result;
}

Object? _percentileGroup(
  String functionName,
  List<_Expr> arguments,
  List<SqlRow> group,
  List<Object?> parameters, {
  required bool distinct,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  final name = functionName.toUpperCase();
  final median = name == 'MEDIAN';
  if (arguments.length != (median ? 1 : 2)) {
    throw PureSqlException('$functionName has an invalid argument count');
  }
  if (distinct) {
    throw PureSqlException('DISTINCT aggregates must have one argument');
  }
  if (group.isEmpty) return null;

  final values = <num>[];
  double? percentile;
  for (final row in group) {
    final rawPercentile = median
        ? 0.5
        : _eval(arguments[1], row, parameters, selectSubquery: selectSubquery);
    if (rawPercentile is! num || !rawPercentile.isFinite) {
      throw PureSqlException('percentile parameter must be numeric');
    }
    final scale = name == 'PERCENTILE' ? 100.0 : 1.0;
    final fraction = rawPercentile.toDouble() / scale;
    if (fraction < 0 || fraction > 1) {
      throw PureSqlException('percentile parameter is out of range');
    }
    if (percentile != null && (fraction - percentile).abs() >= 0.001) {
      throw PureSqlException('percentile parameter must be the same');
    }
    percentile ??= fraction;

    final value = _eval(
      arguments.first,
      row,
      parameters,
      selectSubquery: selectSubquery,
    );
    if (value == null) continue;
    if (value is! num || !value.isFinite) {
      throw PureSqlException('percentile input must be numeric');
    }
    values.add(value);
  }
  if (values.isEmpty) return null;
  values.sort((left, right) => left.compareTo(right));
  final position = percentile! * (values.length - 1);
  final lowerIndex = position.floor();
  if (name == 'PERCENTILE_DISC') return values[lowerIndex];
  final upperIndex = position.ceil();
  final lower = values[lowerIndex].toDouble();
  if (upperIndex == lowerIndex) return lower;
  return lower +
      (position - lowerIndex) * (values[upperIndex].toDouble() - lower);
}

Object? _groupConcat(
  List<_Expr> arguments,
  List<SqlRow> group,
  SqlRow row,
  List<Object?> parameters, {
  required bool distinct,
  String functionName = 'group_concat',
  int minimumArguments = 1,
  List<SqlRow> Function(_Select, SqlRow, List<Object?>)? selectSubquery,
}) {
  if (arguments.length < minimumArguments || arguments.length > 2) {
    throw PureSqlException(
      '$functionName expects ${minimumArguments == 2 ? 'two' : 'one or two'} arguments',
    );
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

int? _readSqliteOffset({required SqlRow row, required String name}) =>
    row['@@sqlite_offset:${_key(name)}'] as int?;

Object? _binary(
  String operator,
  Object? left,
  Object? right, {
  bool noCase = false,
}) {
  if (left is _SqlRowValue || right is _SqlRowValue) {
    return _binaryRow(operator, left, right, noCase: noCase);
  }
  if (operator == '->' || operator == '->>') {
    if (left == null || right == null) return null;
    final path = right is String
        ? right.startsWith(r'$')
              ? right
              : r'$.' + jsonEncode(right)
        : right is int
        ? right < 0
              ? r'$[#' + right.toInt().toString() + ']'
              : r'$[' + right.toInt().toString() + ']'
        : r'$.' + jsonEncode(right.toString());
    final value = _jsonPathValue(_decodeSqlJson(left), path);
    if (value == _missingJsonPath) return null;
    if (operator == '->') return _encodeSqlJson(value);
    if (value is Map || value is List) return _encodeSqlJson(value);
    return _jsonSqlValue(value);
  }
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

Object? _binaryRow(
  String operator,
  Object? left,
  Object? right, {
  required bool noCase,
}) {
  if (left is! _SqlRowValue || right is! _SqlRowValue) {
    throw PureSqlException('row value misused');
  }
  if (left.values.length != right.values.length) {
    throw PureSqlException('row value has mismatched column count');
  }
  if (left.values.any((item) => item is _SqlRowValue) ||
      right.values.any((item) => item is _SqlRowValue)) {
    throw PureSqlException('nested row value misused');
  }
  if (operator == 'IS' || operator == 'IS NOT') {
    final equal = List.generate(left.values.length, (index) {
      final a = left.values[index];
      final b = right.values[index];
      if (a == null || b == null) return a == null && b == null;
      return _compare(a, b, noCase: noCase) == 0;
    }).every((same) => same);
    return operator == 'IS' ? equal : !equal;
  }
  if (operator == '=' || operator == '!=' || operator == '<>') {
    var unknown = false;
    for (var index = 0; index < left.values.length; index++) {
      final a = left.values[index];
      final b = right.values[index];
      if (a == null || b == null) {
        unknown = true;
      } else if (_compare(a, b, noCase: noCase) != 0) {
        final equal = false;
        return operator == '=' ? equal : !equal;
      }
    }
    final equal = unknown ? null : true;
    if (operator == '=') return equal;
    return equal == null ? null : !equal;
  }
  for (var index = 0; index < left.values.length; index++) {
    final a = left.values[index];
    final b = right.values[index];
    if (a == null || b == null) return null;
    final comparison = _compare(a, b, noCase: noCase);
    if (comparison == 0) continue;
    return switch (operator) {
      '<' => comparison < 0,
      '<=' => comparison < 0,
      '>' => comparison > 0,
      '>=' => comparison > 0,
      _ => throw PureSqlException('row value misused'),
    };
  }
  return switch (operator) {
    '<' => false,
    '<=' => true,
    '>' => false,
    '>=' => true,
    _ => throw PureSqlException('row value misused'),
  };
}

bool _truthy(Object? value) {
  if (value is _SqlRowValue) throw PureSqlException('row value misused');
  return value is bool ? value : value != null && value != 0 && value != '';
}

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

int _compareOrderValues(Object? left, Object? right, _Order order) {
  if (left == null || right == null) {
    if (left == right) return 0;
    final nullsFirst = order.nullsFirst ?? !order.descending;
    return (left == null) == nullsFirst ? -1 : 1;
  }
  final comparison = _compare(left, right, noCase: order.noCase);
  return order.descending ? -comparison : comparison;
}

bool _like(
  String value,
  String pattern, {
  String? escape,
  bool caseSensitive = false,
}) {
  if (!caseSensitive) {
    value = _sqliteNoCase(value);
    pattern = _sqliteNoCase(pattern);
    escape = escape == null ? null : _sqliteNoCase(escape);
  }
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

int? _secureDeleteInput(Object? value) {
  if (value is bool) return value ? 1 : 0;
  if (value is num) return value == 0 ? 0 : 1;
  if (value is! String) return null;
  return switch (value.toUpperCase()) {
    'FAST' => 2,
    'ON' || 'YES' || 'TRUE' => 1,
    'OFF' || 'NO' || 'FALSE' => 0,
    _ => switch (double.tryParse(value)) {
      null => null,
      0 => 0,
      _ => 1,
    },
  };
}

int _asInt(Object? value) {
  if (value is int) return value;
  throw PureSqlException('expected integer, got $value');
}

int _sqliteLogCode(Object? value) {
  final number = switch (value) {
    null => 0,
    bool value => value ? 1 : 0,
    int value => value,
    num value => value.isFinite ? value.toInt() : 0,
    String value => double.tryParse(value.trim())?.toInt() ?? 0,
    _ => 0,
  };
  return number.clamp(-0x80000000, 0x7fffffff);
}

String? _sqliteLogMessage(Object? value) => switch (value) {
  null => null,
  List<int> bytes => utf8.decode(bytes, allowMalformed: true),
  _ => value.toString(),
};

const _base85Alphabet =
    r'#$%&*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz';

Object? _applyBase64(List<Object?> values) {
  _requireArity('base64', values, 1);
  final value = values.single;
  if (value == null) return null;
  if (value is List<int>) {
    final encoded = base64.encode(value);
    if (encoded.isEmpty) return '';
    final output = StringBuffer();
    for (var offset = 0; offset < encoded.length; offset += 72) {
      final end = math.min(offset + 72, encoded.length);
      output.write(encoded.substring(offset, end));
      if (end < encoded.length && end - offset == 72) output.write('\n');
    }
    output.write('\n');
    return output.toString();
  }
  if (value is! String) {
    throw PureSqlException('base64 expects TEXT, BLOB, or NULL');
  }
  final prefix = StringBuffer();
  for (final rune in value.trim().runes) {
    if (rune == 10 || rune == 13) continue;
    final valid =
        rune >= 65 && rune <= 90 ||
        rune >= 97 && rune <= 122 ||
        rune >= 48 && rune <= 57 ||
        rune == 43 ||
        rune == 47;
    if (valid) {
      prefix.writeCharCode(rune);
    } else if (rune == 61) {
      break;
    } else {
      break;
    }
  }
  var payload = prefix.toString();
  if (payload.length % 4 == 1) {
    payload = payload.substring(0, payload.length - 1);
  }
  if (payload.isNotEmpty) {
    payload += switch (payload.length % 4) {
      2 => '==',
      3 => '=',
      _ => '',
    };
  }
  try {
    return base64.decode(payload);
  } on FormatException {
    return <int>[];
  }
}

Object? _applyBase85(List<Object?> values) {
  _requireArity('base85', values, 1);
  final value = values.single;
  if (value is List<int>) {
    if (value.isEmpty) return '';
    final encoded = StringBuffer();
    for (var offset = 0; offset < value.length; offset += 4) {
      final size = math.min(4, value.length - offset);
      var number = 0;
      for (var index = 0; index < size; index++) {
        number = (number << 8) | (value[offset + index] & 0xff);
      }
      final digits = List<int>.filled(size + 1, 0);
      for (var index = digits.length - 1; index >= 0; index--) {
        digits[index] = number % 85;
        number ~/= 85;
      }
      for (final digit in digits) {
        encoded.write(_base85Alphabet[digit]);
      }
    }
    final raw = encoded.toString();
    final output = StringBuffer();
    for (var offset = 0; offset < raw.length; offset += 80) {
      final end = math.min(offset + 80, raw.length);
      output.write(raw.substring(offset, end));
      if (end < raw.length && end - offset == 80) output.write('\n');
    }
    output.write('\n');
    return output.toString();
  }
  if (value is! String) {
    throw PureSqlException('base85 expects TEXT or BLOB');
  }
  final bytes = <int>[];
  var run = <int>[];
  void decodeRun() {
    var offset = 0;
    while (offset + 5 <= run.length) {
      var number = 0;
      for (final digit in run.skip(offset).take(5)) {
        number = number * 85 + digit;
      }
      number &= 0xffffffff;
      for (var shift = 24; shift >= 0; shift -= 8) {
        bytes.add((number >> shift) & 0xff);
      }
      offset += 5;
    }
    final remaining = run.length - offset;
    if (remaining >= 2) {
      var number = 0;
      for (final digit in run.skip(offset)) {
        number = number * 85 + digit;
      }
      final size = remaining - 1;
      for (var shift = (size - 1) * 8; shift >= 0; shift -= 8) {
        bytes.add((number >> shift) & 0xff);
      }
    }
    run = [];
  }

  for (final rune in value.runes) {
    final digit = rune < 128
        ? _base85Alphabet.indexOf(String.fromCharCode(rune))
        : -1;
    if (digit < 0) {
      decodeRun();
    } else {
      run.add(digit);
    }
  }
  decodeRun();
  return bytes;
}

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
    this.virtualTable,
    this.schemaSql,
    this.isSequenceTable = false,
    this.isTemporary = false,
    this.primaryKeyColumns = const [],
    this.checkExpressions = const [],
    this.uniqueConstraints = const [],
    this.foreignKeyConstraints = const [],
  });

  String name;
  final List<_ColumnDef> columns;
  int? rootPage;
  final SqlVirtualTable? virtualTable;
  final bool isSequenceTable;
  bool isTemporary;
  List<String> primaryKeyColumns;
  List<_Expr> checkExpressions;
  List<List<String>> uniqueConstraints;
  List<_ForeignKey> foreignKeyConstraints;
  String? schemaSql;
  final List<SqlRow> rows = [];
  final List<int> rowIds = [];
  final Map<int, int> recordOffsets = {};
  final List<_Index> indexes = [];
  int nextRowId = 1;

  bool get autoIncrement => columns.any((column) => column.autoIncrement);

  bool isRowIdAlias(String name) {
    final key = _key(name);
    return const {'rowid', '_rowid_', 'oid'}.contains(key) &&
        !columns.any((column) => _key(column.name) == key);
  }

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
      virtualTable: virtualTable,
      schemaSql: schemaSql,
      isSequenceTable: isSequenceTable,
      isTemporary: isTemporary,
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
    result.recordOffsets.addAll(recordOffsets);
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
    this.autoIncrement = false,
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
  final bool autoIncrement;
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
    autoIncrement: autoIncrement,
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
    this.terms, {
    this.rootPage,
    this.unique = false,
    this.where,
    this.schemaSql,
  });

  String name;
  final _Table table;
  final List<_IndexTerm> terms;
  int? rootPage;
  final bool unique;
  final _Expr? where;
  String? schemaSql;

  _Index copy(_Table table) => _Index(
    name,
    table,
    List<_IndexTerm>.from(terms),
    rootPage: rootPage,
    unique: unique,
    where: where,
    schemaSql: schemaSql,
  );
}

class _IndexTerm {
  const _IndexTerm(this.expression, {this.collation, this.descending = false});

  final _Expr expression;
  final String? collation;
  final bool descending;
}

sealed class _Statement {}

class _Drop extends _Statement {
  _Drop(this.type, this.name, this.ifExists, {this.schema});
  final String type;
  final String name;
  final bool ifExists;
  final String? schema;
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
    this.temporary = false,
  });

  final String name;
  final List<_ColumnDef> columns;
  final bool ifNotExists;
  final List<String> primaryKeyColumns;
  final List<_Expr> checkExpressions;
  final List<List<String>> uniqueConstraints;
  final List<_ForeignKey> foreignKeyConstraints;
  final bool temporary;

  String? get autoIncrementColumn {
    for (final column in columns) {
      if (column.autoIncrement) return column.name;
    }
    return null;
  }
}

class _CreateVirtualTable extends _Statement {
  _CreateVirtualTable(
    this.name,
    this.module,
    this.arguments,
    this.ifNotExists, {
    this.temporary = false,
  });

  final String name;
  final String module;
  final List<String> arguments;
  final bool ifNotExists;
  final bool temporary;
}

class _CreateTableAs extends _Statement {
  _CreateTableAs(
    this.name,
    this.query,
    this.ifNotExists, {
    this.temporary = false,
  });

  final String name;
  final _Select query;
  final bool ifNotExists;
  final bool temporary;
}

class _CreateView extends _Statement {
  _CreateView(
    this.name,
    this.query,
    this.ifNotExists,
    this.columns, {
    this.temporary = false,
  });
  final String name;
  final _Select query;
  final bool ifNotExists;
  final List<String>? columns;
  final bool temporary;
  String? schemaSql;
}

class _CreateTrigger extends _Statement {
  _CreateTrigger(
    this.name,
    this.table,
    this.timing,
    this.event,
    this.updateOf,
    this.when,
    this.steps,
    this.ifNotExists,
    this.usesRaise, {
    this.temporary = false,
  });

  final String name;
  final String table;
  final String timing;
  final String event;
  final List<String> updateOf;
  final _Expr? when;
  final List<_Statement> steps;
  final bool ifNotExists;
  final bool usesRaise;
  final bool temporary;
  bool targetTemporary = false;
  String? schemaSql;
}

class _CreateIndex extends _Statement {
  _CreateIndex(
    this.name,
    this.table,
    this.terms, {
    this.unique = false,
    this.ifNotExists = false,
    this.where,
    this.temporary = false,
  });

  final String name;
  final String table;
  final List<_IndexTerm> terms;
  final bool unique;
  final bool ifNotExists;
  final _Expr? where;
  final bool temporary;
}

class _AlterTable extends _Statement {
  _AlterTable(this.table, this.column, this.definitionSql, {this.schema});

  final String table;
  final _ColumnDef column;
  final String definitionSql;
  final String? schema;
}

class _RenameTable extends _Statement {
  _RenameTable(this.table, this.newName, {this.schema});

  final String table;
  final String newName;
  final String? schema;
}

class _RenameColumn extends _Statement {
  _RenameColumn(this.table, this.oldName, this.newName, {this.schema});

  final String table;
  final String oldName;
  final String newName;
  final String? schema;
}

class _DropColumn extends _Statement {
  _DropColumn(this.table, this.name, {this.schema});

  final String table;
  final String name;
  final String? schema;
}

class _Begin extends _Statement {}

class _Commit extends _Statement {}

class _Rollback extends _Statement {}

class _Savepoint extends _Statement {
  _Savepoint(this.name);
  final String name;
}

class _RollbackTo extends _Statement {
  _RollbackTo(this.name);
  final String name;
}

class _Release extends _Statement {
  _Release(this.name);
  final String name;
}

class _SqlSavepoint {
  _SqlSavepoint(
    this.name,
    this.startsTransaction, {
    required this.pager,
    required this.tables,
    required this.temporaryTables,
    required this.views,
    required this.temporaryViews,
    required this.triggers,
    required this.temporaryTriggers,
    required this.schemaVersion,
    required this.applicationId,
    required this.userVersion,
    required this.memoryPageSize,
    required this.temporaryPragmaValues,
    required this.pendingVirtualTableDestroy,
    required this.dirtyVirtualTables,
  });

  final String name;
  final bool startsTransaction;
  final SqlitePagerSavepoint? pager;
  final Map<String, _Table> tables;
  final Map<String, _Table> temporaryTables;
  final Map<String, _CreateView> views;
  final Map<String, _CreateView> temporaryViews;
  final Map<String, _CreateTrigger> triggers;
  final Map<String, _CreateTrigger> temporaryTriggers;
  final int schemaVersion;
  final int applicationId;
  final int userVersion;
  final int memoryPageSize;
  final Map<String, Object> temporaryPragmaValues;
  final List<SqlVirtualTable> pendingVirtualTableDestroy;
  final Set<SqlVirtualTable> dirtyVirtualTables;
}

class _Pragma extends _Statement {
  _Pragma(this.name, this.value, {this.argument, this.schema});

  String name;
  final _Expr? value;
  final _Expr? argument;
  final String? schema;
}

class _Attach extends _Statement {
  _Attach(this.filename, this.schema);

  final _Expr filename;
  final String schema;
}

class _Detach extends _Statement {
  _Detach(this.schema);

  final String schema;
}

class _AttachedDatabase {
  _AttachedDatabase(this.name, this.filename, this.database);

  final String name;
  final String filename;
  final PureDatabase database;
}

class _Analyze extends _Statement {
  _Analyze(this.target, {this.schema});

  final String? target;
  final String? schema;
}

class _Vacuum extends _Statement {
  _Vacuum(this.schema, [this.into]);

  final String? schema;
  final _Expr? into;
}

class _Reindex extends _Statement {
  _Reindex(this.target, {this.schema});

  final String? target;
  final String? schema;
}

class _Insert extends _Statement {
  _Insert(
    this.table,
    this.columns,
    this.rows, {
    this.conflict = 'abort',
    this.defaultValues = false,
    this.select,
    this.upserts = const [],
    this.returning,
  });
  final String table;
  final List<String>? columns;
  final List<List<_Expr>> rows;
  final String conflict;
  final bool defaultValues;
  final _Select? select;
  final List<_UpsertClause> upserts;
  final List<_SelectItem>? returning;
}

class _UpsertClause {
  _UpsertClause(
    this.target, {
    this.targetWhere,
    this.doNothing = false,
    this.assignments = const [],
    this.where,
  });

  final List<_UpsertTargetTerm>? target;
  final _Expr? targetWhere;
  final bool doNothing;
  final List<_UpdateAssignment> assignments;
  final _Expr? where;
}

class _UpsertTargetTerm {
  const _UpsertTargetTerm(this.expression, this.collation);

  final _Expr expression;
  final String? collation;
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
    this.tableFunction,
    this.namedWindows = const {},
    this.startToken,
    this.endToken,
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
  final _TableFunction? tableFunction;
  final Map<String, _WindowSpec> namedWindows;
  final int? startToken;
  final int? endToken;
}

class _TableFunction {
  _TableFunction(this.name, this.arguments, {this.schema});

  final String name;
  final List<_Expr> arguments;
  final String? schema;
}

class _CompoundTerm {
  _CompoundTerm(this.operator, this.query, {this.all = false});

  final String operator;
  final _Select query;
  final bool all;
}

class _Cte {
  _Cte(_Select query, this.columns) {
    this.query = query;
  }

  _Cte.placeholder(this.columns) : recursive = false;

  late _Select query;
  final List<String>? columns;
  bool recursive = false;
  int recursiveTermIndex = 0;
}

class _Join {
  _Join(
    this.table,
    this.alias, {
    this.query,
    this.tableFunction,
    required this.type,
    this.on,
    this.usingColumns = const [],
    this.natural = false,
  });

  final String? table;
  final String? alias;
  final _Select? query;
  final _TableFunction? tableFunction;
  final String type;
  final _Expr? on;
  final List<String> usingColumns;
  final bool natural;
}

class _Update extends _Statement {
  _Update(
    this.table,
    this.assignments,
    this.where, {
    this.conflict = 'abort',
    this.returning,
  });
  final String table;
  final List<_UpdateAssignment> assignments;
  final _Expr? where;
  final String conflict;
  final List<_SelectItem>? returning;
}

class _UpdateAssignment {
  _UpdateAssignment(this.columns, this.expression);

  final List<String> columns;
  final _Expr expression;
}

class _RowIdAssignment {
  const _RowIdAssignment(this.value);

  final Object? value;
}

class _Delete extends _Statement {
  _Delete(this.table, this.where, {this.returning});
  final String table;
  final _Expr? where;
  final List<_SelectItem>? returning;
}

class _SelectItem {
  _SelectItem(this.expression, this.outputName, {this.explicitAlias = false});
  final _Expr expression;
  final String outputName;
  final bool explicitAlias;
}

class _Function extends _Expr {
  _Function(this.name, this.arguments, {this.distinct = false, this.filter});

  final String name;
  final List<_Expr> arguments;
  final bool distinct;
  final _Expr? filter;
}

class _WindowFunction extends _Expr {
  _WindowFunction(
    this.id,
    this.function,
    this.partitionBy,
    this.orderBy, {
    this.frame,
    this.windowName,
    this.windowSpec,
  });

  final int id;
  final _Function function;
  List<_Expr> partitionBy;
  List<_Order> orderBy;
  _WindowFrame? frame;
  String? windowName;
  _WindowSpec? windowSpec;
}

class _WindowSpec {
  _WindowSpec(this.partitionBy, this.orderBy, this.frame, {this.baseName});

  final List<_Expr> partitionBy;
  final List<_Order> orderBy;
  final _WindowFrame? frame;
  final String? baseName;
}

class _WindowFrame {
  _WindowFrame(this.type, this.start, this.end, {this.exclude = 'noOthers'});

  final String type;
  final _WindowFrameBound start;
  final _WindowFrameBound end;
  final String exclude;
}

class _WindowFrameBound {
  const _WindowFrameBound(this.kind, [this.offset]);
  const _WindowFrameBound.current() : this('current');
  const _WindowFrameBound.unboundedPreceding() : this('unboundedPreceding');
  const _WindowFrameBound.unboundedFollowing() : this('unboundedFollowing');

  final String kind;
  final _Expr? offset;
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

class _RowValue extends _Expr {
  _RowValue(this.values);

  final List<_Expr> values;
}

class _SqlRowValue {
  _SqlRowValue(this.values);

  final List<Object?> values;
}

class _Order {
  _Order(this.expression, this.descending, this.noCase, {this.nullsFirst});
  final _Expr expression;
  final bool descending;
  final bool noCase;
  final bool? nullsFirst;
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
  final tokens = _Tokenizer(sql).tokenize();
  var statementStartToken = 0;
  var inTrigger = _isCreateTriggerAt(tokens, 0);
  var triggerBody = false;
  var triggerEnded = false;
  var parenthesisDepth = 0;
  var caseDepth = 0;
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.type == _TokenType.eof) break;
    if (!inTrigger && token.text == ';') {
      final candidate = sql.substring(statementStart, token.start).trim();
      if (candidate.isNotEmpty) result.add(candidate);
      statementStart = token.end;
      statementStartToken = index + 1;
      inTrigger = _isCreateTriggerAt(tokens, statementStartToken);
      triggerBody = false;
      triggerEnded = false;
      parenthesisDepth = 0;
      caseDepth = 0;
      continue;
    }
    if (!inTrigger) continue;
    if (token.text == '(') parenthesisDepth++;
    if (token.text == ')') parenthesisDepth--;
    if (token.type == _TokenType.word && !token.quoted) {
      final word = token.text.toUpperCase();
      if (!triggerBody && word == 'BEGIN' && parenthesisDepth == 0) {
        triggerBody = true;
      } else if (triggerBody && word == 'CASE') {
        caseDepth++;
      } else if (triggerBody && word == 'END') {
        if (caseDepth > 0) {
          caseDepth--;
        } else {
          triggerEnded = true;
        }
      }
    }
    if (token.text == ';' && triggerEnded) {
      final candidate = sql.substring(statementStart, token.start).trim();
      if (candidate.isNotEmpty) result.add(candidate);
      statementStart = token.end;
      statementStartToken = index + 1;
      inTrigger = _isCreateTriggerAt(tokens, statementStartToken);
      triggerBody = false;
      triggerEnded = false;
      parenthesisDepth = 0;
      caseDepth = 0;
    }
  }
  final candidate = sql.substring(statementStart).trim();
  if (candidate.isNotEmpty &&
      _Tokenizer(candidate).tokenize().first.type != _TokenType.eof) {
    result.add(candidate);
  }
  return result;
}

bool _isCreateTriggerAt(List<_Token> tokens, int start) {
  if (start >= tokens.length ||
      tokens[start].type != _TokenType.word ||
      tokens[start].quoted ||
      tokens[start].text.toUpperCase() != 'CREATE') {
    return false;
  }
  var index = start + 1;
  if (index < tokens.length &&
      tokens[index].type == _TokenType.word &&
      !tokens[index].quoted &&
      const {'TEMP', 'TEMPORARY'}.contains(tokens[index].text.toUpperCase())) {
    index++;
  }
  return index < tokens.length &&
      tokens[index].type == _TokenType.word &&
      !tokens[index].quoted &&
      tokens[index].text.toUpperCase() == 'TRIGGER';
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
        final three = _offset + 2 < sql.length
            ? sql.substring(_offset, _offset + 3)
            : '';
        final two = _offset + 1 < sql.length
            ? sql.substring(_offset, _offset + 2)
            : '';
        if (three == '->>') {
          result.add(
            _Token.positioned(
              _TokenType.symbol,
              three,
              start: start,
              end: start + 3,
            ),
          );
          _offset += 3;
        } else if (const [
          '<=',
          '>=',
          '<>',
          '!=',
          '||',
          '<<',
          '>>',
          '->',
        ].contains(two)) {
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
  _Parser(String sql) : _sql = sql, _tokens = _Tokenizer(sql).tokenize();
  final String _sql;
  final List<_Token> _tokens;
  Map<String, _Cte> _cteContext = const {};
  final Map<String, int> _namedParameters = {};
  final Set<int> _positionalParameters = {};
  var _index = 0;
  var _nextParameter = 0;
  var _nextWindowFunctionId = 0;
  var _sawRaise = false;

  Map<String, int> get namedParameters => _namedParameters;
  Set<int> get positionalParameters => _positionalParameters;
  int get parameterCount => _nextParameter;

  _Statement parse() {
    final statement = switch (_word) {
      'CREATE' => _create(),
      'DROP' => _drop(),
      'ALTER' => _alterTable(),
      'ANALYZE' => _analyze(),
      'REINDEX' => _reindex(),
      'VACUUM' => _vacuum(),
      'BEGIN' => _begin(),
      'COMMIT' => _commit(),
      'END' => _commit(),
      'ROLLBACK' => _rollback(),
      'SAVEPOINT' => _savepoint(),
      'RELEASE' => _release(),
      'ATTACH' => _attach(),
      'DETACH' => _detach(),
      'PRAGMA' => _pragma(),
      'INSERT' => _insert(),
      'REPLACE' => _insert(),
      'WITH' => _withStatement(),
      'SELECT' => _select(),
      'VALUES' => _select(),
      'UPDATE' => _update(),
      'DELETE' => _delete(),
      _ => throw PureSqlException('unsupported statement: ${_peek.text}'),
    };
    if (_accept(';')) {}
    _expectType(_TokenType.eof);
    return statement;
  }

  _Statement _withStatement() {
    final outerContext = _cteContext;
    try {
      return _parseWithStatement(outerContext);
    } finally {
      _cteContext = outerContext;
    }
  }

  _Statement _parseWithStatement(Map<String, _Cte> outerContext) {
    _expectWord('WITH');
    final recursive = _acceptWord('RECURSIVE');
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
      if (!_acceptWord('MATERIALIZED') && _acceptWord('NOT')) {
        _expectWord('MATERIALIZED');
      }
      _expect('(');
      final placeholder = recursive ? _Cte.placeholder(columns) : null;
      if (placeholder != null) ctes[_key(name)] = placeholder;
      _cteContext = Map.unmodifiable({...outerContext, ...ctes});
      final query = _select();
      _expect(')');
      if (placeholder == null) {
        ctes[_key(name)] = _Cte(query, columns);
        continue;
      }
      placeholder.query = query;
      final firstRecursiveTerm = query.compoundTerms.indexWhere(
        (term) => _sourceReferences(term.query, name) > 0,
      );
      if (firstRecursiveTerm < 0) {
        if (_sourceReferences(query, name, includeCompoundTerms: false) > 0) {
          throw PureSqlException('recursive CTE reference must follow UNION');
        }
        placeholder.recursive = false;
      } else {
        final terms = query.compoundTerms;
        final recursiveTerms = terms.skip(firstRecursiveTerm);
        final recursiveOperator = recursiveTerms.first;
        if (recursiveTerms.any(
              (term) =>
                  term.operator != 'UNION' ||
                  term.all != recursiveOperator.all ||
                  _sourceReferences(term.query, name) != 1 ||
                  _selectHasAggregate(term.query),
            ) ||
            _sourceReferences(query, name, includeCompoundTerms: false) != 0 ||
            query.orderBy.any(
              (order) => _containsAggregate(order.expression),
            )) {
          throw PureSqlException(
            'recursive CTE requires anchors followed by same-mode UNION arms',
          );
        }
        placeholder.recursiveTermIndex = firstRecursiveTerm;
        placeholder.recursive = true;
      }
    } while (_accept(','));
    _cteContext = Map.unmodifiable({...outerContext, ...ctes});
    return switch (_word) {
      'SELECT' || 'VALUES' => _select(),
      'INSERT' || 'REPLACE' => _insert(),
      'UPDATE' => _update(),
      'DELETE' => _delete(),
      _ => throw PureSqlException('WITH must precede SELECT or DML'),
    };
  }

  _Select _withSelect() {
    final statement = _withStatement();
    if (statement is! _Select) {
      throw PureSqlException('WITH query must end in SELECT');
    }
    return statement;
  }

  int _sourceReferences(
    _Select query,
    String name, {
    bool includeCompoundTerms = true,
  }) {
    var count = query.table != null && _key(query.table!) == _key(name) ? 1 : 0;
    for (final join in query.joins) {
      if (join.table != null && _key(join.table!) == _key(name)) count++;
      if (join.query != null) count += _sourceReferences(join.query!, name);
    }
    if (query.fromQuery != null) {
      count += _sourceReferences(query.fromQuery!, name);
    }
    if (includeCompoundTerms) {
      for (final term in query.compoundTerms) {
        count += _sourceReferences(term.query, name);
      }
    }
    return count;
  }

  bool _selectHasAggregate(_Select query) =>
      query.items.any((item) => _containsAggregate(item.expression)) ||
      query.groupBy.any(_containsAggregate) ||
      query.where != null && _containsAggregate(query.where!) ||
      query.having != null && _containsAggregate(query.having!) ||
      query.joins.any(
        (join) => join.on != null && _containsAggregate(join.on!),
      );

  _Statement _create() {
    _expectWord('CREATE');
    final temporary = _acceptWord('TEMP') || _acceptWord('TEMPORARY');
    final unique = _acceptWord('UNIQUE');
    if (_acceptWord('INDEX')) {
      return _createIndex(unique, temporary: temporary);
    }
    if (unique) throw PureSqlException('UNIQUE is valid only with INDEX');
    if (_acceptWord('TRIGGER')) {
      return _createTrigger(temporary: temporary);
    }
    if (_acceptWord('VIEW')) return _createView(temporary: temporary);
    if (_acceptWord('VIRTUAL')) {
      _expectWord('TABLE');
      final ifNotExists =
          _acceptWord('IF') && _acceptWord('NOT') && _acceptWord('EXISTS');
      final name = _tableReference();
      _expectWord('USING');
      final module = _identifier();
      return _CreateVirtualTable(
        name,
        module,
        _virtualTableArguments(),
        ifNotExists,
        temporary: temporary,
      );
    }
    _expectWord('TABLE');
    final ifNotExists =
        _acceptWord('IF') && _acceptWord('NOT') && _acceptWord('EXISTS');
    final name = _tableReference();
    if (_acceptWord('AS')) {
      return _CreateTableAs(
        name,
        _word == 'WITH' ? _withSelect() : _select(),
        ifNotExists,
        temporary: temporary,
      );
    }
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
        var autoIncrement = false;
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
          } else if (_acceptWord('AUTOINCREMENT')) {
            autoIncrement = true;
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
        if (autoIncrement &&
            (!primaryKey || typeName?.toUpperCase() != 'INTEGER')) {
          throw PureSqlException(
            'AUTOINCREMENT requires an INTEGER PRIMARY KEY',
          );
        }
        columns.add(
          _ColumnDef(
            columnName,
            typeName: typeName,
            notNull: notNull,
            primaryKey: primaryKey,
            autoIncrement: autoIncrement,
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
    if (columns.where((column) => column.autoIncrement).length > 1 ||
        columns.any((column) => column.autoIncrement) &&
            primaryKeyColumns.isNotEmpty) {
      throw PureSqlException(
        'AUTOINCREMENT requires a single rowid primary key',
      );
    }
    return _CreateTable(
      name,
      columns,
      ifNotExists,
      primaryKeyColumns: primaryKeyColumns,
      checkExpressions: checks,
      uniqueConstraints: uniqueConstraints,
      foreignKeyConstraints: foreignKeyConstraints,
      temporary: temporary,
    );
  }

  List<String> _virtualTableArguments() {
    if (!_accept('(')) return const [];
    if (_accept(')')) return const [];
    final arguments = <String>[];
    var depth = 0;
    var start = _peek.start;
    while (_peek.type != _TokenType.eof) {
      final token = _peek;
      if (token.text == '(') {
        depth++;
      } else if (token.text == ')') {
        if (depth == 0) {
          arguments.add(_sql.substring(start, token.start).trim());
          _advance();
          return arguments;
        }
        depth--;
      } else if (token.text == ',' && depth == 0) {
        arguments.add(_sql.substring(start, token.start).trim());
        _advance();
        start = _peek.start;
        continue;
      }
      _advance();
    }
    throw PureSqlException('unterminated virtual-table arguments');
  }

  _CreateTrigger _createTrigger({bool temporary = false}) {
    final ifNotExists =
        _acceptWord('IF') && _acceptWord('NOT') && _acceptWord('EXISTS');
    final name = _tableReference();
    final timing = _acceptWord('BEFORE')
        ? 'BEFORE'
        : _acceptWord('AFTER')
        ? 'AFTER'
        : _acceptWord('INSTEAD')
        ? _acceptWord('OF')
              ? 'INSTEAD OF'
              : throw PureSqlException('trigger requires INSTEAD OF timing')
        : throw PureSqlException(
            'trigger requires BEFORE, AFTER, or INSTEAD OF timing',
          );
    final event = _acceptWord('INSERT')
        ? 'INSERT'
        : _acceptWord('UPDATE')
        ? 'UPDATE'
        : _acceptWord('DELETE')
        ? 'DELETE'
        : throw PureSqlException('trigger requires INSERT, UPDATE, or DELETE');
    final updateOf = <String>[];
    if (event == 'UPDATE' && _acceptWord('OF')) {
      updateOf.add(_identifier());
      while (_accept(',')) {
        updateOf.add(_identifier());
      }
    }
    _expectWord('ON');
    final table = _identifier();
    if (_acceptWord('FOR')) {
      _expectWord('EACH');
      _expectWord('ROW');
    }
    final when = _acceptWord('WHEN') ? _expression() : null;
    _expectWord('BEGIN');
    final steps = <_Statement>[];
    while (true) {
      while (_accept(';')) {}
      if (_acceptWord('END')) break;
      final step = switch (_word) {
        'INSERT' || 'REPLACE' => _insert(),
        'UPDATE' => _update(),
        'DELETE' => _delete(),
        'SELECT' || 'VALUES' => _select(),
        'WITH' => _withStatement(),
        _ => throw PureSqlException(
          'trigger bodies support SELECT, INSERT, UPDATE, and DELETE only',
        ),
      };
      if (step
          case _Insert(returning: != null) ||
              _Update(returning: != null) ||
              _Delete(returning: != null)) {
        throw PureSqlException('RETURNING is not supported in trigger bodies');
      }
      steps.add(step);
      if (_word != 'END' && _peek.text != ';') {
        throw PureSqlException('expected ; between trigger steps');
      }
    }
    if (steps.isEmpty) throw PureSqlException('trigger body must not be empty');
    return _CreateTrigger(
      name,
      table,
      timing,
      event,
      updateOf,
      when,
      steps,
      ifNotExists,
      _sawRaise,
      temporary: temporary,
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
        : _acceptWord('TRIGGER')
        ? 'trigger'
        : throw PureSqlException(
            'DROP supports TABLE, INDEX, VIEW, or TRIGGER',
          );
    final ifExists = _acceptWord('IF') && _acceptWord('EXISTS');
    return _Drop(type, _tableReference(), ifExists);
  }

  _Statement _createView({bool temporary = false}) {
    final ifNotExists =
        _acceptWord('IF') && _acceptWord('NOT') && _acceptWord('EXISTS');
    final name = _tableReference();
    List<String>? columns;
    if (_accept('(')) {
      columns = [_identifier()];
      while (_accept(',')) {
        columns.add(_identifier());
      }
      _expect(')');
    }
    _expectWord('AS');
    final query = _word == 'WITH' ? _withSelect() : _select();
    return _CreateView(name, query, ifNotExists, columns, temporary: temporary);
  }

  String? _declaredType() {
    const constraints = {
      'NOT',
      'PRIMARY',
      'AUTOINCREMENT',
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

  _Statement _createIndex(bool unique, {bool temporary = false}) {
    final ifNotExists =
        _acceptWord('IF') && _acceptWord('NOT') && _acceptWord('EXISTS');
    final name = _tableReference();
    _expectWord('ON');
    final table = _tableReference();
    _expect('(');
    final terms = <_IndexTerm>[];
    do {
      final expression = _expression();
      String? collation;
      if (_acceptWord('COLLATE')) {
        collation = _identifier().toUpperCase();
        if (!const ['BINARY', 'NOCASE'].contains(collation)) {
          throw PureSqlException('unsupported collation: $collation');
        }
      }
      final isDescending = _acceptWord('DESC');
      if (!isDescending) _acceptWord('ASC');
      terms.add(
        _IndexTerm(expression, collation: collation, descending: isDescending),
      );
    } while (_accept(','));
    _expect(')');
    final where = _acceptWord('WHERE') ? _expression() : null;
    return _CreateIndex(
      name,
      table,
      terms,
      unique: unique,
      ifNotExists: ifNotExists,
      where: where,
      temporary: temporary,
    );
  }

  _Statement _pragma() {
    _expectWord('PRAGMA');
    final first = _identifier();
    final schema = _accept('.') ? first : null;
    final name = schema == null ? first : _identifier();
    _Expr? argument;
    if (_accept('(')) {
      argument = _expression();
      _expect(')');
    }
    final value = _accept('=') ? _expression() : null;
    if (argument != null && value != null) {
      throw PureSqlException('PRAGMA cannot take both an argument and a value');
    }
    return _Pragma(name, value, argument: argument, schema: schema);
  }

  _Attach _attach() {
    _expectWord('ATTACH');
    _acceptWord('DATABASE');
    final filename = _expression();
    _expectWord('AS');
    return _Attach(filename, _identifier());
  }

  _Detach _detach() {
    _expectWord('DETACH');
    _acceptWord('DATABASE');
    return _Detach(_identifier());
  }

  _Analyze _analyze() {
    _expectWord('ANALYZE');
    if (_peek.type != _TokenType.word) return _Analyze(null);
    final first = _identifier();
    if (_accept('.')) return _Analyze(_identifier(), schema: first);
    if (const ['main', 'temp'].contains(_key(first))) {
      return _Analyze(null, schema: first);
    }
    return _Analyze(first);
  }

  _Reindex _reindex() {
    _expectWord('REINDEX');
    if (_peek.type != _TokenType.word) return _Reindex(null);
    final first = _identifier();
    return _accept('.')
        ? _Reindex(_identifier(), schema: first)
        : _Reindex(first);
  }

  _Vacuum _vacuum() {
    _expectWord('VACUUM');
    final schema = _peek.type == _TokenType.word && _word != 'INTO'
        ? _identifier()
        : null;
    final into = _acceptWord('INTO') ? _expression() : null;
    return _Vacuum(schema, into);
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
    _acceptWord('TRANSACTION');
    if (_acceptWord('TO')) {
      _acceptWord('SAVEPOINT');
      return _RollbackTo(_identifier());
    }
    return _Rollback();
  }

  _Statement _savepoint() {
    _expectWord('SAVEPOINT');
    return _Savepoint(_identifier());
  }

  _Statement _release() {
    _expectWord('RELEASE');
    _acceptWord('SAVEPOINT');
    return _Release(_identifier());
  }

  _Statement _alterTable() {
    _expectWord('ALTER');
    _expectWord('TABLE');
    final table = _tableReference();
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
    final definitionStart = _peek.start;
    final name = _identifier();
    final typeName = _declaredType();
    var notNull = false;
    var primaryKey = false;
    var autoIncrement = false;
    var unique = false;
    _Expr? defaultExpression;
    String? referencesTable;
    String? referencesColumn;
    var onDelete = 'NO ACTION';
    var onUpdate = 'NO ACTION';
    String? collation;
    final checks = <_Expr>[];
    while (_peek.type == _TokenType.word) {
      if (_acceptWord('NOT')) {
        _expectWord('NULL');
        notNull = true;
      } else if (_acceptWord('DEFAULT')) {
        defaultExpression = _primary();
      } else if (_acceptWord('PRIMARY')) {
        _expectWord('KEY');
        primaryKey = true;
      } else if (_acceptWord('UNIQUE')) {
        unique = true;
      } else if (_acceptWord('AUTOINCREMENT')) {
        autoIncrement = true;
      } else if (_acceptWord('CHECK')) {
        checks.add(_checkExpression());
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
        primaryKey: primaryKey,
        autoIncrement: autoIncrement,
        unique: unique,
        defaultExpression: defaultExpression,
        referencesTable: referencesTable,
        referencesColumn: referencesColumn,
        onDelete: onDelete,
        onUpdate: onUpdate,
        collation: collation,
        checkExpressions: checks,
      ),
      _sql.substring(definitionStart, _tokens[_index - 1].end),
    );
  }

  _Statement _insert() {
    final replace = _acceptWord('REPLACE');
    if (!replace) _expectWord('INSERT');
    var conflict = replace ? 'replace' : 'abort';
    if (!replace && _acceptWord('OR')) {
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
    final table = _tableReference();
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
    if (_word == 'SELECT' || _word == 'WITH') {
      return _parseUpsert(
        _Insert(
          table,
          columns,
          const [],
          conflict: conflict,
          select: _word == 'WITH' ? _withSelect() : _select(),
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
    final clauses = <_UpsertClause>[];
    while (_acceptWord('ON')) {
      _expectWord('CONFLICT');
      List<_UpsertTargetTerm>? target;
      if (_accept('(')) {
        target = [_upsertTargetTerm()];
        while (_accept(',')) {
          target.add(_upsertTargetTerm());
        }
        _expect(')');
      }
      final targetWhere = target != null && _acceptWord('WHERE')
          ? _expression()
          : null;
      _expectWord('DO');
      if (_acceptWord('NOTHING')) {
        clauses.add(
          _UpsertClause(target, targetWhere: targetWhere, doNothing: true),
        );
        continue;
      }
      _expectWord('UPDATE');
      _expectWord('SET');
      final assignments = <_UpdateAssignment>[];
      do {
        final columns = <String>[];
        if (_accept('(')) {
          columns.add(_identifier());
          while (_accept(',')) {
            columns.add(_identifier());
          }
          _expect(')');
          if (columns.length < 2) {
            throw PureSqlException('row assignment requires multiple columns');
          }
        } else {
          columns.add(_identifier());
        }
        _expect('=');
        assignments.add(_UpdateAssignment(columns, _expression()));
      } while (_accept(','));
      final where = _acceptWord('WHERE') ? _expression() : null;
      clauses.add(
        _UpsertClause(
          target,
          targetWhere: targetWhere,
          assignments: assignments,
          where: where,
        ),
      );
    }
    final returning = _returningItems();
    if (clauses.isEmpty && returning == null) return insert;
    if (clauses.length > 1 &&
        clauses
            .take(clauses.length - 1)
            .any((clause) => clause.target == null)) {
      throw PureSqlException('only the final UPSERT clause may omit a target');
    }
    return _Insert(
      insert.table,
      insert.columns,
      insert.rows,
      conflict: insert.conflict,
      defaultValues: insert.defaultValues,
      select: insert.select,
      upserts: clauses,
      returning: returning,
    );
  }

  _UpsertTargetTerm _upsertTargetTerm() {
    final expression = _expression();
    String? collation;
    if (_acceptWord('COLLATE')) {
      collation = _identifier().toUpperCase();
      if (!const ['BINARY', 'NOCASE'].contains(collation)) {
        throw PureSqlException('unsupported collation: $collation');
      }
    }
    if (!_acceptWord('DESC')) _acceptWord('ASC');
    return _UpsertTargetTerm(expression, collation);
  }

  _Select _select() {
    final startToken = _index;
    final first = _selectCore();
    final terms = List<_CompoundTerm>.from(first.compoundTerms);
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
        bool? nullsFirst;
        if (_acceptWord('NULLS')) {
          nullsFirst = _acceptWord('FIRST')
              ? true
              : _acceptWord('LAST')
              ? false
              : throw PureSqlException('expected FIRST or LAST after NULLS');
        }
        order.add(
          _Order(expression, descending, noCase, nullsFirst: nullsFirst),
        );
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
    _resolveNamedWindows(
      first.items.map((item) => item.expression),
      first.namedWindows,
    );
    for (final term in terms) {
      _resolveNamedWindows(
        term.query.items.map((item) => item.expression),
        term.query.namedWindows,
      );
    }
    _resolveNamedWindows(
      order.map((order) => order.expression),
      first.namedWindows,
    );
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
      tableFunction: first.tableFunction,
      compoundTerms: terms,
      namedWindows: first.namedWindows,
      startToken: first.startToken ?? startToken,
      endToken: terms.isEmpty ? _index : first.endToken,
    );
  }

  void _resolveNamedWindows(
    Iterable<_Expr> expressions,
    Map<String, _WindowSpec> namedWindows,
  ) {
    for (final expression in expressions) {
      for (final window in _windowFunctions(expression)) {
        final name = window.windowName;
        final spec = name == null
            ? window.windowSpec
            : namedWindows[_key(name)];
        if (name != null && spec == null) {
          throw PureSqlException('no such window: $name');
        }
        if (spec == null) continue;
        final resolved = _resolveWindowSpec(spec, namedWindows);
        window
          ..partitionBy = resolved.partitionBy
          ..orderBy = resolved.orderBy
          ..frame = resolved.frame
          ..windowName = null
          ..windowSpec = null;
      }
    }
  }

  _WindowSpec _resolveWindowSpec(
    _WindowSpec spec,
    Map<String, _WindowSpec> namedWindows,
  ) {
    final baseName = spec.baseName;
    final base = baseName == null ? null : namedWindows[_key(baseName)];
    if (base != null) {
      if (base.frame != null) {
        throw PureSqlException('cannot chain from a window with a frame');
      }
      if (spec.partitionBy.isNotEmpty) {
        throw PureSqlException('cannot override PARTITION BY of a window');
      }
      if (base.orderBy.isNotEmpty && spec.orderBy.isNotEmpty) {
        throw PureSqlException('cannot override ORDER BY of a window');
      }
    }
    final resolved = _WindowSpec(
      base?.partitionBy ?? spec.partitionBy,
      spec.orderBy.isNotEmpty ? spec.orderBy : base?.orderBy ?? spec.orderBy,
      spec.frame,
    );
    if (resolved.frame?.type == 'RANGE' &&
        (resolved.frame!.start.offset != null ||
            resolved.frame!.end.offset != null) &&
        resolved.orderBy.length != 1) {
      throw PureSqlException(
        'RANGE offsets require exactly one ORDER BY expression',
      );
    }
    return resolved;
  }

  _Select _selectCore() {
    final startToken = _index;
    if (_acceptWord('VALUES')) {
      final rows = <List<_SelectItem>>[];
      do {
        _expect('(');
        final expressions = <_Expr>[_expression()];
        while (_accept(',')) {
          expressions.add(_expression());
        }
        _expect(')');
        if (rows.isNotEmpty && expressions.length != rows.first.length) {
          throw PureSqlException(
            'VALUES rows must all have the same number of columns',
          );
        }
        rows.add([
          for (var index = 0; index < expressions.length; index++)
            _SelectItem(expressions[index], 'column${index + 1}'),
        ]);
      } while (_accept(','));
      return _Select(
        rows.first,
        null,
        null,
        const [],
        null,
        const [],
        null,
        const [],
        null,
        null,
        false,
        compoundTerms: [
          for (final row in rows.skip(1))
            _CompoundTerm(
              'UNION',
              _Select(
                row,
                null,
                null,
                const [],
                null,
                const [],
                null,
                const [],
                null,
                null,
                false,
              ),
              all: true,
            ),
        ],
        startToken: startToken,
        endToken: _index,
      );
    }
    _expectWord('SELECT');
    final distinct = _acceptWord('DISTINCT');
    if (!distinct) _acceptWord('ALL');
    final items = <_SelectItem>[];
    if (_accept('*')) {
      items.add(_SelectItem(_Column('*'), '*'));
    } else {
      do {
        final expression = _expression();
        final explicitAlias = _acceptWord('AS');
        final name = explicitAlias
            ? _identifier()
            : expression is _Column
            ? expression.name
            : 'column${items.length + 1}';
        items.add(_SelectItem(expression, name, explicitAlias: explicitAlias));
      } while (_accept(','));
    }
    String? table;
    _TableFunction? tableFunction;
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
        final name = _tableReference();
        tableFunction = _parseTableFunction(name);
        if (tableFunction == null) {
          table = name;
        } else {
          alias = tableFunction.name;
        }
        alias = _acceptWord('AS')
            ? _identifier()
            : _acceptAlias(_peek.text)
            ? _identifier()
            : alias;
      }
    }
    final joins = <_Join>[];
    while (true) {
      final commaJoin = _accept(',');
      final natural = !commaJoin && _acceptWord('NATURAL');
      var type = commaJoin ? 'CROSS' : 'INNER';
      var joinModifier = natural;
      if (!commaJoin) {
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
      }
      if (table == null && tableFunction == null && fromQuery == null) {
        throw PureSqlException('JOIN requires a FROM clause');
      }
      String? joinedTable;
      _TableFunction? joinedFunction;
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
        final name = _tableReference();
        joinedFunction = _parseTableFunction(name);
        if (joinedFunction == null) {
          joinedTable = name;
        } else {
          joinedAlias = joinedFunction.name;
        }
        joinedAlias = _acceptWord('AS')
            ? _identifier()
            : _acceptAlias(_peek.text)
            ? _identifier()
            : joinedAlias;
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
          tableFunction: joinedFunction,
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
    final namedWindows = <String, _WindowSpec>{};
    if (_acceptWord('WINDOW')) {
      do {
        final name = _identifier();
        _expectWord('AS');
        _expect('(');
        final spec = _windowSpecification();
        _expect(')');
        if (namedWindows.containsKey(_key(name))) {
          throw PureSqlException('duplicate window name: $name');
        }
        namedWindows[_key(name)] = _resolveWindowSpec(spec, namedWindows);
      } while (_accept(','));
    }
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
      tableFunction: tableFunction,
      namedWindows: namedWindows,
      startToken: startToken,
      endToken: _index,
    );
  }

  _TableFunction? _parseTableFunction(String name) {
    if (!_accept('(')) return null;
    final separator = name.indexOf('\u0000');
    final schema = separator < 0 ? null : name.substring(0, separator);
    final normalized = (separator < 0 ? name : name.substring(separator + 1))
        .toLowerCase();
    if (!const {
          'json_each',
          'json_tree',
          'jsonb_each',
          'jsonb_tree',
        }.contains(normalized) &&
        !(normalized.startsWith('pragma_') &&
            _pragmaTableFunctionColumns.containsKey(
              normalized.substring('pragma_'.length),
            ))) {
      throw PureSqlException('unsupported table-valued function: $name');
    }
    if (schema != null && !normalized.startsWith('pragma_')) {
      throw PureSqlException('unsupported table-valued function: $name');
    }
    final arguments = <_Expr>[];
    if (!_accept(')')) {
      arguments.add(_expression());
      while (_accept(',')) {
        arguments.add(_expression());
      }
      _expect(')');
    }
    return _TableFunction(normalized, arguments, schema: schema);
  }

  bool _acceptAlias(String word) =>
      _peek.type == _TokenType.word &&
      (_peek.quoted ||
          !const [
            'WHERE',
            'ORDER',
            'LIMIT',
            'GROUP',
            'HAVING',
            'WINDOW',
            'UNION',
            'INTERSECT',
            'EXCEPT',
            'JOIN',
            'LEFT',
            'RIGHT',
            'FULL',
            'INNER',
            'CROSS',
            'NATURAL',
            'USING',
            'ON',
            'RETURNING',
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
    final table = _tableReference();
    _expectWord('SET');
    final assignments = <_UpdateAssignment>[];
    do {
      final columns = <String>[];
      if (_accept('(')) {
        columns.add(_identifier());
        while (_accept(',')) {
          columns.add(_identifier());
        }
        _expect(')');
        if (columns.length < 2) {
          throw PureSqlException('row assignment requires multiple columns');
        }
      } else {
        columns.add(_identifier());
      }
      _expect('=');
      assignments.add(_UpdateAssignment(columns, _expression()));
    } while (_accept(','));
    final where = _acceptWord('WHERE') ? _expression() : null;
    return _Update(
      table,
      assignments,
      where,
      conflict: conflict,
      returning: _returningItems(),
    );
  }

  _Statement _delete() {
    _expectWord('DELETE');
    _expectWord('FROM');
    final table = _tableReference();
    final where = _acceptWord('WHERE') ? _expression() : null;
    return _Delete(table, where, returning: _returningItems());
  }

  List<_SelectItem>? _returningItems() {
    if (!_acceptWord('RETURNING')) return null;
    final items = <_SelectItem>[];
    do {
      if (_accept('*')) {
        items.add(_SelectItem(_Column('*'), '*'));
      } else {
        final expression = _expression();
        final explicitAlias = _acceptWord('AS');
        final name = explicitAlias
            ? _identifier()
            : expression is _Column
            ? expression.name
            : 'column${items.length + 1}';
        items.add(_SelectItem(expression, name, explicitAlias: explicitAlias));
      }
    } while (_accept(','));
    return items;
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
      } else if (_acceptWord('MATCH')) {
        result = _patternMatch(result, 'MATCH', true);
      } else {
        throw PureSqlException(
          'expected IN, BETWEEN, LIKE, GLOB, REGEXP, or MATCH',
        );
      }
    } else if (_acceptWord('IN')) {
      result = _inExpression(result, false);
    } else if (_acceptWord('LIKE')) {
      result = _patternMatch(result, 'LIKE', false);
    } else if (_acceptWord('GLOB')) {
      result = _patternMatch(result, 'GLOB', false);
    } else if (_acceptWord('REGEXP')) {
      result = _patternMatch(result, 'REGEXP', false);
    } else if (_acceptWord('MATCH')) {
      result = _patternMatch(result, 'MATCH', false);
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
    while (true) {
      final operator =
          _peek.type == _TokenType.symbol &&
              const ['||', '->', '->>'].contains(_peek.text)
          ? _advance().text
          : null;
      if (operator == null) break;
      result = _Binary(result, operator, _unary());
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
      if (_accept(',')) {
        final values = <_Expr>[result, _expression()];
        while (_accept(',')) {
          values.add(_expression());
        }
        _expect(')');
        return _RowValue(values);
      }
      _expect(')');
      return result;
    }
    final token = _advance();
    if (token.type == _TokenType.parameter) {
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
        _positionalParameters.add(index);
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
      if (word == 'X' &&
          _peek.type == _TokenType.string &&
          _peek.start == token.end) {
        final hex = _advance().value! as String;
        if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
          throw PureSqlException('invalid blob literal');
        }
        return _Literal([
          for (var index = 0; index < hex.length; index += 2)
            int.parse(hex.substring(index, index + 2), radix: 16),
        ]);
      }
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
      if (const {
            'CURRENT_DATE',
            'CURRENT_TIME',
            'CURRENT_TIMESTAMP',
          }.contains(word) &&
          _peek.text != '(') {
        return _Function(word, const []);
      }
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
      if (word == 'RAISE') {
        _sawRaise = true;
        _expect('(');
        if (_acceptWord('IGNORE')) {
          _expect(')');
          return _Function('RAISE', [_Literal('IGNORE')]);
        }
        final action = _acceptWord('ROLLBACK')
            ? 'ROLLBACK'
            : _acceptWord('ABORT')
            ? 'ABORT'
            : _acceptWord('FAIL')
            ? 'FAIL'
            : throw PureSqlException(
                'RAISE requires IGNORE, ROLLBACK, ABORT, or FAIL',
              );
        _expect(',');
        final message = _expression();
        _expect(')');
        return _Function('RAISE', [_Literal(action), message]);
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
        _Expr? filter;
        if (_acceptWord('FILTER')) {
          _expect('(');
          _expectWord('WHERE');
          filter = _expression();
          _expect(')');
        }
        final function = _Function(
          token.text,
          arguments,
          distinct: distinct,
          filter: filter,
        );
        return _acceptWord('OVER') ? _windowFunction(function) : function;
      }
      if (_accept('.')) {
        final second = _accept('*') ? '*' : _identifier();
        if (second == '*') return _Column('${token.text}.*');
        if (_accept('.')) {
          final column = _accept('*') ? '*' : _identifier();
          return _Column(column == '*' ? '$second.*' : '$second.$column');
        }
        return _Column('${token.text}.$second');
      }
      return _Column(token.text);
    }
    throw PureSqlException('expected expression, got ${token.text}');
  }

  _WindowFunction _windowFunction(_Function function) {
    if (function.distinct) {
      throw PureSqlException('DISTINCT is not allowed in window functions');
    }
    final id = _nextWindowFunctionId++;
    if (!_accept('(')) {
      return _WindowFunction(
        id,
        function,
        const [],
        const [],
        windowName: _identifier(),
      );
    }
    final spec = _windowSpecification();
    _expect(')');
    return _WindowFunction(
      id,
      function,
      spec.partitionBy,
      spec.orderBy,
      frame: spec.frame,
      windowSpec: spec,
    );
  }

  _WindowSpec _windowSpecification() {
    String? baseName;
    if (_peek.type == _TokenType.word &&
        (_peek.quoted ||
            !const [
              'PARTITION',
              'ORDER',
              'ROWS',
              'GROUPS',
              'RANGE',
              'EXCLUDE',
            ].contains(_word))) {
      baseName = _identifier();
    }
    final partitionBy = <_Expr>[];
    if (_acceptWord('PARTITION')) {
      _expectWord('BY');
      partitionBy.add(_expression());
      while (_accept(',')) {
        partitionBy.add(_expression());
      }
    }
    final orderBy = <_Order>[];
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
        bool? nullsFirst;
        if (_acceptWord('NULLS')) {
          nullsFirst = _acceptWord('FIRST')
              ? true
              : _acceptWord('LAST')
              ? false
              : throw PureSqlException('expected FIRST or LAST after NULLS');
        }
        orderBy.add(
          _Order(expression, descending, noCase, nullsFirst: nullsFirst),
        );
      } while (_accept(','));
    }
    _WindowFrame? frame;
    String? frameType;
    if (_acceptWord('ROWS')) {
      frameType = 'ROWS';
    } else if (_acceptWord('GROUPS')) {
      frameType = 'GROUPS';
    } else if (_acceptWord('RANGE')) {
      frameType = 'RANGE';
    }
    if (frameType != null) {
      final hasBetween = _acceptWord('BETWEEN');
      final start = _windowFrameBound();
      final end = hasBetween
          ? _advanceFrameEnd()
          : const _WindowFrameBound.current();
      if (start.kind == 'unboundedFollowing' ||
          end.kind == 'unboundedPreceding' ||
          start.kind == 'following' &&
              const {'preceding', 'current'}.contains(end.kind) ||
          start.kind == 'current' && end.kind == 'preceding') {
        throw PureSqlException('invalid $frameType frame boundary');
      }
      if (frameType == 'RANGE' &&
          [
            start.offset,
            end.offset,
          ].whereType<_Expr>().any((offset) => !_constantRangeOffset(offset))) {
        throw PureSqlException(
          'RANGE offsets must be constant numeric expressions',
        );
      }
      frame = _WindowFrame(frameType, start, end);
    }
    var exclude = 'noOthers';
    if (_acceptWord('EXCLUDE')) {
      if (frame == null) {
        throw PureSqlException('EXCLUDE requires a window frame');
      }
      if (_acceptWord('CURRENT')) {
        _expectWord('ROW');
        exclude = 'currentRow';
      } else if (_acceptWord('GROUP')) {
        exclude = 'group';
      } else if (_acceptWord('TIES')) {
        exclude = 'ties';
      } else {
        _expectWord('NO');
        _expectWord('OTHERS');
      }
      frame = _WindowFrame(
        frame.type,
        frame.start,
        frame.end,
        exclude: exclude,
      );
    }
    if (_peek.type == _TokenType.word) {
      throw PureSqlException(
        'unexpected token in window specification: ${_peek.text}',
      );
    }
    return _WindowSpec(partitionBy, orderBy, frame, baseName: baseName);
  }

  _WindowFrameBound _advanceFrameEnd() {
    _expectWord('AND');
    return _windowFrameBound();
  }

  _WindowFrameBound _windowFrameBound() {
    if (_acceptWord('UNBOUNDED')) {
      if (_acceptWord('PRECEDING')) {
        return const _WindowFrameBound.unboundedPreceding();
      }
      _expectWord('FOLLOWING');
      return const _WindowFrameBound.unboundedFollowing();
    }
    if (_acceptWord('CURRENT')) {
      _expectWord('ROW');
      return const _WindowFrameBound.current();
    }
    final offset = _expression();
    if (_acceptWord('PRECEDING')) {
      return _WindowFrameBound('preceding', offset);
    }
    _expectWord('FOLLOWING');
    return _WindowFrameBound('following', offset);
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

  String _tableReference() {
    final name = _identifier();
    if (!_accept('.')) return name;
    return '$name\u0000${_identifier()}';
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
