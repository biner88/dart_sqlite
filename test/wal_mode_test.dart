import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_sqlite/dart_sqlite.dart';

Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == '--hold-write') {
    final db = PureDatabase.open(args[1]);
    db.execute('BEGIN IMMEDIATE');
    db.execute("UPDATE entries SET value = 'committed' WHERE id = 1");
    stdout.writeln('READY');
    stdin.readLineSync();
    db.execute('COMMIT');
    stdout.writeln('COMMITTED');
    stdin.readLineSync();
    db.close();
    return;
  }

  final directory = Directory.systemTemp.createTempSync('dart_sqlite_wal_');
  final path = '${directory.path}/data.sqlite';
  try {
    final setup = PureDatabase.open(path);
    assert(
      setup.select('PRAGMA journal_size_limit').single['journal_size_limit'] ==
          -1,
    );
    final journalLimitPeer = PureDatabase.open(path);
    journalLimitPeer.execute('PRAGMA journal_size_limit = 64');
    assert(
      setup.select('PRAGMA journal_size_limit').single['journal_size_limit'] ==
          -1,
    );
    journalLimitPeer.close();
    setup.execute('PRAGMA journal_size_limit = 64');
    assert(
      setup.select('PRAGMA journal_size_limit').single['journal_size_limit'] ==
          64,
    );
    assert(
      setup.select('PRAGMA wal_autocheckpoint').single['wal_autocheckpoint'] ==
          1000,
    );
    setup.execute('PRAGMA wal_autocheckpoint = 0');
    assert(
      setup.select('PRAGMA wal_autocheckpoint').single['wal_autocheckpoint'] ==
          0,
    );
    final checkpointSettingPeer = PureDatabase.open(path);
    assert(
      checkpointSettingPeer
              .select('PRAGMA wal_autocheckpoint')
              .single['wal_autocheckpoint'] ==
          1000,
    );
    checkpointSettingPeer.execute('PRAGMA wal_autocheckpoint = 8');
    assert(
      setup.select('PRAGMA wal_autocheckpoint').single['wal_autocheckpoint'] ==
          0,
    );
    checkpointSettingPeer.close();
    setup.execute('CREATE TABLE entries (id INTEGER PRIMARY KEY, value TEXT)');
    setup.execute("INSERT INTO entries VALUES (1, 'before')");
    final noWalCheckpoint = setup.select('PRAGMA wal_checkpoint(NOOP)').single;
    assert(noWalCheckpoint['busy'] == 0);
    assert(noWalCheckpoint['log'] == -1);
    assert(noWalCheckpoint['checkpointed'] == -1);
    assert(setup.select('PRAGMA wal_checkpoint(PASSIVE)').single['log'] == -1);
    setup.execute('PRAGMA journal_mode = WAL');
    assert(setup.select('PRAGMA journal_mode').single['journal_mode'] == 'wal');
    assert(File('$path-wal').lengthSync() == 32);
    final emptyTruncate = setup
        .select('PRAGMA wal_checkpoint(TRUNCATE)')
        .single;
    assert(emptyTruncate['busy'] == 0);
    assert(emptyTruncate['log'] == 0);
    assert(emptyTruncate['checkpointed'] == 0);
    assert(File('$path-wal').lengthSync() == 0);
    final walPageSize = setup.select('PRAGMA page_size').single['page_size'];
    setup.execute('PRAGMA page_size = 8192');
    assert(setup.select('PRAGMA page_size').single['page_size'] == walPageSize);
    assert(File('$path-wal').existsSync(), 'WAL file should be created');
    setup.execute('CREATE TABLE wal_raise_rows (value INTEGER)');
    setup.execute('''
      CREATE TRIGGER wal_raise_rows_ai AFTER INSERT ON wal_raise_rows
      WHEN NEW.value = 2
      BEGIN SELECT RAISE(ABORT, 'WAL statement aborted'); END
    ''');
    setup.execute(
      'CREATE TABLE large_entries (id INTEGER PRIMARY KEY, payload TEXT)',
    );
    setup.execute('INSERT INTO large_entries VALUES (1, ?)', ['x' * 12000]);
    final checkpoint = setup.select('PRAGMA wal_checkpoint(NOOP)').single;
    assert(checkpoint['busy'] == 0);
    assert((checkpoint['log'] as int) > 0);
    assert(checkpoint['checkpointed'] == 0);
    final passiveCheckpoint = setup
        .select('PRAGMA wal_checkpoint(PASSIVE)')
        .single;
    assert(passiveCheckpoint['busy'] == 0);
    assert((passiveCheckpoint['log'] as int) > 0);
    assert(passiveCheckpoint['checkpointed'] == passiveCheckpoint['log']);
    assert(setup.select('PRAGMA wal_checkpoint(NOOP)').single['log'] == 0);
    assert(File('$path-wal').lengthSync() <= 64);
    setup.execute('PRAGMA journal_size_limit = 0');
    setup.select('PRAGMA wal_checkpoint(PASSIVE)');
    assert(File('$path-wal').lengthSync() == 0);
    setup.execute('PRAGMA journal_size_limit = 64');
    final truncateCheckpoint = setup
        .select('PRAGMA wal_checkpoint(TRUNCATE)')
        .single;
    assert(truncateCheckpoint['busy'] == 0);
    assert(truncateCheckpoint['log'] == 0);
    assert(truncateCheckpoint['checkpointed'] == 0);
    assert(File('$path-wal').lengthSync() == 0);
    assert(setup.select('PRAGMA journal_mode').single['journal_mode'] == 'wal');
    setup.execute('CREATE TABLE checkpoint_probe (id INTEGER, value TEXT)');
    setup.execute('PRAGMA wal_autocheckpoint = 1');
    setup.execute("INSERT INTO checkpoint_probe VALUES (1, 'auto')");
    assert(
      setup.select('PRAGMA wal_checkpoint(NOOP)').single['log'] == 0,
      'wal_autocheckpoint should checkpoint at its page threshold',
    );
    assert(
      setup.select('SELECT value FROM checkpoint_probe').single['value'] ==
          'auto',
    );
    setup.execute('PRAGMA wal_autocheckpoint = -1');
    assert(
      setup.select('PRAGMA wal_autocheckpoint').single['wal_autocheckpoint'] ==
          0,
    );
    setup.execute('PRAGMA wal_autocheckpoint = 0');
    setup.execute("INSERT INTO checkpoint_probe VALUES (2, 'full')");
    final fullCheckpoint = setup.select('PRAGMA wal_checkpoint(FULL)').single;
    assert(fullCheckpoint['busy'] == 0);
    assert(fullCheckpoint['log'] == fullCheckpoint['checkpointed']);
    assert(setup.select('PRAGMA wal_checkpoint(NOOP)').single['log'] == 0);
    setup.execute("INSERT INTO checkpoint_probe VALUES (3, 'restart')");
    final restartCheckpoint = setup
        .select('PRAGMA wal_checkpoint(RESTART)')
        .single;
    assert(restartCheckpoint['busy'] == 0);
    assert(restartCheckpoint['log'] == restartCheckpoint['checkpointed']);
    assert(setup.select('PRAGMA wal_checkpoint(NOOP)').single['log'] == 0);
    setup.execute("INSERT INTO checkpoint_probe VALUES (3, 'default')");
    final defaultCheckpoint = setup.select('PRAGMA wal_checkpoint').single;
    assert(defaultCheckpoint['busy'] == 0);
    assert(defaultCheckpoint['log'] == defaultCheckpoint['checkpointed']);
    assert(setup.select('PRAGMA wal_checkpoint(NOOP)').single['log'] == 0);
    try {
      setup.select('PRAGMA wal_checkpoint(IMMEDIATE)');
      assert(false, 'unsupported checkpoint modes must be rejected');
    } on PureSqlException catch (error) {
      assert(error.message.contains('invalid wal_checkpoint mode'));
    }
    setup.execute("INSERT INTO checkpoint_probe VALUES (4, 'query-only')");
    setup.execute('PRAGMA query_only = ON');
    assert(
      (setup.select('PRAGMA wal_checkpoint(NOOP)').single['log'] as int) > 0,
    );
    try {
      setup.select('PRAGMA wal_checkpoint(PASSIVE)');
      assert(false, 'query_only must block mutating checkpoints');
    } on PureSqlException catch (error) {
      assert(error.message.contains('readonly'));
    }
    setup.execute('PRAGMA query_only = OFF');
    setup.select('PRAGMA wal_checkpoint(TRUNCATE)');
    setup.execute('BEGIN IMMEDIATE');
    setup.execute("INSERT INTO checkpoint_probe VALUES (5, 'pending')");
    final passiveWhileWriting = setup
        .select('PRAGMA wal_checkpoint(PASSIVE)')
        .single;
    assert(passiveWhileWriting['busy'] == 0);
    assert(passiveWhileWriting['checkpointed'] == 0);
    final fullWhileWriting = setup.select('PRAGMA wal_checkpoint(FULL)').single;
    assert(fullWhileWriting['busy'] == 1);
    setup.execute('ROLLBACK');
    setup.execute(
      'CREATE TABLE wal_vacuum_rows (id INTEGER PRIMARY KEY, tag TEXT, payload TEXT)',
    );
    setup.execute('CREATE INDEX wal_vacuum_tag ON wal_vacuum_rows (tag)');
    final walVacuumPlaceholders = List.filled(40, '(?, ?, ?)').join(', ');
    setup.execute('INSERT INTO wal_vacuum_rows VALUES $walVacuumPlaceholders', [
      for (var id = 1; id <= 40; id++) ...[id, 'tag-$id', 'y' * 1800],
    ]);
    setup.execute('DELETE FROM wal_vacuum_rows WHERE id > 2');
    final walVacuumPageCount =
        setup.select('PRAGMA page_count').single['page_count'] as int;
    final walVacuumIntoPath = '${directory.path}/wal-vacuum-into.sqlite';
    setup.execute('VACUUM main INTO ?', [walVacuumIntoPath]);
    assert(
      setup.select('PRAGMA page_count').single['page_count'] ==
          walVacuumPageCount,
    );
    final walVacuumIntoDb = PureDatabase.open(walVacuumIntoPath);
    assert(
      walVacuumIntoDb.select('PRAGMA journal_mode').single['journal_mode'] ==
          'delete',
    );
    assert(
      (walVacuumIntoDb.select('PRAGMA page_count').single['page_count']
              as int) <
          walVacuumPageCount,
    );
    assert(
      walVacuumIntoDb
              .select('SELECT COUNT(*) AS count FROM wal_vacuum_rows')
              .single['count'] ==
          2,
    );
    assert(
      walVacuumIntoDb
              .select('PRAGMA integrity_check')
              .single['integrity_check'] ==
          'ok',
    );
    walVacuumIntoDb.close();
    final sqliteVacuumInto = Process.runSync('sqlite3', [
      walVacuumIntoPath,
      'PRAGMA journal_mode; PRAGMA integrity_check; SELECT COUNT(*) FROM wal_vacuum_rows; PRAGMA freelist_count;',
    ]);
    assert(sqliteVacuumInto.exitCode == 0, sqliteVacuumInto.stderr);
    assert(
      sqliteVacuumInto.stdout.trim() == 'delete\nok\n2\n0',
      sqliteVacuumInto.stdout,
    );
    setup.execute('VACUUM');
    assert(
      (setup.select('PRAGMA page_count').single['page_count'] as int) <
          walVacuumPageCount,
    );
    assert(
      setup.select('PRAGMA integrity_check').single['integrity_check'] == 'ok',
    );
    setup.close();

    final reader = PureDatabase.open(path);
    final holder = await Process.start(Platform.resolvedExecutable, [
      Platform.script.toFilePath(),
      '--hold-write',
      path,
    ]);
    var holderExited = false;
    try {
      final lines = StreamIterator<String>(
        holder.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      assert(await lines.moveNext().timeout(const Duration(seconds: 5)));
      assert(lines.current == 'READY');
      final stopwatch = Stopwatch()..start();
      final duringWrite = reader
          .select('SELECT value FROM entries WHERE id = 1')
          .single['value'];
      stopwatch.stop();
      assert(duringWrite == 'before');
      assert(stopwatch.elapsed < const Duration(milliseconds: 1000));

      holder.stdin.writeln('commit');
      assert(await lines.moveNext().timeout(const Duration(seconds: 5)));
      assert(lines.current == 'COMMITTED');
      assert(
        reader
                .select('SELECT value FROM entries WHERE id = 1')
                .single['value'] ==
            'committed',
      );
      holder.stdin.writeln('close');
      assert(await holder.exitCode == 0);
      await lines.cancel();
      holderExited = true;
    } finally {
      if (!holderExited) {
        holder.kill();
        await holder.exitCode;
      }
    }
    reader.close();

    final reopened = PureDatabase.open(path);
    assert(
      reopened.select('PRAGMA journal_mode').single['journal_mode'] == 'wal',
    );
    assert(
      reopened
              .select('SELECT value FROM entries WHERE id = 1')
              .single['value'] ==
          'committed',
    );
    assert(
      (reopened
                      .select('SELECT payload FROM large_entries WHERE id = 1')
                      .single['payload']
                  as String)
              .length ==
          12000,
    );
    reopened.execute('BEGIN');
    reopened.execute('INSERT INTO wal_raise_rows VALUES (1)');
    try {
      reopened.execute('INSERT INTO wal_raise_rows VALUES (2), (3)');
      assert(false, 'RAISE(ABORT) should restore the WAL savepoint');
    } on SqliteException catch (error) {
      assert(error.message == 'WAL statement aborted');
    }
    assert(
      reopened.select('SELECT value FROM wal_raise_rows').single['value'] == 1,
    );
    reopened.execute('COMMIT');
    reopened.close();

    final sqlite = Process.runSync('sqlite3', [
      path,
      'PRAGMA journal_mode; PRAGMA integrity_check; SELECT value FROM entries; SELECT length(payload) FROM large_entries; SELECT value FROM wal_raise_rows; SELECT COUNT(*) FROM wal_vacuum_rows; PRAGMA freelist_count;',
    ]);
    assert(sqlite.exitCode == 0, sqlite.stderr);
    assert(
      sqlite.stdout.trim() == 'wal\nok\ncommitted\n12000\n1\n2\n0',
      sqlite.stdout,
    );

    final rollbackJournal = PureDatabase.open(path);
    rollbackJournal.execute('PRAGMA journal_mode = DELETE');
    assert(
      rollbackJournal.select('PRAGMA journal_mode').single['journal_mode'] ==
          'delete',
    );
    assert(
      rollbackJournal
              .select('SELECT value FROM entries WHERE id = 1')
              .single['value'] ==
          'committed',
    );
    rollbackJournal.close();
    assert(!File('$path-wal').existsSync());

    final rollbackSqlite = Process.runSync('sqlite3', [
      path,
      'PRAGMA journal_mode; PRAGMA integrity_check; SELECT value FROM entries; SELECT length(payload) FROM large_entries; SELECT value FROM wal_raise_rows; SELECT COUNT(*) FROM wal_vacuum_rows; PRAGMA freelist_count;',
    ]);
    assert(rollbackSqlite.exitCode == 0, rollbackSqlite.stderr);
    assert(
      rollbackSqlite.stdout.trim() == 'delete\nok\ncommitted\n12000\n1\n2\n0',
      rollbackSqlite.stdout,
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
