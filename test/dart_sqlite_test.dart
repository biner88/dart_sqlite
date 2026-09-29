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
  fkDb.execute(
    'CREATE TABLE composite_parent (a TEXT, b TEXT, PRIMARY KEY (a, b))',
  );
  fkDb.execute('''
    CREATE TABLE composite_child (
      a TEXT,
      b TEXT,
      FOREIGN KEY (a, b) REFERENCES composite_parent (a, b)
        ON DELETE CASCADE ON UPDATE CASCADE
    )
  ''');
  fkDb.execute("INSERT INTO composite_parent VALUES ('x', 'y')");
  fkDb.execute("INSERT INTO composite_child VALUES ('x', 'y')");
  assert(fkDb.select('PRAGMA foreign_key_list(composite_child)').length == 2);
  try {
    fkDb.execute("INSERT INTO composite_child VALUES ('x', 'bad')");
    assert(false, 'composite foreign key should fail');
  } on PureSqlException {
    // Expected.
  }
  assert(fkDb.select('PRAGMA foreign_key_check').isEmpty);
  fkDb.execute("UPDATE composite_parent SET a = 'z' WHERE a = 'x'");
  assert(fkDb.select('SELECT a FROM composite_child').single['a'] == 'z');
  fkDb.execute("DELETE FROM composite_parent WHERE a = 'z'");
  assert(fkDb.select('SELECT * FROM composite_child').isEmpty);
  fkDb.execute('INSERT INTO folders VALUES (?)', ['empty']);
  final leftJoined = fkDb.select(
    'SELECT folders.id, files.id FROM folders LEFT JOIN files ON files.folder_id = folders.id ORDER BY folders.id',
  );
  assert(leftJoined.last['folders.id'] == 'folder');
  assert(leftJoined.last['files.id'] == 'file');
  assert(leftJoined.first['folders.id'] == 'empty');
  assert(leftJoined.first['files.id'] == null);

  final cascadeDb = PureDatabase.memory();
  cascadeDb.execute('CREATE TABLE cascade_parent (id INTEGER PRIMARY KEY)');
  cascadeDb.execute('''
    CREATE TABLE cascade_child (
      id INTEGER,
      parent_id INTEGER PRIMARY KEY REFERENCES cascade_parent(id)
        ON DELETE CASCADE ON UPDATE CASCADE
    )
  ''');
  cascadeDb.execute('''
    CREATE TABLE cascade_grandchild (
      id INTEGER PRIMARY KEY,
      child_id INTEGER REFERENCES cascade_child(parent_id)
        ON DELETE CASCADE ON UPDATE CASCADE
    )
  ''');
  cascadeDb.execute('PRAGMA foreign_keys = ON');
  cascadeDb.execute('INSERT INTO cascade_parent VALUES (1)');
  cascadeDb.execute('INSERT INTO cascade_child VALUES (10, 1)');
  cascadeDb.execute('INSERT INTO cascade_grandchild VALUES (100, 1)');
  assert(
    cascadeDb
            .select('PRAGMA foreign_key_list(cascade_child)')
            .single['on_update'] ==
        'CASCADE',
  );
  cascadeDb.execute('UPDATE cascade_parent SET id = 2 WHERE id = 1');
  assert(
    cascadeDb
            .select('SELECT parent_id FROM cascade_child')
            .single['parent_id'] ==
        2,
  );
  cascadeDb.execute(
    'CREATE TABLE alternate_parent (id INTEGER PRIMARY KEY, key TEXT UNIQUE, value INTEGER)',
  );
  cascadeDb.execute('''
    CREATE TABLE alternate_child (
      parent_id INTEGER REFERENCES alternate_parent(id) ON UPDATE CASCADE
    )
  ''');
  cascadeDb.execute("INSERT INTO alternate_parent VALUES (1, 'same', 10)");
  cascadeDb.execute('INSERT INTO alternate_child VALUES (1)');
  assert(
    cascadeDb.execute('''
      INSERT INTO alternate_parent VALUES (2, 'same', 20)
      ON CONFLICT(key) DO UPDATE
      SET id = EXCLUDED.id, value = excluded.value
    ''') ==
        1,
  );
  assert(
    cascadeDb.select('SELECT id, value FROM alternate_parent').single['id'] ==
        2,
  );
  assert(
    cascadeDb
            .select('SELECT parent_id FROM alternate_child')
            .single['parent_id'] ==
        2,
  );
  assert(
    cascadeDb.execute('''
      INSERT INTO alternate_parent VALUES (3, 'same', 30)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      WHERE excluded.id < 0
    ''') ==
        0,
  );
  assert(
    cascadeDb.select('SELECT value FROM alternate_parent').single['value'] ==
        20,
  );
  cascadeDb.execute(
    "INSERT INTO alternate_parent (key, value) VALUES ('new', 40)",
  );
  assert(
    cascadeDb
            .select("SELECT id FROM alternate_parent WHERE key = 'new'")
            .single['id'] ==
        3,
  );
  assert(
    cascadeDb
            .select('SELECT child_id FROM cascade_grandchild')
            .single['child_id'] ==
        2,
  );
  cascadeDb.execute('DELETE FROM cascade_parent WHERE id = 2');
  assert(cascadeDb.select('SELECT * FROM cascade_child').isEmpty);
  assert(cascadeDb.select('SELECT * FROM cascade_grandchild').isEmpty);

  final actionDb = PureDatabase.memory();
  actionDb.execute('CREATE TABLE action_parent (id INTEGER PRIMARY KEY)');
  actionDb.execute('INSERT INTO action_parent VALUES (1), (9)');
  actionDb.execute('''
    CREATE TABLE null_child (
      parent_id INTEGER REFERENCES action_parent(id)
        ON DELETE SET NULL ON UPDATE SET NULL
    )
  ''');
  actionDb.execute('''
    CREATE TABLE default_child (
      parent_id INTEGER DEFAULT 9 REFERENCES action_parent(id)
        ON DELETE SET DEFAULT ON UPDATE SET DEFAULT
    )
  ''');
  actionDb.execute('''
    CREATE TABLE restricted_child (
      parent_id INTEGER REFERENCES action_parent(id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
    )
  ''');
  actionDb.execute('PRAGMA foreign_keys = ON');
  actionDb.execute('INSERT INTO null_child VALUES (1)');
  actionDb.execute('INSERT INTO default_child VALUES (1)');
  actionDb.execute('UPDATE action_parent SET id = 2 WHERE id = 1');
  assert(
    actionDb
        .select('SELECT parent_id FROM null_child')
        .every((row) => row['parent_id'] == null),
  );
  assert(
    actionDb
        .select('SELECT parent_id FROM default_child')
        .every((row) => row['parent_id'] == 9),
  );
  actionDb.execute('INSERT INTO null_child VALUES (2)');
  actionDb.execute('INSERT INTO default_child VALUES (2)');
  actionDb.execute('INSERT INTO restricted_child VALUES (2)');
  try {
    actionDb.execute('UPDATE action_parent SET id = 3 WHERE id = 2');
    assert(false, 'RESTRICT should reject parent updates');
  } on PureSqlException {
    assert(
      actionDb.select('SELECT id FROM action_parent WHERE id = 2').length == 1,
    );
  }
  try {
    actionDb.execute('DELETE FROM action_parent WHERE id = 2');
    assert(false, 'RESTRICT should reject parent deletes');
  } on PureSqlException {
    assert(
      actionDb.select('SELECT id FROM action_parent WHERE id = 2').length == 1,
    );
  }
  actionDb.execute('DELETE FROM restricted_child');
  actionDb.execute('DELETE FROM action_parent WHERE id = 2');
  assert(
    actionDb
        .select('SELECT parent_id FROM null_child')
        .every((row) => row['parent_id'] == null),
  );
  assert(
    actionDb
        .select('SELECT parent_id FROM default_child')
        .every((row) => row['parent_id'] == 9),
  );

  final replaceDb = PureDatabase.memory();
  replaceDb.execute('CREATE TABLE replace_parent (id INTEGER PRIMARY KEY)');
  replaceDb.execute('''
    CREATE TABLE replace_child (
      parent_id INTEGER REFERENCES replace_parent(id) ON DELETE CASCADE
    )
  ''');
  replaceDb.execute('PRAGMA foreign_keys = ON');
  replaceDb.execute('INSERT INTO replace_parent VALUES (1)');
  replaceDb.execute('INSERT INTO replace_child VALUES (1)');
  replaceDb.execute('INSERT OR REPLACE INTO replace_parent VALUES (1)');
  assert(replaceDb.select('SELECT * FROM replace_child').isEmpty);

  final dropDb = PureDatabase.memory();
  dropDb.execute('CREATE TABLE drop_parent (id INTEGER PRIMARY KEY)');
  dropDb.execute('''
    CREATE TABLE drop_child (
      parent_id INTEGER REFERENCES drop_parent(id) ON DELETE SET NULL
    )
  ''');
  dropDb.execute('PRAGMA foreign_keys = ON');
  dropDb.execute('INSERT INTO drop_parent VALUES (1)');
  dropDb.execute('INSERT INTO drop_child VALUES (1)');
  dropDb.execute('DROP TABLE drop_parent');
  assert(
    dropDb.select('SELECT parent_id FROM drop_child').single['parent_id'] ==
        null,
  );

  final updateConflictDb = PureDatabase.memory();
  updateConflictDb.execute(
    'CREATE TABLE update_conflicts (id INTEGER PRIMARY KEY, label TEXT UNIQUE)',
  );
  updateConflictDb.execute('''
    CREATE TABLE update_conflict_children (
      parent_id INTEGER REFERENCES update_conflicts(id) ON DELETE CASCADE
    )
  ''');
  updateConflictDb.execute('PRAGMA foreign_keys = ON');
  updateConflictDb.execute(
    "INSERT INTO update_conflicts VALUES (1, 'one'), (2, 'two')",
  );
  updateConflictDb.execute('INSERT INTO update_conflict_children VALUES (1)');
  assert(
    updateConflictDb.execute(
          "UPDATE OR IGNORE update_conflicts SET label = 'one' WHERE id = 2",
        ) ==
        0,
  );
  assert(
    updateConflictDb
            .select('SELECT label FROM update_conflicts WHERE id = 2')
            .single['label'] ==
        'two',
  );
  assert(
    updateConflictDb.execute(
          "UPDATE OR REPLACE update_conflicts SET label = 'one' WHERE id = 2",
        ) ==
        1,
  );
  assert(
    updateConflictDb
            .select('SELECT id FROM update_conflicts WHERE label = \'one\'')
            .single['id'] ==
        2,
  );
  assert(
    updateConflictDb.select('SELECT * FROM update_conflict_children').isEmpty,
  );

  updateConflictDb.execute(
    "CREATE TABLE update_checks (id INTEGER PRIMARY KEY, value TEXT NOT NULL CHECK (value <> 'bad'))",
  );
  updateConflictDb.execute("INSERT INTO update_checks VALUES (1, 'good')");
  assert(
    updateConflictDb.execute(
          'UPDATE OR IGNORE update_checks SET value = NULL WHERE id = 1',
        ) ==
        0,
  );
  assert(
    updateConflictDb.execute(
          "UPDATE OR IGNORE update_checks SET value = 'bad' WHERE id = 1",
        ) ==
        0,
  );
  assert(
    updateConflictDb
            .select('SELECT value FROM update_checks')
            .single['value'] ==
        'good',
  );

  final disabledFkDb = PureDatabase.memory();
  disabledFkDb.execute('CREATE TABLE disabled_parent (id INTEGER PRIMARY KEY)');
  disabledFkDb.execute('''
    CREATE TABLE disabled_child (
      parent_id INTEGER REFERENCES disabled_parent(id) ON UPDATE CASCADE
    )
  ''');
  disabledFkDb.execute('INSERT INTO disabled_parent VALUES (1)');
  disabledFkDb.execute('INSERT INTO disabled_child VALUES (1)');
  disabledFkDb.execute('UPDATE disabled_parent SET id = 2 WHERE id = 1');
  assert(
    disabledFkDb
            .select('SELECT parent_id FROM disabled_child')
            .single['parent_id'] ==
        1,
  );

  final renameDb = PureDatabase.memory();
  renameDb.execute('''
    CREATE TABLE old_parent (
      id INTEGER PRIMARY KEY,
      value TEXT,
      external_key TEXT UNIQUE
    )
  ''');
  renameDb.execute('''
    CREATE TABLE old_child (
      parent_id INTEGER REFERENCES old_parent(id) ON UPDATE CASCADE
    )
  ''');
  renameDb.execute('CREATE INDEX old_parent_value_idx ON old_parent(value)');
  renameDb.execute('''
    CREATE VIEW old_parent_view AS
      SELECT id, 'FROM old_parent' AS marker FROM old_parent
  ''');
  renameDb.execute('PRAGMA foreign_keys = ON');
  renameDb.execute("INSERT INTO old_parent VALUES (1, 'value', 'key')");
  renameDb.execute('INSERT INTO old_child VALUES (1)');
  renameDb.execute('ALTER TABLE old_parent RENAME TO renamed_parent');
  assert(renameDb.select('SELECT value FROM renamed_parent').length == 1);
  assert(
    renameDb.select('SELECT marker FROM old_parent_view').single['marker'] ==
        'FROM old_parent',
  );
  assert(
    renameDb.select('PRAGMA foreign_key_list(old_child)').single['table'] ==
        'renamed_parent',
  );
  assert(
    renameDb
        .select('PRAGMA index_list(renamed_parent)')
        .any((row) => row['name'] == 'old_parent_value_idx'),
  );
  renameDb.execute('UPDATE renamed_parent SET id = 2 WHERE id = 1');
  assert(
    renameDb.select('SELECT parent_id FROM old_child').single['parent_id'] == 2,
  );
  renameDb.execute('BEGIN');
  final schemaVersionBeforeRollback = renameDb
      .select('PRAGMA schema_version')
      .single['schema_version'];
  renameDb.execute('ALTER TABLE renamed_parent RENAME TO temporary_parent');
  assert(
    renameDb.select('PRAGMA schema_version').single['schema_version'] ==
        (schemaVersionBeforeRollback as int) + 1,
  );
  renameDb.execute('ROLLBACK');
  assert(
    renameDb.select('PRAGMA schema_version').single['schema_version'] ==
        schemaVersionBeforeRollback,
  );
  assert(renameDb.select('SELECT id FROM renamed_parent').single['id'] == 2);
  assert(
    renameDb
        .select('PRAGMA index_list(renamed_parent)')
        .any((row) => row['name'] == 'old_parent_value_idx'),
  );

  final renameColumnDb = PureDatabase.memory();
  renameColumnDb.execute('''
    CREATE TABLE rename_column_probe (
      id INTEGER PRIMARY KEY,
      "old value" TEXT,
      note TEXT DEFAULT 'old value'
    )
  ''');
  renameColumnDb.execute(
    "INSERT INTO rename_column_probe VALUES (1, 'kept', NULL)",
  );
  renameColumnDb.execute('''
    ALTER TABLE rename_column_probe RENAME COLUMN "old value" TO "new value"
  ''');
  assert(
    renameColumnDb
            .select('SELECT "new value", note FROM rename_column_probe')
            .single['new value'] ==
        'kept',
  );
  assert(
    renameColumnDb.select(
          'PRAGMA table_info(rename_column_probe)',
        )[1]['name'] ==
        'new value',
  );
  renameColumnDb.execute('BEGIN');
  renameColumnDb.execute('''
    ALTER TABLE rename_column_probe RENAME COLUMN "new value" TO rolled_back
  ''');
  renameColumnDb.execute('ROLLBACK');
  assert(
    renameColumnDb
            .select('SELECT "new value" FROM rename_column_probe')
            .single['new value'] ==
        'kept',
  );

  final dropColumnDb = PureDatabase.memory();
  dropColumnDb.execute('''
    CREATE TABLE drop_column_probe (
      id INTEGER PRIMARY KEY,
      remove_me TEXT,
      keep TEXT DEFAULT 'remove_me'
    )
  ''');
  dropColumnDb.execute(
    "INSERT INTO drop_column_probe VALUES (1, 'gone', 'kept')",
  );
  dropColumnDb.execute('ALTER TABLE drop_column_probe DROP COLUMN remove_me');
  assert(
    dropColumnDb
            .select('SELECT id, keep FROM drop_column_probe')
            .single['keep'] ==
        'kept',
  );
  assert(
    dropColumnDb
            .select('PRAGMA table_info(drop_column_probe)')
            .map((row) => row['name'])
            .join(',') ==
        'id,keep',
  );
  try {
    dropColumnDb.execute('ALTER TABLE drop_column_probe DROP COLUMN id');
    assert(false, 'dropping a primary-key column should fail');
  } on PureSqlException {
    // Expected.
  }

  final joinDb = PureDatabase.memory();
  joinDb.execute('CREATE TABLE join_left (id INTEGER, label TEXT)');
  joinDb.execute('CREATE TABLE join_right (id INTEGER, value TEXT)');
  joinDb.execute("INSERT INTO join_left VALUES (1, 'left'), (2, 'both')");
  joinDb.execute("INSERT INTO join_right VALUES (2, 'both'), (3, 'right')");
  final usingJoin = joinDb.select('''
    SELECT id, join_left.label, join_right.value
    FROM join_left JOIN join_right USING (id)
  ''');
  assert(usingJoin.length == 1);
  assert(usingJoin.single['id'] == 2);
  final naturalJoin = joinDb.select('''
    SELECT join_left.id, join_right.id
    FROM join_left NATURAL INNER JOIN join_right
  ''');
  assert(naturalJoin.length == 1);
  final crossJoin = joinDb.select(
    'SELECT COUNT(*) AS count FROM join_left CROSS JOIN join_right',
  );
  assert(crossJoin.single['count'] == 4);
  final rightJoin = joinDb.select('''
    SELECT join_left.id AS left_id, join_right.id AS right_id
    FROM join_left RIGHT OUTER JOIN join_right USING (id)
    ORDER BY right_id
  ''');
  assert(rightJoin.length == 2);
  assert(rightJoin.first['left_id'] == 2);
  assert(rightJoin.last['left_id'] == null && rightJoin.last['right_id'] == 3);
  final fullJoin = joinDb.select('''
    SELECT id, join_left.id AS left_id, join_right.id AS right_id
    FROM join_left FULL OUTER JOIN join_right USING (id)
    ORDER BY id
  ''');
  assert(fullJoin.length == 3);
  assert(fullJoin.first['id'] == 1 && fullJoin.first['right_id'] == null);
  assert(fullJoin.last['id'] == 3 && fullJoin.last['left_id'] == null);

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
  final cteRows = grouped.select('''
    WITH daily AS (
      SELECT day, SUM(amount) AS total FROM events GROUP BY day
    ), selected AS (
      SELECT day, total FROM daily WHERE total > 2
    )
    SELECT day, total FROM selected ORDER BY day
  ''');
  assert(cteRows.length == 2);
  assert(cteRows.first['day'] == 'a' && cteRows.first['total'] == 5);
  final namedCteColumns = grouped.select('''
    WITH constants(value) AS (SELECT 17)
    SELECT value FROM constants
  ''');
  assert(namedCteColumns.single['value'] == 17);

  assert(db.select('SELECT 1 + 2 AS value').single['value'] == 3);
  assert(db.select('SELECT 1 AS value WHERE 0').isEmpty);
  final operators = db.select('''
    SELECT -5 % 2 AS remainder,
           'a' || 'b' AS concatenated,
           3 BETWEEN 2 AND 4 AS in_range,
           1 NOT BETWEEN 2 AND 4 AS out_of_range,
           'ABC' LIKE 'a%' AS like_match,
           'abc' GLOB 'a*' AS glob_match,
           'abc' REGEXP '^a.c' AS regexp_match,
           'x_y' LIKE 'x!_y' ESCAPE '!' AS escaped_match,
           5 & 3 AS bit_and,
           1 << 3 AS shifted,
           1 IS DISTINCT FROM 2 AS distinct_values
  ''').single;
  assert(operators['remainder'] == -1);
  assert(operators['concatenated'] == 'ab');
  assert(operators['in_range'] == true);
  assert(operators['out_of_range'] == true);
  assert(operators['like_match'] == true);
  assert(operators['glob_match'] == true);
  assert(operators['regexp_match'] == true);
  assert(operators['escaped_match'] == true);
  assert(operators['bit_and'] == 1);
  assert(operators['shifted'] == 8);
  assert(operators['distinct_values'] == true);
  final castAndParameters = db.select(
    '''
    SELECT CAST('123suffix' AS INTEGER) AS integer_cast,
           CAST(2.5 AS TEXT) AS text_cast,
           :shared + :shared AS repeated_name,
           ?4 AS numbered_parameter
  ''',
    [5, null, null, 7],
  );
  assert(castAndParameters.single['integer_cast'] == 123);
  assert(castAndParameters.single['text_cast'] == '2.5');
  assert(castAndParameters.single['repeated_name'] == 10);
  assert(castAndParameters.single['numbered_parameter'] == 7);
  final mapParameters = db
      .select(
        r'''
    SELECT :same + :same AS repeated,
           @answer AS answer,
           $name AS dollar_name
  ''',
        {'same': 4, 'answer': 42, 'name': 'bound'},
      )
      .single;
  assert(mapParameters['repeated'] == 8);
  assert(mapParameters['answer'] == 42);
  assert(mapParameters['dollar_name'] == 'bound');
  db.execute(
    'CREATE TABLE named_bindings (id INTEGER PRIMARY KEY, value TEXT)',
  );
  db.execute('INSERT INTO named_bindings VALUES (:id, :value)', {
    ':id': 11,
    'value': 'map',
  });
  assert(
    db.select('SELECT value FROM named_bindings WHERE id = :id', {
          'id': 11,
        }).single['value'] ==
        'map',
  );
  try {
    db.select('SELECT :required', const {});
    assert(false, 'missing named parameters should fail');
  } on PureSqlException {
    // Expected.
  }
  try {
    db.select('SELECT ?1', {'1': 9});
    assert(false, 'named maps cannot bind numbered parameters');
  } on PureSqlException {
    // Expected.
  }
  final extendedFunctions = db.select('''
    SELECT IIF(1, 'chosen', RANDOMBLOB(16777217)) AS branch,
           LIKELIHOOD(9, 0.2) AS likelihood,
           RANDOM() AS random_value,
           RANDOMBLOB(8) AS random_blob,
           ZEROBLOB(3) AS zero_blob
  ''').single;
  assert(extendedFunctions['branch'] == 'chosen');
  assert(extendedFunctions['likelihood'] == 9);
  assert(extendedFunctions['random_value'] is int);
  assert((extendedFunctions['random_blob'] as List<int>).length == 8);
  assert(
    (extendedFunctions['zero_blob'] as List<int>).every((byte) => byte == 0),
  );
  final mathFunctions = db.select('''
    SELECT PI() AS pi,
           CEIL(1.2) AS ceiling,
           FLOOR(1.9) AS floor,
           LOG(100) AS log10,
           LOG(2, 8) AS log_base,
           LN(EXP(1)) AS natural_log,
           POWER(2, 3) AS power,
           MOD(5, 2) AS remainder,
           SIGN(-5) AS sign,
           SQRT(-1) AS invalid_root,
           SQRT('9') AS numeric_text,
           SQRT('invalid') AS invalid_text
  ''').single;
  assert((mathFunctions['pi'] as double) - 3.141592653589793 < 1e-12);
  assert(mathFunctions['ceiling'] == 2.0);
  assert(mathFunctions['floor'] == 1.0);
  assert(mathFunctions['log10'] == 2.0);
  assert(mathFunctions['log_base'] == 3.0);
  assert((mathFunctions['natural_log'] as double) - 1 < 1e-12);
  assert(mathFunctions['power'] == 8.0);
  assert(mathFunctions['remainder'] == 1.0);
  assert(mathFunctions['sign'] == -1.0);
  assert(mathFunctions['invalid_root'] == null);
  assert(mathFunctions['numeric_text'] == 3.0);
  assert(mathFunctions['invalid_text'] == null);
  db.execute('CREATE TABLE 数据表 (编号 INTEGER PRIMARY KEY, 名称 TEXT)');
  db.execute("INSERT INTO 数据表 VALUES (1, '咖啡')");
  assert(db.select('SELECT 名称 FROM 数据表 WHERE 编号 = 1').single['名称'] == '咖啡');

  final compatible = PureDatabase.memory();
  compatible.execute('''
    CREATE TABLE "group" (
      "group name" TEXT,
      amount INTEGER
    )
  ''');
  compatible.execute('''
    INSERT INTO "group" VALUES ('a', 2), ('a', 3), ('b', 5)
  ''');
  final distinct = compatible.select(
    'SELECT DISTINCT "group name" FROM "group" ORDER BY "group name"',
  );
  assert(distinct.length == 2);
  final having = compatible.select('''
    SELECT "group name", COUNT(*) AS count
    FROM "group"
    GROUP BY "group name"
    HAVING COUNT(*) > 1
  ''');
  assert(having.length == 1 && having.single['count'] == 2);
  final scalarFunctions = compatible.select('''
    SELECT LENGTH('abc') AS len,
           SUBSTR('abcdef', 2, 3) AS middle,
           ABS(-3) AS magnitude,
           ROUND(2.56, 1) AS rounded,
           IFNULL(NULL, 'fallback') AS fallback,
           NULLIF(1, 1) AS null_value
  ''').single;
  assert(scalarFunctions['len'] == 3);
  assert(scalarFunctions['middle'] == 'bcd');
  assert(scalarFunctions['magnitude'] == 3);
  assert(scalarFunctions['rounded'] == 2.6);
  assert(scalarFunctions['fallback'] == 'fallback');
  assert(scalarFunctions['null_value'] == null);
  final aggregateFunctions = compatible.select('''
    SELECT MIN(amount) AS minimum,
           MAX(amount) AS maximum,
           AVG(amount) AS average,
           TOTAL(amount) AS total,
           GROUP_CONCAT("group name", '-') AS names
    FROM "group"
  ''').single;
  assert(aggregateFunctions['minimum'] == 2);
  assert(aggregateFunctions['maximum'] == 5);
  assert(aggregateFunctions['average'] == 10 / 3);
  assert(aggregateFunctions['total'] == 10.0);
  assert(aggregateFunctions['names'] == 'a-a-b');

  assert(
    compatible.select('PRAGMA application_id').single['application_id'] == 0,
  );
  assert(
    compatible.select('PRAGMA freelist_count').single['freelist_count'] == 0,
  );
  assert(
    compatible
        .select('PRAGMA pragma_list')
        .any((row) => row['name'] == 'freelist_count'),
  );
  assert(
    compatible
        .select('PRAGMA pragma_list')
        .any((row) => row['name'] == 'schema_version'),
  );
  final initialSchemaVersion =
      compatible.select('PRAGMA schema_version').single['schema_version']
          as int;
  compatible.execute('CREATE TABLE schema_version_probe (id INTEGER)');
  assert(
    compatible.select('PRAGMA schema_version').single['schema_version'] ==
        initialSchemaVersion + 1,
  );
  compatible.execute(
    'CREATE TABLE IF NOT EXISTS schema_version_probe (id INTEGER)',
  );
  assert(
    compatible.select('PRAGMA schema_version').single['schema_version'] ==
        initialSchemaVersion + 1,
  );
  compatible.execute('PRAGMA schema_version = 100');
  assert(
    compatible.select('PRAGMA schema_version').single['schema_version'] == 100,
  );
  compatible.execute('PRAGMA application_id = 1234');
  assert(
    compatible.select('PRAGMA application_id').single['application_id'] == 1234,
  );
  final columns = compatible.select('PRAGMA table_info("group")');
  assert(columns.length == 2);
  assert(columns.first['name'] == 'group name');
  compatible.execute('''
    CREATE TABLE typed_values (
      code VARCHAR(80),
      amount DOUBLE PRECISION,
      UNIQUE (code, amount)
    )
  ''');
  assert(
    compatible.select('PRAGMA table_info(typed_values)').last['type'] ==
        'DOUBLE PRECISION',
  );
  compatible.execute("INSERT INTO typed_values VALUES ('x', 1.5)");
  try {
    compatible.execute("INSERT INTO typed_values VALUES ('x', 1.5)");
    assert(false, 'table-level UNIQUE should reject duplicates');
  } on PureSqlException {
    // Expected.
  }
  assert(compatible.select('PRAGMA index_list(typed_values)').length == 1);
  assert(
    compatible
            .select('PRAGMA index_info(sqlite_autoindex_typed_values_1)')
            .length ==
        2,
  );
  assert(compatible.select('PRAGMA database_list').single['name'] == 'main');
  final functionList = compatible.select('PRAGMA function_list');
  assert(functionList.isNotEmpty);
  assert(functionList.any((row) => row['name'] == 'LOG'));
  compatible.execute(
    'CREATE TABLE upsert_rows (id INTEGER PRIMARY KEY, value TEXT UNIQUE)',
  );
  compatible.execute("INSERT INTO upsert_rows VALUES (1, 'first')");
  assert(
    compatible.execute(
          "INSERT INTO upsert_rows VALUES (1, 'ignored') ON CONFLICT(id) DO NOTHING",
        ) ==
        0,
  );
  assert(
    compatible.execute(
          "INSERT INTO upsert_rows VALUES (2, 'first') ON CONFLICT DO NOTHING",
        ) ==
        0,
  );
  assert(
    compatible.select('PRAGMA integrity_check').single['integrity_check'] ==
        'ok',
  );
  compatible.execute('''
    CREATE VIEW larger_groups(group_name) AS
      SELECT "group name" FROM "group" WHERE amount > 2
  ''');
  assert(compatible.select('SELECT group_name FROM larger_groups').length == 2);
  assert(compatible.select('PRAGMA table_info(larger_groups)').length == 1);
  assert(
    compatible
        .select('PRAGMA table_list')
        .any((row) => row['name'] == 'larger_groups' && row['type'] == 'view'),
  );
  compatible.execute('DROP VIEW larger_groups');
  compatible.execute('CREATE VIEW all_group_fields AS SELECT * FROM "group"');
  assert(
    compatible
            .select('PRAGMA table_list')
            .singleWhere((row) => row['name'] == 'all_group_fields')['ncol'] ==
        2,
  );
  compatible.execute('DROP VIEW all_group_fields');
  compatible.execute('''
    /* semicolons inside comments are ignored; */
    CREATE TABLE scripts (value TEXT);
    INSERT INTO scripts VALUES ('first;second');
    UPDATE scripts SET value = value || '-done';
  ''');
  assert(
    compatible.select('SELECT value FROM scripts').single['value'] ==
        'first;second-done',
  );
  compatible.execute('CREATE TABLE dropped_table (id INTEGER PRIMARY KEY)');
  compatible.execute('CREATE INDEX dropped_index ON dropped_table(id)');
  compatible.execute('DROP INDEX dropped_index');
  compatible.execute('DROP TABLE dropped_table');
  compatible.execute('DROP TABLE IF EXISTS missing_table');
  try {
    compatible.select('SELECT * FROM dropped_table');
    assert(false, 'dropped table should not be visible');
  } on PureSqlException {
    // Expected.
  }
  compatible.execute(
    'CREATE TABLE defaults (id INTEGER PRIMARY KEY, value TEXT DEFAULT \'seed\')',
  );
  compatible.execute('INSERT INTO defaults DEFAULT VALUES');
  assert(
    compatible.select('SELECT value FROM defaults').single['value'] == 'seed',
  );
  compatible.execute('CREATE TABLE copies (value TEXT)');
  compatible.execute('INSERT INTO copies SELECT value FROM scripts');
  assert(
    compatible.select('SELECT value FROM copies').single['value'] ==
        'first;second-done',
  );
  compatible.execute('CREATE TABLE wanted (value TEXT)');
  compatible.execute("INSERT INTO wanted VALUES ('a'), ('missing')");
  final subqueryResults = compatible.select('''
    SELECT "group name",
           "group name" IN (SELECT value FROM wanted) AS wanted,
           EXISTS (SELECT 1 FROM wanted WHERE wanted.value = "group"."group name") AS exists_match,
           NOT EXISTS (SELECT 1 FROM wanted WHERE wanted.value = 'never') AS exists_empty
    FROM "group"
    ORDER BY "group name", amount
  ''');
  assert(subqueryResults.length == 3);
  assert(subqueryResults.first['wanted'] == true);
  assert(subqueryResults.first['exists_match'] == true);
  assert(subqueryResults.first['exists_empty'] == true);
  assert(subqueryResults.last['wanted'] == false);
  final filteredBySubquery = compatible.select('''
    SELECT "group name"
    FROM "group" AS g
    WHERE EXISTS (
      SELECT 1 FROM wanted WHERE wanted.value = g."group name"
    )
  ''');
  assert(filteredBySubquery.length == 2);
  final joinSubquery = compatible.select('''
    SELECT g."group name", wanted.value
    FROM "group" AS g JOIN wanted
      ON EXISTS (SELECT 1 FROM wanted AS nested WHERE nested.value = g."group name")
  ''');
  assert(joinSubquery.length == 4);
  final nestedSubqueryFunction = compatible.select('''
    SELECT IIF(EXISTS (SELECT 1 FROM wanted WHERE value = 'a'), 'yes', 'no') AS found
  ''').single;
  assert(nestedSubqueryFunction['found'] == 'yes');
  final groupedSubquery = compatible.select('''
    SELECT "group name", COUNT(*) AS count
    FROM "group"
    GROUP BY "group name"
    HAVING EXISTS (
      SELECT 1 FROM wanted WHERE wanted.value = "group"."group name"
    )
  ''');
  assert(groupedSubquery.length == 1);
  assert(groupedSubquery.single['group name'] == 'a');
  assert(groupedSubquery.single['count'] == 2);
  final scalarSubqueryFunction = compatible.select('''
    SELECT IFNULL((SELECT value FROM wanted WHERE value = 'absent'), 'empty') AS value
  ''').single;
  assert(scalarSubqueryFunction['value'] == 'empty');
  final compoundRows = compatible.select('''
    SELECT 1 AS value
    UNION SELECT 1
    UNION ALL SELECT 2
    ORDER BY value DESC
    LIMIT 2
  ''');
  assert(compoundRows.map((row) => row['value']).join(',') == '2,1');
  final intersectPrecedence = compatible.select('''
    SELECT 1 AS value UNION SELECT 2 INTERSECT SELECT 2
  ''');
  assert(intersectPrecedence.map((row) => row['value']).join(',') == '1,2');
  final exceptRows = compatible.select('''
    SELECT 1 AS value UNION ALL SELECT 2 EXCEPT SELECT 2
  ''');
  assert(exceptRows.length == 1 && exceptRows.single['value'] == 1);
  try {
    compatible.select('SELECT 1 UNION SELECT 1, 2');
    assert(false, 'compound terms with different arity should fail');
  } on PureSqlException {
    // Expected.
  }
  final derivedTable = compatible.select('''
    SELECT d.name, d.total
    FROM (
      SELECT "group name" AS name, SUM(amount) AS total
      FROM "group"
      GROUP BY "group name"
    ) AS d
    WHERE d.total >= 5
  ''');
  assert(derivedTable.length == 2);
  final qualifiedDerivedColumn = compatible.select('''
    SELECT d."group name"
    FROM (SELECT "group"."group name" FROM "group") AS d
    ORDER BY 1
  ''');
  assert(qualifiedDerivedColumn.first.values.single == 'a');
  final joinedDerivedTables = compatible.select('''
    SELECT names.name, wanted.value
    FROM (SELECT DISTINCT "group name" AS name FROM "group") AS names
    LEFT JOIN (SELECT value FROM wanted) AS wanted ON names.name = wanted.value
    ORDER BY names.name
  ''');
  assert(joinedDerivedTables.length == 2);
  assert(joinedDerivedTables.first['wanted.value'] == 'a');
  assert(joinedDerivedTables.last['wanted.value'] == null);
  final subqueryNull = compatible.select('''
    SELECT NULL IN (SELECT value FROM wanted) AS in_null,
           NULL NOT IN (SELECT value FROM wanted) AS not_in_null,
           NULL IN (SELECT value FROM wanted WHERE value = 'absent') AS in_empty
  ''').single;
  assert(subqueryNull['in_null'] == null);
  assert(subqueryNull['not_in_null'] == null);
  assert(subqueryNull['in_empty'] == false);
  assert(
    compatible
            .select("SELECT NULL NOT IN (SELECT value FROM wanted WHERE 0)")
            .single
            .values
            .single ==
        true,
  );
  try {
    compatible.select('SELECT 1 IN (SELECT value, value FROM wanted)');
    assert(false, 'IN subquery must return exactly one column');
  } on PureSqlException {
    // Expected.
  }
}
