# dart_sqlite

`dart_sqlite` is a dependency-free, pure-Dart SQLite-compatible engine for Dart VM applications. It reads and writes SQLite 3 database files and implements the SQL and database API needed by this repository's application.

Status: experimental and application-focused. Review the compatibility notes below before using it with other workloads.

This is a focused compatibility implementation, not a complete SQLite engine or a drop-in replacement for every API in the `sqlite3` package. It uses Dart file I/O and does not call native SQLite through FFI.

## Features

* In-memory and persistent file databases.
* Parameterized SQL, transactions, and synchronous `execute`/`select` APIs.
* SQLite 3 database pages, table and index B-trees, overflow pages, rollback-journal recovery, and WAL reading/writing.
* Application-used DDL and DML, constraints, indexes, joins, grouping, aggregates,        `CASE`, and scalar/correlated subqueries.
* A small `sqlite3.open` compatibility facade for applications that use `Database.execute`,        `Database.select`,        `updatedRows`, and `dispose`.
* No runtime dependencies in this package.

## Add the package

The package is currently local to this repository and is not published to pub.dev. Add it as a path dependency:

```yaml
dependencies:
  dart_sqlite: ^0.1.0
```

For another project, set `path` to the location of the `dart_sqlite` package relative to that project's `pubspec.yaml` .

## Quick start

Use `PureDatabase` for the engine's direct API. The same API works with an in-memory database or a persistent SQLite file.

```dart
import 'package:dart_sqlite/dart_sqlite.dart';

void main() {
  final db = PureDatabase.memory();
  try {
    db.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL
      )
    ''');
    db.execute('INSERT INTO users (name) VALUES (?)', ['Ada']);

    final rows = db.select(
      'SELECT id, name FROM users WHERE id = ?',
      [1],
    );
    print(rows.single['name']); // Ada
  } finally {
    db.close();
  }
}
```

Open a persistent database with `PureDatabase.open` :

```dart
import 'package:dart_sqlite/dart_sqlite.dart';

void main() {
  final db = PureDatabase.open(
    'data/app.sqlite',
    busyTimeout: const Duration(seconds: 5),
  );
  try {
    db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL
      )
    ''');
    db.execute('INSERT INTO users (name) VALUES (?)', ['Grace']);
    final users = db.select('SELECT id, name FROM users ORDER BY id');
    print(users.last['name']);
  } finally {
    db.close();
  }
}
```

`PureDatabase.transaction` commits when the callback returns and rolls back if it throws:

```dart
import 'package:dart_sqlite/dart_sqlite.dart';

void main() {
  final db = PureDatabase.memory();
  try {
    db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
    db.execute("INSERT INTO users VALUES (1, 'Grace')");
    db.transaction((transaction) {
      transaction.execute('UPDATE users SET name = ? WHERE id = ?', ['Ada', 1]);
    });
  } finally {
    db.close();
  }
}
```

## Replacing `sqlite3` call sites

For applications using the small compatibility surface implemented here, the import and package dependency can be switched while keeping their SQL text and call pattern:

```dart
import 'package:dart_sqlite/dart_sqlite.dart';

void main() {
  final db = sqlite3.open('data/app.sqlite');
  try {
    db.execute('INSERT INTO users (name) VALUES (?)', ['Ada']);
    print('Changed rows: ${db.updatedRows}');

    final rows = db.select('SELECT id, name FROM users ORDER BY id');
    print(rows.first['name']);
  } on SqliteException catch (error) {
    print('Database error: $error');
  } finally {
    db.dispose();
  }
}
```

The compatibility facade currently provides `sqlite3.open(path)` , `Database.execute` , `Database.select` , `Database.updatedRows` , `Database.dispose` , `Row` , and `SqliteException` . It does not provide the complete `sqlite3` package API. Use `PureDatabase.memory()` for an in-memory database; `sqlite3.open(':memory:')` is not supported.

## SQL support

The implemented subset targets the migrations and queries used by the bundled application. It includes:

* `CREATE TABLE`,  `CREATE INDEX` (including unique and partial indexes),        `ALTER TABLE ... ADD COLUMN`,        `INSERT`,        `UPDATE`, and `DELETE`.
* `SELECT` with parameters,        `WHERE`,        `INNER JOIN`,        `LEFT JOIN`,        `GROUP BY`, multi-term `ORDER BY`,        `LIMIT`, and `OFFSET`.
* `CASE`, scalar and correlated subqueries in the application's query forms, and `COUNT`,        `SUM`,        `MAX`,        `COUNT(DISTINCT ...)`,        `COALESCE`,        `LOWER`,        `UPPER`, and a subset of `strftime`.
* Primary/unique/not-null/check constraints, the implemented column-level foreign-key checks, and `BINARY`/ASCII `NOCASE` collations.
* `BEGIN`,        `COMMIT`,        `ROLLBACK`,        `PRAGMA user_version`,        `foreign_keys`,        `busy_timeout`,        `synchronous`, and the application's `journal_mode` request.

Unsupported syntax and functions throw `SqliteException` ; this package does not silently delegate SQL to a native SQLite library.

## Persistence and compatibility notes

* Persistent databases require Dart VM file I/O (`dart:io`); Web is not supported.
* Persistent databases default to SQLite's rollback-journal mode. `PRAGMA journal_mode = WAL` enables a standard SQLite WAL file;  `PRAGMA journal_mode` reports the active mode, and readers can continue reading the last committed snapshot while a WAL writer is active. Switching back to `DELETE` checkpoints committed WAL pages into the database file.
* WAL compatibility currently uses direct WAL scanning instead of SQLite's shared-memory wal-index. Do not run simultaneous native SQLite writers against a database while this engine is open; automatic WAL-size checkpointing is not implemented, so long-lived WAL files should be checkpointed by switching to `DELETE` when appropriate.
* The compatibility facade covers the API used by this repository, not all APIs in `package:sqlite3`.
* This engine has a deliberately limited SQL and SQLite-file-format surface. It does not currently implement triggers, views, CTEs, window functions, FTS, virtual tables, or SQLite extensions. See the package tests for the currently verified behavior.

## License

This package is licensed under the [MIT license](https://opensource.org/licenses/MIT).
See [LICENSE](LICENSE) for more information.
