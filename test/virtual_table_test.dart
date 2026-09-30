import 'dart:io';

import 'package:dart_sqlite/dart_sqlite.dart';

class _Store {
  List<SqlVirtualTableRow> rows = [];
  var creates = 0;
  var connects = 0;
  var disconnects = 0;
  var destroys = 0;
}

class _RowsModule extends SqlVirtualTable {
  _RowsModule(this.store);

  final _Store store;

  @override
  List<String> get columns => const ['key', 'value'];

  @override
  Iterable<SqlVirtualTableRow> scan() => [
    for (final row in store.rows)
      SqlVirtualTableRow(row.rowId, Map<String, Object?>.from(row.values)),
  ];

  @override
  void replaceRows(List<SqlVirtualTableRow> rows) {
    store.rows = [
      for (final row in rows)
        SqlVirtualTableRow(row.rowId, Map<String, Object?>.from(row.values)),
    ];
  }

  @override
  void disconnect() => store.disconnects++;

  @override
  void destroy() => store.destroys++;
}

SqlVirtualTableModule _moduleFor(_Store store) =>
    (database, schema, tableName, arguments, {required create}) {
      assert(schema == 'main');
      assert(tableName == 'item_rows');
      assert(arguments.length == 2);
      assert(arguments[0] == "'source,one'");
      assert(arguments[1] == 'nested(1, 2)');
      if (create) {
        store.creates++;
      } else {
        store.connects++;
      }
      return _RowsModule(store);
    };

