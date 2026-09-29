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
    setup.execute('CREATE TABLE entries (id INTEGER PRIMARY KEY, value TEXT)');
    setup.execute("INSERT INTO entries VALUES (1, 'before')");
    setup.execute('PRAGMA journal_mode = WAL');
    assert(setup.select('PRAGMA journal_mode').single['journal_mode'] == 'wal');
    assert(File('$path-wal').existsSync(), 'WAL file should be created');
    setup.execute(
      'CREATE TABLE large_entries (id INTEGER PRIMARY KEY, payload TEXT)',
    );
    setup.execute('INSERT INTO large_entries VALUES (1, ?)', ['x' * 12000]);
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
    reopened.close();

    final sqlite = Process.runSync('sqlite3', [
      path,
      'PRAGMA journal_mode; PRAGMA integrity_check; SELECT value FROM entries; SELECT length(payload) FROM large_entries;',
    ]);
    assert(sqlite.exitCode == 0, sqlite.stderr);
    assert(sqlite.stdout.trim() == 'wal\nok\ncommitted\n12000', sqlite.stdout);

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
      'PRAGMA journal_mode; PRAGMA integrity_check; SELECT value FROM entries; SELECT length(payload) FROM large_entries;',
    ]);
    assert(rollbackSqlite.exitCode == 0, rollbackSqlite.stderr);
    assert(
      rollbackSqlite.stdout.trim() == 'delete\nok\ncommitted\n12000',
      rollbackSqlite.stdout,
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
