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
  assert(database.select('PRAGMA user_version').single['user_version'] == 7);
  database.execute('CREATE TABLE folders (id TEXT PRIMARY KEY)');
  database.execute(
    'CREATE TABLE files (id TEXT PRIMARY KEY, folder_id TEXT NOT NULL REFERENCES folders(id))',
  );
  database.execute('PRAGMA foreign_keys = ON');
  database.execute('INSERT INTO folders VALUES (?)', ['folder']);
  database.execute('INSERT INTO files VALUES (?, ?)', ['file', 'folder']);
  database.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
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
  database.close();

  final reopened = PureDatabase.open(path);
  assert(reopened.select('PRAGMA user_version').single['user_version'] == 7);
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
