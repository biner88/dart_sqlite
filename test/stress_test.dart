import 'package:dart_sqlite/dart_sqlite.dart';

void main() {
  final database = PureDatabase.memory();
  database.execute(
    'CREATE TABLE values_table (id INTEGER PRIMARY KEY, value INTEGER)',
  );
  var seed = 17;
  int next() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed;
  }

  for (var step = 0; step < 300; step++) {
    final id = next() % 80 + 1;
    switch (next() % 3) {
      case 0:
        database.execute('INSERT OR REPLACE INTO values_table VALUES (?, ?)', [
          id,
          next() % 1000,
        ]);
      case 1:
        database.execute('UPDATE values_table SET value = ? WHERE id = ?', [
          next() % 1000,
          id,
        ]);
      case 2:
        database.execute('DELETE FROM values_table WHERE id = ?', [id]);
    }
  }
  final rows = database.select(
    'SELECT id, value FROM values_table ORDER BY id',
  );
  assert(rows.length <= 80);
  for (var index = 1; index < rows.length; index++) {
    assert((rows[index - 1]['id'] as int) < (rows[index]['id'] as int));
  }

  for (final sql in const [
    '',
    'SELECT',
    'CREATE TABLE',
    'INSERT INTO values_table VALUES',
    'SELECT * FROM missing',
  ]) {
    try {
      database.select(sql);
    } on PureSqlException {
      // Expected parser and execution errors.
    }
  }

  final stopwatch = Stopwatch()..start();
  for (var index = 0; index < 100; index++) {
    database.select('SELECT id FROM values_table WHERE id = ?', [index]);
  }
  stopwatch.stop();
  assert(stopwatch.elapsedMilliseconds < 5000);
}