void main() {
  final store = _Store()
    ..rows = [
      const SqlVirtualTableRow(10, {'key': 'a', 'value': 'one'}),
      const SqlVirtualTableRow(20, {'key': 'b', 'value': 'two'}),
    ];
  final database = PureDatabase.memory()
    ..registerVirtualTableModule('rows', _moduleFor(store))
    ..execute(
      "CREATE VIRTUAL TABLE item_rows USING rows('source,one', nested(1, 2))",
    );

  assert(store.creates == 1);
  assert(
    database
            .select('SELECT rowid, key, value FROM item_rows ORDER BY rowid')
            .map((row) => row['rowid'])
            .join(',') ==
        '10,20',
  );
  assert(database.select('PRAGMA table_info(item_rows)').length == 2);
  assert(
    database.select('PRAGMA table_list(item_rows)').single['type'] == 'virtual',
  );
  assert(
    database.select('PRAGMA module_list').any((row) => row['name'] == 'rows'),
  );

  database.execute("INSERT INTO item_rows VALUES ('c', 'three')");
  assert(
    database
            .select('SELECT rowid FROM item_rows WHERE key = \'c\'')
            .single['rowid'] ==
        1,
  );
  final insertedWithRowId = database.select(
    "INSERT INTO item_rows(rowid, key, value) "
    "VALUES (-7, 'explicit', 'rowid') RETURNING rowid",
  );
  assert(insertedWithRowId.single['rowid'] == -7);
  final updatedWithRowId = database.select(
    "UPDATE item_rows SET _rowid_ = 0 WHERE key = 'explicit' "
    'RETURNING oid',
  );
  assert(updatedWithRowId.single['oid'] == 0);
  assert(
    database
            .select("SELECT rowid FROM item_rows WHERE key = 'explicit'")
            .single['rowid'] ==
        0,
  );
  final beforeDuplicateRowId = store.rows.length;
  try {
    database.execute(
      "INSERT INTO item_rows(rowid, key) VALUES (0, 'duplicate')",
    );
    assert(false, 'virtual-table rowids must be unique');
  } on SqliteException {
    // Expected.
  }
  assert(store.rows.length == beforeDuplicateRowId);
  database.execute("UPDATE item_rows SET value = 'changed' WHERE key = 'b'");
  assert(
    database
            .select("SELECT value FROM item_rows WHERE key = 'b'")
            .single['value'] ==
        'changed',
  );
  database.execute("DELETE FROM item_rows WHERE key = 'a'");
  database.execute("DELETE FROM item_rows WHERE key = 'explicit'");
  assert(database.select('SELECT key FROM item_rows').length == 2);

  final beforeRollback = store.rows.length;
  try {
    database.transaction((database) {
      database.execute("INSERT INTO item_rows VALUES ('d', 'rollback')");
      throw StateError('rollback virtual-table write');
    });
  } on StateError {
    // Expected.
  }
  assert(store.rows.length == beforeRollback);
  database.execute('SAVEPOINT virtual_rows');
  database.execute("INSERT INTO item_rows VALUES ('e', 'savepoint')");
  database.execute('ROLLBACK TO virtual_rows');
  database.execute('RELEASE virtual_rows');
  assert(store.rows.length == beforeRollback);

  database.execute('CREATE VIRTUAL TABLE IF NOT EXISTS item_rows USING rows');
  assert(store.creates == 1);
  try {
    database.execute('CREATE INDEX item_rows_key ON item_rows(key)');
    assert(false, 'virtual-table indexes are not supported');
  } on SqliteException {
    // Expected.
  }
  try {
    database.execute('ALTER TABLE item_rows ADD COLUMN extra');
    assert(false, 'virtual-table ALTER TABLE is not supported');
  } on SqliteException {
    // Expected.
  }
  database.execute('SAVEPOINT virtual_table_drop');
  database.execute('DROP TABLE item_rows');
  database.execute('ROLLBACK TO virtual_table_drop');
  database.execute('RELEASE virtual_table_drop');
  assert(
    database.select('SELECT count(*) AS n FROM item_rows').single['n'] == 2,
  );
  assert(store.destroys == 0);
  database.execute('DROP TABLE item_rows');
  assert(store.destroys == 1);
  database.close();

  final directory = Directory.systemTemp.createTempSync('dart_sqlite_vtab_');
  final path = '${directory.path}/virtual.sqlite';
  final persistentStore = _Store()
    ..rows = [
      const SqlVirtualTableRow(7, {'key': 'persisted', 'value': 'ok'}),
    ];
  final modules = {'rows': _moduleFor(persistentStore)};
  try {
    final created = PureDatabase.open(path, virtualTableModules: modules)
      ..execute(
        "CREATE VIRTUAL TABLE item_rows USING rows('source,one', nested(1, 2))",
      )
      ..execute("INSERT INTO item_rows VALUES ('saved', 'yes')");
    created.close();

    final reopened = PureDatabase.open(path, virtualTableModules: modules);
    assert(persistentStore.connects == 1);
    assert(
      reopened
              .select("SELECT value FROM item_rows WHERE key = 'saved'")
              .single['value'] ==
          'yes',
    );
    reopened.execute('VACUUM');
    reopened.execute(
      "UPDATE item_rows SET rowid = -12, value = 'again' WHERE key = 'saved'",
    );
    assert(
      persistentStore.rows.any(
        (row) =>
            row.rowId == -12 &&
            row.values['key'] == 'saved' &&
            row.values['value'] == 'again',
      ),
    );
    assert(
      reopened
              .select("SELECT rowid FROM item_rows WHERE key = 'saved'")
              .single['rowid'] ==
          -12,
    );
    final persistentRowCount = persistentStore.rows.length;
    try {
      reopened.transaction((database) {
        database.execute("INSERT INTO item_rows VALUES ('rolled', 'back')");
        throw StateError('rollback persistent virtual-table write');
      });
    } on StateError {
      // Expected.
    }
    assert(persistentStore.rows.length == persistentRowCount);
    try {
      reopened.transaction((database) {
        database.execute('DROP TABLE item_rows');
        throw StateError('rollback virtual-table drop');
      });
    } on StateError {
      // Expected.
    }
    assert(persistentStore.destroys == 0);
    assert(
      reopened.select('SELECT count(*) AS n FROM item_rows').single['n'] == 2,
    );
    reopened.close();

    final vacuumReopened = PureDatabase.open(
      path,
      virtualTableModules: modules,
    );
    assert(
      vacuumReopened
              .select("SELECT value FROM item_rows WHERE key = 'saved'")
              .single['value'] ==
          'again',
    );
    vacuumReopened.close();

    try {
      PureDatabase.open(path).close();
      assert(false, 'reopening needs its registered module');
    } on SqliteException {
      // Expected.
    }
    final dropped = PureDatabase.open(path, virtualTableModules: modules)
      ..execute('DROP TABLE item_rows');
    assert(persistentStore.destroys == 1);
    dropped.close();
    PureDatabase.open(path).close();
  } finally {
    directory.deleteSync(recursive: true);
  }
}
