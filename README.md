# dart_sqlite

A dependency-free, pure-Dart SQLite-compatible engine for synchronous Dart VM applications. It reads and writes SQLite 3 database files without native SQLite or FFI.

> Status: experimental and application-focused. “SQLite-compatible” describes the database file format and the subset listed below; it does not mean full SQLite SQL semantics or a drop-in replacement for every `package:sqlite3` API.

## What it provides

- In-memory databases and persistent database files.
- Positional SQL parameters, transactions, and synchronous `execute` / `select` APIs.
- SQLite table/index B-trees, overflow pages, rollback-journal recovery, and WAL read/write support.
- A small `sqlite3.open` facade for call sites using `execute`, `select`, `updatedRows`, and `dispose`.
- No runtime package dependencies.

## Install

This package is not published on pub.dev. Use a path dependency:

```yaml
dependencies:
  dart_sqlite:
    path: ../dart_sqlite
```

Adjust the path relative to the consuming project's `pubspec.yaml`.

## Quick start

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

Use `PureDatabase.open(path)` for a persistent file. `PureDatabase.transaction` commits on success and rolls back when the callback throws. Nested transactions are not supported for persistent databases.

## Supported SQL

`execute()` accepts one statement or a semicolon-separated script. Bind values
with a positional list or a map for named placeholders. A trailing semicolon is
optional.

| Area | Supported subset |
| --- | --- |
| DDL | `CREATE TABLE [IF NOT EXISTS]`; `CREATE VIEW [IF NOT EXISTS]` with optional output-column names; `CREATE [UNIQUE] INDEX [IF NOT EXISTS]` on columns, including partial indexes; `DROP TABLE` / `DROP VIEW` / `DROP INDEX [IF EXISTS]`; `ALTER TABLE ... ADD [COLUMN]` with declared types, `NOT NULL`, and literal `DEFAULT` |
| DML | Multi-row `INSERT [OR IGNORE\|REPLACE] INTO ... VALUES (...)`, `DEFAULT VALUES`, and `INSERT ... SELECT`; UPSERT `ON CONFLICT (...) DO NOTHING` or `DO UPDATE SET ... [WHERE ...]`; `UPDATE [OR ABORT\|IGNORE\|REPLACE] ... SET ... [WHERE ...]`; `DELETE FROM ... [WHERE ...]` |
| Query | `SELECT` with or without `FROM`, derived tables in `FROM` and joins, non-recursive `WITH` CTEs, `UNION` / `UNION ALL` / `INTERSECT` / `EXCEPT`, `DISTINCT`, `AS` aliases, `WHERE`, inner/left/right/full/cross/natural joins with `ON` or `USING`, `GROUP BY`, `HAVING`, expression/ordinal `ORDER BY`, `LIMIT`, and `OFFSET`; `*` and qualified columns are supported |
| Schema constraints | Column `PRIMARY KEY`, `UNIQUE`, `NOT NULL`, literal `DEFAULT`, `CHECK`, and `REFERENCES`; table-level primary key, unique, foreign key, and `CHECK` constraints; foreign-key `ON DELETE` / `ON UPDATE` actions `NO ACTION`, `RESTRICT`, `CASCADE`, `SET NULL`, and `SET DEFAULT` |
| Collations | `BINARY` and ASCII `NOCASE` on columns; `ORDER BY ... COLLATE NOCASE` |
| Transactions | `BEGIN [DEFERRED\|IMMEDIATE\|EXCLUSIVE]`, `COMMIT` / `END`, and `ROLLBACK` |
| Parameters | Positional `?` and numbered `?NNN`; named `:name`, `@name`, and `$name` placeholders; use a list in slot order or a name map (map keys may include the prefix). Values can be `null`, numbers, strings, booleans, or `List<int>` blobs |

Expressions support literals, column references, parentheses, searched `CASE`, unary and arithmetic operators, comparisons, `IS [NOT] [DISTINCT FROM]`, `BETWEEN`, `LIKE` / `GLOB` / `REGEXP`, `IN` lists and subqueries, `EXISTS`, bitwise operators, concatenation, and `CAST`. Scalar and correlated scalar subqueries are supported in expressions. Single-quoted strings, `--` line comments, and block comments are supported. Unquoted identifiers accept Unicode letters and digits; double-quoted, backtick, and bracket identifiers are also accepted.

### Functions

