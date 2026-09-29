import 'package:dart_sqlite/dart_sqlite.dart';

void main() {
  final db = PureDatabase.memory();
  db.execute('''
    CREATE TABLE users (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      active INTEGER
    )
  ''');

  db.execute('INSERT INTO users VALUES (?, ?, ?)', [1, 'Alice', 1]);
  db.execute('INSERT INTO users VALUES (?, ?, ?)', [2, 'Bob', 0]);
  db.execute('UPDATE users SET active = ? WHERE name = ?', [1, 'Bob']);

  final rows = db.select(
    'SELECT id, name FROM users WHERE active = ? ORDER BY id DESC LIMIT ?',
    [1, 1],
  );
  assert(rows.length == 1);
  assert(rows.single['name'] == 'Bob');
  final paged = db.select(
    'SELECT id FROM users WHERE name LIKE ? ORDER BY name COLLATE NOCASE LIMIT ? OFFSET ?',
    ['%', 1, 1],
  );
  assert(paged.single['id'] == 2);

  try {
    db.transaction((database) {
      database.execute('DELETE FROM users WHERE id = ?', [1]);
      throw StateError('rollback');
    });
  } on StateError {
    // Expected.
  }
  assert(db.select('SELECT id FROM users ORDER BY id').length == 2);

  try {
    db.execute('INSERT INTO users VALUES (?, ?, ?)', [3, null, 1]);
    assert(false, 'NOT NULL should fail');
  } on PureSqlException {
    // Expected.
  }

  assert(
    db.execute('INSERT OR IGNORE INTO users VALUES (?, ?, ?)', [
          1,
          'ignored',
          0,
        ]) ==
        0,
  );
  assert(
    db.select('SELECT name FROM users WHERE id = 1').single['name'] == 'Alice',
  );
  assert(
    db.execute('INSERT OR REPLACE INTO users VALUES (?, ?, ?)', [
          1,
          'replaced',
          0,
        ]) ==
        1,
  );
  assert(
    db.select('SELECT name FROM users WHERE id = 1').single['name'] ==
        'replaced',
  );

  final fkDb = PureDatabase.memory();
  fkDb.execute('CREATE TABLE folders (id TEXT PRIMARY KEY)');
  fkDb.execute(
    'CREATE TABLE files (id TEXT PRIMARY KEY, folder_id TEXT REFERENCES folders(id))',
  );
  fkDb.execute('PRAGMA foreign_keys = ON');
  assert(fkDb.select('PRAGMA foreign_keys').single['foreign_keys'] == 1);
  fkDb.execute('INSERT INTO folders VALUES (?)', ['folder']);
  fkDb.execute('INSERT INTO files VALUES (?, ?)', ['file', 'folder']);
  try {
    fkDb.execute('INSERT INTO files VALUES (?, ?)', ['bad', 'missing']);
    assert(false, 'foreign key should fail');
  } on PureSqlException {
    // Expected.
  }
  try {
    fkDb.execute('DELETE FROM folders WHERE id = ?', ['folder']);
    assert(false, 'referenced parent delete should fail');
  } on PureSqlException {
    // Expected.
  }
  final joined = fkDb.select(
    'SELECT files.id, folders.id FROM files JOIN folders ON files.folder_id = folders.id',
  );
  assert(joined.single['files.id'] == 'file');
  fkDb.execute('INSERT INTO folders VALUES (?)', ['empty']);
  final leftJoined = fkDb.select(
    'SELECT folders.id, files.id FROM folders LEFT JOIN files ON files.folder_id = folders.id ORDER BY folders.id',
  );
  assert(leftJoined.last['folders.id'] == 'folder');
  assert(leftJoined.last['files.id'] == 'file');
  assert(leftJoined.first['folders.id'] == 'empty');
  assert(leftJoined.first['files.id'] == null);

  final grouped = PureDatabase.memory();
  grouped.execute('CREATE TABLE events (day TEXT, amount INTEGER)');
  grouped.execute('INSERT INTO events VALUES (?, ?)', ['a', 2]);
  grouped.execute('INSERT INTO events VALUES (?, ?)', ['a', 3]);
  grouped.execute('INSERT INTO events VALUES (?, ?)', ['b', 5]);
  final totals = grouped.select(
    'SELECT day, COUNT(*) AS count, SUM(amount) AS total FROM events GROUP BY day ORDER BY day',
  );
  assert(totals.length == 2);
  assert(totals[0]['day'] == 'a');
  assert(totals[0]['count'] == 2);
  assert(totals[0]['total'] == 5);
  assert(totals[1]['day'] == 'b');
  assert(totals[1]['count'] == 1);
  assert(totals[1]['total'] == 5);
}
