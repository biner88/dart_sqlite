import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_sqlite/dart_sqlite.dart';

Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == '--hold-write') {
    final database = PureDatabase.open(args[1]);
    database.execute('BEGIN IMMEDIATE');
    database.execute("UPDATE lock_probe SET value = 'committed'");
    stdout.writeln('READY');
    stdin.readLineSync();
    database.execute('COMMIT');
    database.close();
    return;
  }

  final directory = Directory.systemTemp.createTempSync('dart_sqlite_db_');
  final path = '${directory.path}/data.sqlite';

  final database = PureDatabase.open(path);
  final parallelOpen = PureDatabase.open(path);
  assert(
    parallelOpen.select('PRAGMA user_version').single['user_version'] == 0,
  );
  parallelOpen.close();
  assert(database.select('PRAGMA user_version').single['user_version'] == 0);
  database.execute('PRAGMA user_version = 7');
  database.execute('PRAGMA application_id = 1234');
  database.execute('PRAGMA schema_version = 40');
  assert(database.select('PRAGMA user_version').single['user_version'] == 7);
  assert(
    database.select('PRAGMA schema_version').single['schema_version'] == 40,
  );
  database.execute('CREATE TABLE folders (id TEXT PRIMARY KEY)');
  assert(
    database.select('PRAGMA schema_version').single['schema_version'] == 41,
  );
  database.execute(
    'CREATE TABLE files (id TEXT PRIMARY KEY, folder_id TEXT NOT NULL REFERENCES folders(id))',
  );
  database.execute('PRAGMA foreign_keys = ON');
  database.execute('INSERT INTO folders VALUES (?)', ['folder']);
  database.execute('INSERT INTO files VALUES (?, ?)', ['file', 'folder']);
  database.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
  database.execute('''
    CREATE TABLE composite_parent (
      a TEXT,
      b TEXT,
      PRIMARY KEY (a, b)
    )
  ''');
  database.execute('''
    CREATE TABLE composite_child (
      a TEXT,
      b TEXT,
      FOREIGN KEY (a, b) REFERENCES composite_parent (a, b)
    )
  ''');
  database.execute("INSERT INTO composite_parent VALUES ('a', 'b')");
  database.execute("INSERT INTO composite_child VALUES ('a', 'b')");
  database.execute('''
    CREATE TABLE before_rename (id INTEGER PRIMARY KEY, value TEXT UNIQUE)
  ''');
  database.execute('''
    CREATE TABLE rename_reference (
      parent_id INTEGER REFERENCES before_rename(id) ON UPDATE CASCADE
    )
  ''');
  database.execute(
    'CREATE INDEX before_rename_value_idx ON before_rename(value)',
  );
  database.execute('''
    CREATE VIEW renamed_view AS
      SELECT 'FROM before_rename' AS marker, value FROM before_rename
  ''');
  database.execute("INSERT INTO before_rename VALUES (1, 'kept')");
  database.execute('INSERT INTO rename_reference VALUES (1)');
  database.execute('ALTER TABLE before_rename RENAME TO after_rename');
  database.execute('UPDATE after_rename SET id = 2 WHERE id = 1');
  database.execute(
    'CREATE TABLE persistent_column_rename (id INTEGER PRIMARY KEY, old_name TEXT)',
  );
  database.execute(
    "INSERT INTO persistent_column_rename VALUES (1, 'survives reopen')",
  );
  database.execute(
    'ALTER TABLE persistent_column_rename RENAME COLUMN old_name TO new_name',
  );
  database.execute(
    'CREATE TABLE persistent_drop_column (id INTEGER PRIMARY KEY, remove_me TEXT, keep TEXT)',
  );
  database.execute(
    "INSERT INTO persistent_drop_column VALUES (1, 'gone', 'kept')",
  );
  database.execute('ALTER TABLE persistent_drop_column DROP COLUMN remove_me');
  database.execute(
    'CREATE TABLE persistent_update_fail (id INTEGER PRIMARY KEY, value TEXT UNIQUE)',
  );
  database.execute(
    "INSERT INTO persistent_update_fail VALUES (1, 'one'), (2, 'two')",
  );
  try {
    database.execute('''
      UPDATE OR FAIL persistent_update_fail
      SET value = 'changed'
    ''');
    assert(false, 'persistent UPDATE OR FAIL should fail');
  } on PureSqlException {
    // Expected; the first row is committed despite the statement error.
  }
  database.execute(
    'CREATE TABLE persistent_rollback_conflict (id INTEGER PRIMARY KEY, value TEXT UNIQUE)',
  );
  database.execute(
    "INSERT INTO persistent_rollback_conflict VALUES (1, 'one')",
  );
  database.execute('BEGIN');
  database.execute(
    "INSERT INTO persistent_rollback_conflict VALUES (2, 'two')",
  );
  try {
    database.execute(
      "UPDATE OR ROLLBACK persistent_rollback_conflict SET value = 'one' WHERE id = 2",
    );
    assert(false, 'persistent UPDATE OR ROLLBACK should fail');
  } on PureSqlException {
    // Expected; the active transaction is rolled back.
  }
  assert(
    database.select('SELECT id FROM persistent_rollback_conflict').length == 1,
  );
  database.execute('''
    CREATE TABLE upsert_parent (id INTEGER PRIMARY KEY, token TEXT UNIQUE)
  ''');
  database.execute('''
    CREATE TABLE upsert_child (
      parent_id INTEGER REFERENCES upsert_parent(id)
        ON UPDATE CASCADE ON DELETE CASCADE
    )
  ''');
  database.execute("INSERT INTO upsert_parent VALUES (1, 'token')");
  database.execute('INSERT INTO upsert_child VALUES (1)');
  database.execute('''
    INSERT INTO upsert_parent VALUES (2, 'token')
    ON CONFLICT(token) DO UPDATE SET id = excluded.id
  ''');
  assert(
    database.select('SELECT parent_id FROM upsert_child').single['parent_id'] ==
        2,
  );
  database.execute('INSERT INTO users VALUES (?, ?)', [1, 'Alice']);
  database.execute('INSERT INTO users VALUES (?, ?)', [2, 'Bob']);
  for (var id = 3; id <= 160; id++) {
    database.execute('INSERT INTO users VALUES (?, ?)', [
      id,
      'user-$id-${'x' * 80}',
    ]);
  }
  database.execute('UPDATE users SET name = ? WHERE id = ?', [
    'Alice-updated',
    1,
  ]);
  database.execute('DELETE FROM users WHERE id = ?', [2]);
  database.execute('INSERT INTO users VALUES (?, ?)', [2, 'Bob-restored']);
  database.execute('CREATE TABLE compact (id INTEGER PRIMARY KEY, value TEXT)');
  for (var id = 1; id <= 100; id++) {
    database.execute('INSERT INTO compact VALUES (?, ?)', [id, 'v${'x' * 80}']);
  }
  for (var id = 2; id <= 100; id++) {
    database.execute('DELETE FROM compact WHERE id = ?', [id]);
  }
  database.execute(
    'CREATE TABLE large_rows (id INTEGER PRIMARY KEY, payload TEXT)',
  );
  database.execute('INSERT INTO large_rows VALUES (?, ?)', [1, 'z' * 12000]);
  database.execute(
    'CREATE TABLE dropped_rows (id INTEGER PRIMARY KEY, payload TEXT)',
  );
  database.execute('CREATE INDEX dropped_rows_id_idx ON dropped_rows(id)');
  database.execute('INSERT INTO dropped_rows VALUES (?, ?)', [1, 'q' * 12000]);
  database.execute('DROP INDEX dropped_rows_id_idx');
  database.execute('DROP TABLE dropped_rows');
  assert(
    (database.select('PRAGMA freelist_count').single['freelist_count'] as int) >
        0,
  );
  database.execute('DROP TABLE IF EXISTS absent_table');
  database.execute('CREATE INDEX users_name_idx ON users(name)');
  database.execute('ALTER TABLE users ADD COLUMN active INTEGER');
  assert(
    database.select('SELECT active FROM users WHERE id = 1').single['active'] ==
        null,
  );
  database.execute(
    "ALTER TABLE users ADD COLUMN state TEXT NOT NULL DEFAULT 'new'",
  );
  assert(
    database.select('SELECT state FROM users WHERE id = 1').single['state'] ==
        'new',
  );
  database.execute('''
    CREATE VIEW first_users(user_id, display_name) AS
      SELECT id, name FROM users WHERE id < 3
  ''');
  final expectedSchemaVersion = database
      .select('PRAGMA schema_version')
      .single['schema_version'];
  database.close();

  final reopened = PureDatabase.open(path);
  assert(reopened.select('PRAGMA user_version').single['user_version'] == 7);
  assert(
    reopened.select('PRAGMA schema_version').single['schema_version'] ==
        expectedSchemaVersion,
  );
  assert(
    reopened.select('PRAGMA application_id').single['application_id'] == 1234,
  );
  assert(
    reopened.select('PRAGMA foreign_key_list(composite_child)').length == 2,
  );
  assert(reopened.select('SELECT * FROM composite_child').length == 1);
  assert(
    reopened
            .select('SELECT marker, value FROM renamed_view')
            .single['marker'] ==
        'FROM before_rename',
  );
  assert(
    reopened
            .select('PRAGMA foreign_key_list(rename_reference)')
            .single['table'] ==
        'after_rename',
  );
  assert(
    reopened
        .select('PRAGMA index_list(after_rename)')
        .any((row) => row['name'] == 'before_rename_value_idx'),
  );
  assert(
    reopened
            .select('SELECT parent_id FROM rename_reference')
            .single['parent_id'] ==
        2,
  );
  assert(
    reopened
            .select('SELECT new_name FROM persistent_column_rename')
            .single['new_name'] ==
        'survives reopen',
  );
  assert(
    reopened.select('SELECT keep FROM persistent_drop_column').single['keep'] ==
        'kept',
  );
  assert(
    reopened
            .select('SELECT value FROM persistent_update_fail WHERE id = 1')
            .single['value'] ==
        'changed',
  );
  assert(
    reopened
            .select('SELECT value FROM persistent_update_fail WHERE id = 2')
            .single['value'] ==
        'two',
  );
  assert(
    reopened.select('SELECT id FROM persistent_rollback_conflict').length == 1,
  );
  assert(reopened.select('SELECT id FROM upsert_parent').single['id'] == 2);
  assert(
    reopened.select('SELECT parent_id FROM upsert_child').single['parent_id'] ==
        2,
  );
  reopened.execute('PRAGMA foreign_keys = ON');
  reopened.execute('DELETE FROM upsert_parent WHERE id = 2');
  assert(reopened.select('SELECT * FROM upsert_child').isEmpty);
  assert(reopened.select('SELECT * FROM first_users').length == 2);
  reopened.execute('DROP VIEW first_users');
  assert(reopened.select('SELECT id FROM files').single['id'] == 'file');
  final rows = reopened.select(
    'SELECT id, name, active, state FROM users ORDER BY id',
  );
  assert(rows.length == 160);
  assert(rows[0]['name'] == 'Alice-updated');
  assert(rows[1]['name'] == 'Bob-restored');
  assert(rows.last['id'] == 160);
  assert(rows.first['active'] == null);
  assert(rows.first['state'] == 'new');
  final indexed = reopened.select('SELECT id FROM users WHERE name = ?', [
    'user-160-${'x' * 80}',
  ]);
  assert(indexed.single['id'] == 160);
  assert(reopened.select('SELECT id FROM compact').single['id'] == 1);
  assert(
    (reopened.select('SELECT payload FROM large_rows').single['payload']
                as String)
            .length ==
        12000,
  );

  try {
    reopened.transaction((database) {
      database.execute('INSERT INTO users (id, name) VALUES (?, ?)', [
        999,
        'rolled back',
      ]);
      throw StateError('rollback');
    });
  } on StateError {
    // Expected.
  }
  assert(reopened.select('SELECT id FROM users WHERE id = 999').isEmpty);
  reopened.transaction((database) {
    database.execute('INSERT INTO users (id, name) VALUES (?, ?)', [
      999,
      'committed',
    ]);
  });
  assert(reopened.select('SELECT id FROM users WHERE id = 999').length == 1);
  reopened.execute('BEGIN IMMEDIATE');
  reopened.execute('INSERT INTO users (id, name) VALUES (?, ?)', [
    1000,
    'explicit-commit',
  ]);
  reopened.execute('COMMIT');
  assert(reopened.select('SELECT id FROM users WHERE id = 1000').length == 1);
  reopened.execute('BEGIN');
  reopened.execute('INSERT INTO users (id, name) VALUES (?, ?)', [
    1001,
    'explicit-rollback',
  ]);
  reopened.execute('ROLLBACK');
  assert(reopened.select('SELECT id FROM users WHERE id = 1001').isEmpty);
  reopened.close();

  final journal = SqliteRollbackJournal.begin(path);
  File(path).writeAsBytesSync(Uint8List(File(path).lengthSync()));
  journal.rollback(path);
  final recovered = PureDatabase.open(path);
  assert(recovered.select('SELECT id FROM users WHERE id = 999').length == 1);
  recovered.close();
  final droppedSchemaCheck = Process.runSync('sqlite3', [
    path,
    'PRAGMA integrity_check;',
  ]);
  assert(droppedSchemaCheck.exitCode == 0, droppedSchemaCheck.stderr);
  assert(droppedSchemaCheck.stdout.trim() == 'ok');

  final crashPath = '${directory.path}/native-journal.sqlite';
  PureDatabase.open(crashPath)
    ..execute('CREATE TABLE journal_probe (value TEXT)')
    ..execute("INSERT INTO journal_probe VALUES ('before')")
    ..close();
  final interrupted = PureDatabase.open(crashPath)
    ..execute('BEGIN IMMEDIATE')
    ..execute("UPDATE journal_probe SET value = 'after'");
  final nativeJournal = File('$crashPath-journal');
  assert(nativeJournal.existsSync(), 'transaction must create SQLite journal');
  final journalBytes = nativeJournal.readAsBytesSync();
  assert(
    journalBytes.take(8).join(',') == '217,213,5,249,32,161,99,215',
    'journal must use the SQLite rollback-journal header',
  );
  interrupted.close(); // Simulate process exit before COMMIT.
  final sqliteCheck = Process.runSync('sqlite3', [
    crashPath,
    'PRAGMA integrity_check; SELECT value FROM journal_probe;',
  ]);
  assert(sqliteCheck.exitCode == 0, sqliteCheck.stderr);
  assert(sqliteCheck.stdout.trim() == 'ok\nbefore', sqliteCheck.stdout);
  assert(!nativeJournal.existsSync(), 'SQLite should remove a hot journal');

  final lockPath = '${directory.path}/connections.sqlite';
  PureDatabase.open(lockPath)
    ..execute('CREATE TABLE lock_probe (value TEXT)')
    ..execute("INSERT INTO lock_probe VALUES ('before')")
    ..close();
  final secondConnection = PureDatabase.open(
    lockPath,
    busyTimeout: const Duration(milliseconds: 120),
  );
  final holder = await Process.start(Platform.resolvedExecutable, [
    Platform.script.toFilePath(),
    '--hold-write',
    lockPath,
  ]);
  try {
    final ready = await holder.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 5));
    assert(ready == 'READY');
    final stopwatch = Stopwatch()..start();
    var busy = false;
    try {
      secondConnection.select('SELECT value FROM lock_probe');
    } on SqliteFormatException {
      busy = true;
    }
    stopwatch.stop();
    assert(busy, 'a competing reader must observe the active write lock');
    assert(stopwatch.elapsed >= const Duration(milliseconds: 100));
    holder.stdin.writeln('commit');
    assert(await holder.exitCode == 0);
    assert(
      secondConnection.select('SELECT value FROM lock_probe').single['value'] ==
          'committed',
      'a second connection must refresh after another connection commits',
    );

    final sqliteReader = await Process.start('sqlite3', ['-batch', lockPath]);
    try {
      sqliteReader.stdin
        ..writeln('BEGIN;')
        ..writeln('SELECT value FROM lock_probe;');
      await sqliteReader.stdin.flush();
      final readerValue = await sqliteReader.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      assert(readerValue == 'committed');
      assert(
        secondConnection
                .select('SELECT value FROM lock_probe')
                .single['value'] ==
            'committed',
        'SQLite shared locks must coexist with PureDatabase readers',
      );
      var writerBusy = false;
      try {
        secondConnection.execute(
          "UPDATE lock_probe SET value = 'must-not-write'",
        );
      } on SqliteFormatException {
        writerBusy = true;
      }
      assert(writerBusy, 'an SQLite reader must block PureDatabase writers');
      sqliteReader.stdin
        ..writeln('ROLLBACK;')
        ..writeln('.quit');
      await sqliteReader.stdin.close();
      assert(await sqliteReader.exitCode == 0);
    } finally {
      sqliteReader.kill();
      await sqliteReader.exitCode;
    }

    final sqliteWriter = await Process.start('sqlite3', ['-batch', lockPath]);
    try {
      sqliteWriter.stdin
        ..writeln('BEGIN IMMEDIATE;')
        ..writeln('SELECT value FROM lock_probe;');
      await sqliteWriter.stdin.flush();
      final writerValue = await sqliteWriter.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      assert(writerValue == 'committed');
      assert(
        secondConnection
                .select('SELECT value FROM lock_probe')
                .single['value'] ==
            'committed',
        'SQLite RESERVED locks must allow PureDatabase readers',
      );
      var reservedBusy = false;
      try {
        secondConnection.execute(
          "UPDATE lock_probe SET value = 'must-not-write'",
        );
      } on SqliteFormatException {
        reservedBusy = true;
      }
      assert(
        reservedBusy,
        'SQLite RESERVED locks must block PureDatabase writers',
      );
      sqliteWriter.stdin
        ..writeln('ROLLBACK;')
        ..writeln('.quit');
      await sqliteWriter.stdin.close();
      assert(await sqliteWriter.exitCode == 0);
    } finally {
      sqliteWriter.kill();
      await sqliteWriter.exitCode;
    }

    final sqliteHolder = await Process.start('sqlite3', ['-batch', lockPath]);
    try {
      sqliteHolder.stdin
        ..writeln('BEGIN EXCLUSIVE;')
        ..writeln('SELECT 1;');
      await sqliteHolder.stdin.flush();
      final sqliteReady = await sqliteHolder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      assert(sqliteReady == '1');
      var sqliteBusy = false;
      try {
        secondConnection.select('SELECT value FROM lock_probe');
      } on SqliteFormatException {
        sqliteBusy = true;
      }
      assert(sqliteBusy, 'PureDatabase must respect SQLite exclusive locks');
      sqliteHolder.stdin
        ..writeln('ROLLBACK;')
        ..writeln('.quit');
      await sqliteHolder.stdin.close();
      assert(await sqliteHolder.exitCode == 0);
    } finally {
      sqliteHolder.kill();
      await sqliteHolder.exitCode;
    }
  } finally {
    holder.kill();
    secondConnection.close();
  }

  if (Platform.environment['KEEP_SQLITE_FILE'] == '1') {
    print(path);
  } else {
    directory.deleteSync(recursive: true);
  }
}