- Scalar: `ABS`, `CHAR`, `COALESCE`, `CONCAT`, `CONCAT_WS`, `DATE`, `DATETIME`, `HEX`, `IFNULL`, `IIF`, `INSTR`, `JULIANDAY`, `LENGTH`, `LIKELIHOOD`, `LIKELY`, `LOWER`, `LTRIM`, `NULLIF`, `QUOTE`, `RANDOM`, `RANDOMBLOB`, `REPLACE`, `ROUND`, `RTRIM`, `STRFTIME`, `SUBSTR` / `SUBSTRING`, `TIME`, `TRIM`, `TYPEOF`, `UNICODE`, `UNIXEPOCH`, `UNLIKELY`, `UPPER`, and `ZEROBLOB`.
- Math: `ACOS`, `ACOSH`, `ASIN`, `ASINH`, `ATAN`, `ATAN2`, `ATANH`, `CEIL` / `CEILING`, `COS`, `COSH`, `DEGREES`, `EXP`, `FLOOR`, `LN`, `LOG`, `LOG10`, `LOG2`, `MOD`, `PI`, `POW` / `POWER`, `RADIANS`, `SIGN`, `SIN`, `SINH`, `SQRT`, `TAN`, `TANH`, and `TRUNC`. Out-of-domain or non-finite results return `NULL`.
- Aggregates: `AVG`, `COUNT`, `GROUP_CONCAT`, `MAX`, `MIN`, `SUM`, and `TOTAL`; aggregates support `DISTINCT`, and `COUNT(*)` is supported.
- Date functions implement common ISO-8601 and Unix timestamp inputs, a subset of SQLite date modifiers, and common `strftime` directives; they are not a full date/time compatibility layer.
- `RANDOMBLOB` / `ZEROBLOB` are limited to 16 MiB per result.

### Supported PRAGMAs

Read/write settings: `application_id`, `user_version`, `foreign_keys`, `busy_timeout`, `synchronous`, and `journal_mode` (`DELETE` / `WAL` for persistent databases; in-memory reports `memory`). Read-only inspection includes `integrity_check`, `quick_check`, `table_info`, `table_xinfo`, `index_list`, `index_info`, `index_xinfo`, `foreign_key_list`, `foreign_key_check`, `database_list`, `table_list`, `collation_list`, `function_list`, `pragma_list`, `encoding`, `page_size`, `page_count`, `freelist_count`, and `auto_vacuum`.

## Not supported

- Full SQLite grammar: recursive CTEs, window functions, and DML `RETURNING`.
- Other DDL: rename/drop-column forms of `ALTER TABLE`, triggers, virtual tables, and `AUTOINCREMENT` sequence persistence.
- Other DML: `UPDATE OR FAIL` / `OR ROLLBACK` and `UPDATE` / `DELETE ... RETURNING`. UPSERT supports one conflict clause with column-only targets; target predicates and multiple clauses are not supported.
- Other expression syntax: row values and `RAISE()`. A named-parameter map cannot bind positional placeholders; use one binding style per statement.
- SQL functions and PRAGMAs not listed above. SQLite's extension, loadable-function, virtual-table, and compile-option ecosystem is intentionally not implied by these lists.

Unsupported SQL and functions raise `SqliteException`. Malformed or unsupported database-file data raises `SqliteFormatException`.

## Compatibility boundaries

### SQL and API behavior

- This is a subset engine, not a full SQLite interpreter. SQLite type affinity, coercion, and expression `NULL` behavior are not reproduced completely. `LIKE` supports `%` and `_` and SQLite-style ASCII case-insensitive matching. Do not assume SQL accepted by SQLite will work here.
- Foreign-key enforcement is off by default. When enabled with `PRAGMA foreign_keys = ON`, column- and table-level references and the listed immediate `ON DELETE` / `ON UPDATE` actions are applied on writes. Deferred checks are not implemented.
- `PRAGMA synchronous` accepts and reports SQLite-style values, but does not select different durability modes; file writes are flushed synchronously.
- Transaction mode keywords are accepted, but do not provide SQLite's full distinction between deferred, immediate, and exclusive transaction semantics.

### SQLite files and runtime

- Persistent storage uses `dart:io` and works on Dart VM, not Dart Web. `sqlite3.open(':memory:')` is not supported; use `PureDatabase.memory()`.
- The engine reads and writes SQLite 3 database files only when their schema and operations fit the supported subset. File-format compatibility does not imply SQL or feature compatibility for arbitrary SQLite databases.
- Rollback-journal files and WAL files are supported. WAL is scanned directly rather than through SQLite's shared-memory wal-index. Readers can see the last committed snapshot while a WAL writer is active; switching to `DELETE` checkpoints committed WAL pages. Automatic WAL-size checkpointing is not implemented.
- File locks and `busy_timeout` are implemented, with tests for interaction with native SQLite processes. Do not run simultaneous native SQLite writers against a database while this engine is open, especially in WAL mode.
- The package tests check representative SQLite CLI interoperability, journal recovery, locks, and WAL behavior. Passing them does not establish full SQLite compatibility or validate every application migration/query.

### `sqlite3` facade

For existing code that uses only the small facade, the import and call pattern can be switched:

```dart
import 'package:dart_sqlite/dart_sqlite.dart';

void main() {
  final db = sqlite3.open('data/app.sqlite');
  try {
    db.execute('INSERT INTO users (name) VALUES (?)', ['Ada']);
    print(db.updatedRows);
    print(db.select('SELECT id, name FROM users ORDER BY id').first['name']);
  } on SqliteException catch (error) {
    print(error);
  } finally {
    db.dispose();
  }
}
```

The facade provides `sqlite3.open(path)`, `Database.execute`, `Database.select`, `Database.updatedRows`, `Database.dispose`, `Row`, `ResultSet`, and `SqliteException`. It does not provide the complete `package:sqlite3` API (for example, prepared-statement objects or `sqlite3.open(':memory:')`). Use `PureDatabase` when the in-memory API or transaction callback is needed.

## License

MIT. See [LICENSE](LICENSE).
