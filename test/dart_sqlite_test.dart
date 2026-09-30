import 'package:dart_sqlite/dart_sqlite.dart';

void main() {
  final db = PureDatabase.memory();
  db.execute('PRAGMA page_size = 8192');
  assert(db.select('PRAGMA page_size').single['page_size'] == 8192);
  db.execute('BEGIN');
  db.execute('PRAGMA page_size = 4096');
  assert(db.select('PRAGMA page_size').single['page_size'] == 4096);
  db.execute('ROLLBACK');
  assert(db.select('PRAGMA page_size').single['page_size'] == 8192);
  db.execute('''
    CREATE TABLE users (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      active INTEGER
    )
  ''');
  db.execute('PRAGMA page_size = 4096');
  assert(db.select('PRAGMA page_size').single['page_size'] == 8192);

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

  final savepointDb = PureDatabase.memory()
    ..execute('CREATE TABLE savepoint_rows (id INTEGER)')
    ..execute('INSERT INTO savepoint_rows VALUES (1)');
  savepointDb.execute('SAVEPOINT outer');
  savepointDb.execute('INSERT INTO savepoint_rows VALUES (2)');
  savepointDb.execute('SAVEPOINT inner');
  savepointDb.execute('INSERT INTO savepoint_rows VALUES (3)');
  savepointDb.execute('ROLLBACK TRANSACTION TO SAVEPOINT inner');
  savepointDb.execute('INSERT INTO savepoint_rows VALUES (4)');
  savepointDb.execute('RELEASE SAVEPOINT inner');
  assert(
    savepointDb
            .select('SELECT id FROM savepoint_rows ORDER BY id')
            .map((row) => row['id'])
            .join(',') ==
        '1,2,4',
  );
  savepointDb.execute('ROLLBACK TO outer');
  assert(
    savepointDb
            .select('SELECT id FROM savepoint_rows ORDER BY id')
            .map((row) => row['id'])
            .join(',') ==
        '1',
  );
  savepointDb.execute('INSERT INTO savepoint_rows VALUES (5)');
  savepointDb.execute('RELEASE outer');
  assert(
    savepointDb
            .select('SELECT id FROM savepoint_rows ORDER BY id')
            .map((row) => row['id'])
            .join(',') ==
        '1,5',
  );
  savepointDb.execute('BEGIN');
  savepointDb.execute('ROLLBACK');

  savepointDb.execute('SAVEPOINT duplicate');
  savepointDb.execute('INSERT INTO savepoint_rows VALUES (6)');
  savepointDb.execute('SAVEPOINT DUPLICATE');
  savepointDb.execute('INSERT INTO savepoint_rows VALUES (7)');
  savepointDb.execute('ROLLBACK TO duplicate');
  assert(
    savepointDb
            .select('SELECT id FROM savepoint_rows ORDER BY id')
            .map((row) => row['id'])
            .join(',') ==
        '1,5,6',
  );
  savepointDb.execute('RELEASE duplicate');
  savepointDb.execute('RELEASE duplicate');
  assert(
    savepointDb
            .select('SELECT id FROM savepoint_rows ORDER BY id')
            .map((row) => row['id'])
            .join(',') ==
        '1,5,6',
  );
  savepointDb.execute('BEGIN');
  savepointDb.execute('SAVEPOINT nested_transaction');
  savepointDb.execute('INSERT INTO savepoint_rows VALUES (8)');
  savepointDb.execute('RELEASE nested_transaction');
  savepointDb.execute('ROLLBACK');
  assert(
    savepointDb
            .select('SELECT id FROM savepoint_rows ORDER BY id')
            .map((row) => row['id'])
            .join(',') ==
        '1,5,6',
  );
  savepointDb.execute('SAVEPOINT schema_rollback');
  savepointDb.execute('CREATE TABLE savepoint_ddl (id INTEGER)');
  savepointDb.execute('ROLLBACK TO schema_rollback');
  savepointDb.execute('RELEASE schema_rollback');
  try {
    savepointDb.select('SELECT * FROM savepoint_ddl');
    assert(false, 'ROLLBACK TO must undo schema changes');
  } on PureSqlException {
    // Expected.
  }

  final createAsDb = PureDatabase.memory()
    ..execute('CREATE TABLE source_rows (id, label)')
    ..execute("INSERT INTO source_rows VALUES (1, 'one'), (2, 'two')");
  createAsDb.execute('CREATE INDEX source_rows_label ON source_rows(label)');
  final pragmaTableInfo = createAsDb.select(
    '''
    SELECT pragma.cid AS cid, pragma.name AS name
    FROM pragma_table_info(?, ?) AS pragma
    ORDER BY pragma.cid
  ''',
    ['source_rows', 'main'],
  );
  assert(pragmaTableInfo.map((row) => row['name']).join(',') == 'id,label');
  assert(
    createAsDb
            .select(
              "SELECT name FROM main.pragma_table_info('source_rows') ORDER BY cid",
            )
            .map((row) => row['name'])
            .join(',') ==
        'id,label',
  );
  assert(
    createAsDb
            .select("SELECT name FROM pragma_index_list('source_rows')")
            .single['name'] ==
        'source_rows_label',
  );
  assert(
    createAsDb
            .select(
              "SELECT COUNT(*) AS n FROM pragma_function_list() WHERE name = 'COUNT'",
            )
            .single['n'] ==
        2,
  );
  assert(
    createAsDb
            .select('SELECT * FROM pragma_integrity_check()')
            .single['integrity_check'] ==
        'ok',
  );
  assert(
    createAsDb
            .select(
              "SELECT * FROM pragma_integrity_check('source_rows', 'main')",
            )
            .single['integrity_check'] ==
        'ok',
  );
  assert(
    createAsDb.select("SELECT * FROM pragma_table_info('missing')").isEmpty,
  );
  assert(
    createAsDb
            .select("SELECT name FROM pragma_table_list('source_rows')")
            .single['name'] ==
        'source_rows',
  );
  final pragmaValues = createAsDb.select('''
    SELECT page_count.page_count AS page_count,
           encoding.encoding AS encoding,
           auto_vacuum.auto_vacuum AS auto_vacuum,
           freelist_count.freelist_count AS freelist_count
    FROM pragma_page_count() AS page_count
    CROSS JOIN pragma_encoding() AS encoding
    CROSS JOIN pragma_auto_vacuum() AS auto_vacuum
    CROSS JOIN pragma_freelist_count() AS freelist_count
  ''').single;
  assert(pragmaValues['page_count'] == 0);
  assert(pragmaValues['encoding'] == 'UTF-8');
  assert(pragmaValues['auto_vacuum'] == 0);
  assert(
    createAsDb.select('PRAGMA data_version').single['data_version'] == 1,
    'in-memory databases have no external change counter',
  );
  assert(
    createAsDb
            .select('SELECT data_version FROM pragma_data_version()')
            .single['data_version'] ==
        1,
  );
  assert(pragmaValues['freelist_count'] == 0);
  createAsDb.execute('''
    CREATE TABLE copied_rows AS
    SELECT id, label AS copied_label FROM source_rows ORDER BY id DESC
  ''');
  createAsDb.execute('''
    CREATE TABLE cte_copied_rows AS
    WITH selected AS (SELECT id, label FROM source_rows)
    SELECT id, label FROM selected
  ''');
  assert(
    createAsDb
            .select('SELECT label FROM cte_copied_rows ORDER BY id')
            .map((row) => row['label'])
            .join(',') ==
        'one,two',
  );
  assert(
    createAsDb
            .select('SELECT * FROM copied_rows')
            .map((row) => row['copied_label'])
            .join(',') ==
        'two,one',
  );
  assert(
    createAsDb
            .select('PRAGMA table_info(copied_rows)')
            .map((row) => row['name'])
            .join(',') ==
        'id,copied_label',
  );
  createAsDb.execute('''
    CREATE TABLE empty_copy AS SELECT id, label FROM source_rows WHERE 0
  ''');
  assert(createAsDb.select('SELECT * FROM empty_copy').isEmpty);
  assert(createAsDb.select('PRAGMA table_info(empty_copy)').length == 2);
  createAsDb.execute('''
    CREATE TABLE ctas_type_source (
      integer_value INTEGER,
      text_value TEXT,
      numeric_value NUMERIC,
      real_value REAL,
      blob_value BLOB
    )
  ''');
  createAsDb.execute('''
    CREATE TABLE ctas_type_copy AS
    SELECT integer_value, text_value, numeric_value, real_value, blob_value,
           CAST(integer_value AS INTEGER) AS cast_integer,
           CAST(text_value AS VARCHAR(20)) AS cast_text,
           (integer_value) AS parenthesized,
           +integer_value AS unary_plus,
           integer_value + 1 AS calculated
    FROM ctas_type_source WHERE 0
  ''');
  assert(
    createAsDb
            .select('PRAGMA table_info(ctas_type_copy)')
            .map((row) => row['type'])
            .join(',') ==
        'INT,TEXT,NUM,REAL,,INT,TEXT,INT,,',
  );
  createAsDb.execute('''
    CREATE TABLE ctas_type_star AS
    SELECT * FROM ctas_type_source WHERE 0
  ''');
  assert(
    createAsDb
            .select('PRAGMA table_info(ctas_type_star)')
            .map((row) => row['type'])
            .join(',') ==
        'INT,TEXT,NUM,REAL,',
  );
  createAsDb.execute('''
    CREATE TABLE ctas_type_cte AS
    WITH typed AS (SELECT integer_value FROM ctas_type_source)
    SELECT integer_value FROM typed WHERE 0
  ''');
  assert(
    createAsDb.select('PRAGMA table_info(ctas_type_cte)').single['type'] ==
        'INT',
  );
  createAsDb.execute('''
    CREATE VIEW ctas_type_view AS
    SELECT integer_value, CAST(text_value AS DOUBLE) AS cast_real
    FROM ctas_type_source
  ''');
  assert(
    createAsDb
            .select('PRAGMA table_info(ctas_type_view)')
            .map((row) => row['type'])
            .join(',') ==
        'INT,REAL',
  );
  createAsDb.execute('''
    CREATE TABLE duplicate_copy AS
    SELECT id AS repeated, id + 10 AS repeated FROM source_rows ORDER BY id
  ''');
  final duplicateColumns = createAsDb.select(
    'SELECT repeated, "repeated:1" FROM duplicate_copy ORDER BY repeated',
  );
  assert(duplicateColumns[0]['repeated'] == 1);
  assert(duplicateColumns[0]['repeated:1'] == 11);
  assert(duplicateColumns[1]['repeated'] == 2);
  assert(duplicateColumns[1]['repeated:1'] == 12);
  createAsDb.execute('''
    CREATE TABLE IF NOT EXISTS copied_rows AS SELECT 99 AS ignored
  ''');
  assert(createAsDb.select('PRAGMA table_info(copied_rows)').length == 2);
  createAsDb.execute(
    'CREATE TABLE parameter_copy AS SELECT ? AS value, :label AS label',
    {'1': 7, 'label': 'bound'},
  );
  final parameterCopy = createAsDb
      .select('SELECT * FROM parameter_copy')
      .single;
  assert(parameterCopy['value'] == 7);
  assert(parameterCopy['label'] == 'bound');

  final temporaryDb = PureDatabase.memory()
    ..execute('CREATE TABLE shadowed_rows (value TEXT)')
    ..execute('CREATE TABLE main_trigger_log (value TEXT)')
    ..execute('''
      CREATE TRIGGER main_shadow_trigger AFTER INSERT ON shadowed_rows BEGIN
        INSERT INTO main_trigger_log VALUES (NEW.value);
      END
    ''')
    ..execute("INSERT INTO shadowed_rows VALUES ('main')")
    ..execute('CREATE TEMP TABLE shadowed_rows (value TEXT)')
    ..execute('''
      CREATE TEMP TABLE temporary_rows (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        value TEXT
      )
    ''')
    ..execute(
      'CREATE TEMP UNIQUE INDEX temporary_value_idx ON temporary_rows(value)',
    )
    ..execute('CREATE TEMP TABLE temporary_log (value TEXT)')
    ..execute('''
      CREATE TEMP TRIGGER temporary_rows_trigger AFTER INSERT ON temporary_rows BEGIN
        INSERT INTO temporary_log VALUES (NEW.value);
      END
    ''')
    ..execute("INSERT INTO shadowed_rows VALUES ('temp')")
    ..execute("INSERT INTO temporary_rows (value) VALUES ('one')");
  assert(
    temporaryDb.select('SELECT value FROM shadowed_rows').single['value'] ==
        'temp',
  );
  assert(temporaryDb.select('SELECT * FROM main_trigger_log').length == 1);
  assert(temporaryDb.select('SELECT id FROM temporary_rows').single['id'] == 1);
  assert(
    temporaryDb.select('SELECT * FROM temporary_log').single['value'] == 'one',
  );
  assert(
    temporaryDb.select('PRAGMA index_list(temporary_rows)').single['name'] ==
        'temporary_value_idx',
  );
  assert(
    temporaryDb
            .select('PRAGMA index_info(temporary_value_idx)')
            .single['name'] ==
        'value',
  );
  assert(
    temporaryDb
            .select('PRAGMA table_list')
            .where((row) => row['schema'] == 'temp')
            .length ==
        3,
  );
  try {
    temporaryDb.execute("INSERT INTO temporary_rows (value) VALUES ('one')");
    assert(false, 'TEMP unique index should reject duplicate values');
  } on PureSqlException {
    // Expected.
  }
  temporaryDb.execute('DROP INDEX temporary_value_idx');
  assert(temporaryDb.select('PRAGMA index_list(temporary_rows)').isEmpty);
  temporaryDb.execute('DROP TABLE shadowed_rows');
  assert(
    temporaryDb.select('SELECT value FROM shadowed_rows').single['value'] ==
        'main',
  );
  temporaryDb.execute(
    'CREATE TEMP TABLE temporary_copy AS SELECT value FROM temporary_rows',
  );
  assert(
    temporaryDb.select('SELECT value FROM temporary_copy').single['value'] ==
        'one',
  );
  try {
    temporaryDb.transaction((database) {
      database.execute(
        "INSERT INTO temporary_rows (value) VALUES ('rolled back')",
      );
      database.execute('DROP TABLE temporary_log');
      database.execute(
        'CREATE TEMP VIEW rolled_back_view AS SELECT value FROM temporary_rows',
      );
      throw StateError('rollback temporary schema and rows');
    });
  } on StateError {
    // Expected.
  }
  assert(temporaryDb.select('SELECT * FROM temporary_log').length == 1);
  assert(temporaryDb.select('SELECT * FROM temporary_rows').length == 1);
  assert(
    temporaryDb
        .select('PRAGMA table_list')
        .every((row) => row['name'] != 'rolled_back_view'),
  );

  final temporaryViewDb = PureDatabase.memory()
    ..execute('CREATE TABLE view_source (value TEXT)')
    ..execute("INSERT INTO view_source VALUES ('main'), ('temp')")
    ..execute(
      "CREATE VIEW scoped_view AS SELECT value FROM view_source WHERE value = 'main'",
    )
    ..execute(
      "CREATE TEMP VIEW scoped_view AS SELECT value FROM view_source WHERE value = 'temp'",
    )
    ..execute('CREATE TEMP TABLE writable_view_target (value TEXT)')
    ..execute(
      'CREATE TEMP VIEW writable_view AS SELECT value FROM writable_view_target',
    )
    ..execute('''
      CREATE TEMP TRIGGER writable_view_insert INSTEAD OF INSERT ON writable_view BEGIN
        INSERT INTO writable_view_target VALUES (NEW.value);
      END
    ''')
    ..execute("INSERT INTO writable_view VALUES ('written')");
  assert(
    temporaryViewDb.select('SELECT value FROM scoped_view').single['value'] ==
        'temp',
  );
  assert(
    temporaryViewDb
            .select('PRAGMA table_list')
            .where((row) => row['schema'] == 'temp' && row['type'] == 'view')
            .length ==
        2,
  );
  assert(
    temporaryViewDb
            .select('SELECT value FROM writable_view_target')
            .single['value'] ==
        'written',
  );
  temporaryViewDb.execute('DROP VIEW scoped_view');
  assert(
    temporaryViewDb.select('SELECT value FROM scoped_view').single['value'] ==
        'main',
  );
  temporaryViewDb
    ..execute(
      'CREATE TEMP TABLE alter_source (id INTEGER PRIMARY KEY, value TEXT)',
    )
    ..execute('CREATE TEMP TABLE alter_audit (value TEXT)')
    ..execute('''
      CREATE TEMP TRIGGER alter_source_insert AFTER INSERT ON alter_source BEGIN
        INSERT INTO alter_audit VALUES (NEW.value);
      END
    ''')
    ..execute(
      'CREATE TEMP VIEW alter_source_view AS SELECT value FROM alter_source',
    )
    ..execute("INSERT INTO alter_source VALUES (1, 'before')")
    ..execute('ALTER TABLE alter_source RENAME TO alter_target')
    ..execute("ALTER TABLE alter_target ADD COLUMN scratch TEXT DEFAULT 'x'")
    ..execute('ALTER TABLE alter_target RENAME COLUMN scratch TO transient')
    ..execute('ALTER TABLE alter_target DROP COLUMN transient')
    ..execute("INSERT INTO alter_target VALUES (2, 'after')");
  assert(
    temporaryViewDb
            .select('SELECT value FROM alter_source_view ORDER BY value')
            .map((row) => row['value'])
            .join(',') ==
        'after,before',
  );
  assert(
    temporaryViewDb
            .select('SELECT value FROM alter_audit ORDER BY value')
            .map((row) => row['value'])
            .join(',') ==
        'after,before',
  );

  final addColumnConstraintsDb = PureDatabase.memory()
    ..execute('PRAGMA foreign_keys = ON')
    ..execute('CREATE TABLE add_column_parent (id INTEGER PRIMARY KEY)')
    ..execute('CREATE TABLE add_column_child (id INTEGER PRIMARY KEY)')
    ..execute('INSERT INTO add_column_child VALUES (1)')
    ..execute('''
      ALTER TABLE add_column_child
      ADD COLUMN state TEXT NOT NULL DEFAULT 'ready'
      CHECK (state IN ('ready', 'done'))
    ''')
    ..execute('''
      ALTER TABLE add_column_child
      ADD COLUMN parent_id INTEGER REFERENCES add_column_parent(id)
      ON DELETE CASCADE DEFAULT NULL
    ''');
  assert(
    addColumnConstraintsDb
            .select('SELECT state FROM add_column_child')
            .single['state'] ==
        'ready',
  );
  assert(
    addColumnConstraintsDb
            .select('PRAGMA foreign_key_list(add_column_child)')
            .single['on_delete'] ==
        'CASCADE',
  );
  addColumnConstraintsDb
    ..execute('INSERT INTO add_column_parent VALUES (10)')
    ..execute('UPDATE add_column_child SET parent_id = 10 WHERE id = 1')
    ..execute('DELETE FROM add_column_parent WHERE id = 10');
  assert(
    addColumnConstraintsDb.select('SELECT * FROM add_column_child').isEmpty,
  );

  final rejectedAddCheckDb = PureDatabase.memory()
    ..execute('CREATE TABLE rejected_add_check (id INTEGER)')
    ..execute('INSERT INTO rejected_add_check VALUES (1)');
  var addCheckRejected = false;
  try {
    rejectedAddCheckDb.execute('''
      ALTER TABLE rejected_add_check
      ADD COLUMN state TEXT DEFAULT 'bad' CHECK (state <> 'bad')
    ''');
  } on SqliteException catch (error) {
    addCheckRejected = error.message.startsWith('CHECK constraint failed');
  }
  assert(addCheckRejected);
  assert(
    rejectedAddCheckDb.select('PRAGMA table_info(rejected_add_check)').length ==
        1,
  );

  final rejectedAddReferenceDb = PureDatabase.memory()
    ..execute('PRAGMA foreign_keys = ON')
    ..execute('CREATE TABLE rejected_add_parent (id INTEGER PRIMARY KEY)')
    ..execute('CREATE TABLE rejected_add_child (id INTEGER)')
    ..execute('INSERT INTO rejected_add_child VALUES (1)');
  var addReferenceRejected = false;
  try {
    rejectedAddReferenceDb.execute('''
      ALTER TABLE rejected_add_child
      ADD COLUMN parent_id INTEGER DEFAULT 1 REFERENCES rejected_add_parent(id)
    ''');
  } on SqliteException catch (error) {
    addReferenceRejected = error.message.contains('non-NULL default');
  }
  assert(addReferenceRejected);
  assert(
    rejectedAddReferenceDb
            .select('PRAGMA table_info(rejected_add_child)')
            .length ==
        1,
  );

  final temporaryForeignKeyDb = PureDatabase.memory()
    ..execute('PRAGMA foreign_keys = ON')
    ..execute('CREATE TEMP TABLE temporary_parent (id INTEGER PRIMARY KEY)')
    ..execute('''
      CREATE TEMP TABLE temporary_child (
        parent_id INTEGER REFERENCES temporary_parent(id) ON DELETE CASCADE
      )
    ''')
    ..execute('INSERT INTO temporary_parent VALUES (1)')
    ..execute('INSERT INTO temporary_child VALUES (1)');
  try {
    temporaryForeignKeyDb.execute('INSERT INTO temporary_child VALUES (2)');
    assert(false, 'TEMP foreign keys should reject missing parent rows');
  } on PureSqlException {
    // Expected.
  }
  temporaryForeignKeyDb.execute('DELETE FROM temporary_parent WHERE id = 1');
  assert(temporaryForeignKeyDb.select('SELECT * FROM temporary_child').isEmpty);
  assert(temporaryForeignKeyDb.select('PRAGMA foreign_key_check').isEmpty);

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

  final queryOnlyDb = PureDatabase.memory()
    ..execute('CREATE TABLE query_only_rows (value INTEGER)')
    ..execute('INSERT INTO query_only_rows VALUES (1)')
    ..execute('PRAGMA query_only = ON');
  assert(queryOnlyDb.select('PRAGMA query_only').single['query_only'] == 1);
  assert(
    queryOnlyDb.select('SELECT value FROM query_only_rows').single['value'] ==
        1,
  );
  assert(
    queryOnlyDb
        .select('PRAGMA pragma_list')
        .any((row) => row['name'] == 'query_only'),
  );
  queryOnlyDb.execute('PRAGMA foreign_keys = ON');
  assert(queryOnlyDb.select('PRAGMA foreign_keys').single['foreign_keys'] == 1);
  queryOnlyDb.execute('PRAGMA cache_size = -256');
  assert(queryOnlyDb.select('PRAGMA cache_size').single['cache_size'] == -256);
  for (final write in [
    'INSERT INTO query_only_rows VALUES (2)',
    'UPDATE query_only_rows SET value = 2',
    'DELETE FROM query_only_rows',
    'CREATE TABLE query_only_blocked (value INTEGER)',
    'ANALYZE',
    'PRAGMA user_version = 3',
    'PRAGMA default_cache_size = 20',
  ]) {
    try {
      queryOnlyDb.execute(write);
      assert(false, 'query_only must reject: $write');
    } on PureSqlException {
      // Read queries and connection-local PRAGMAs remain available.
    }
  }
  queryOnlyDb.execute('PRAGMA query_only = OFF');
  queryOnlyDb.execute('INSERT INTO query_only_rows VALUES (2)');
  assert(
    queryOnlyDb
            .select('SELECT COUNT(*) AS count FROM query_only_rows')
            .single['count'] ==
        2,
  );

  final triggerDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE trigger_source (id INTEGER PRIMARY KEY, value TEXT)',
    )
    ..execute(
      'CREATE TABLE trigger_audit (event TEXT, old_value TEXT, new_value TEXT)',
    );
  triggerDb.execute('''
    CREATE TRIGGER trigger_source_insert AFTER INSERT ON trigger_source
    BEGIN
      INSERT INTO trigger_audit SELECT 'insert', NULL, NEW.value;
    END;
    CREATE TRIGGER trigger_source_update AFTER UPDATE OF value ON trigger_source
    WHEN OLD.value <> NEW.value
    BEGIN
      INSERT INTO trigger_audit VALUES ('update', OLD.value, NEW.value);
    END;
    CREATE TRIGGER trigger_source_delete AFTER DELETE ON trigger_source
    BEGIN
      INSERT INTO trigger_audit VALUES ('delete', OLD.value, NULL);
    END;
  ''');
  assert(
    triggerDb.execute("INSERT INTO trigger_source VALUES (1, 'one')") == 1,
  );
  assert(
    triggerDb
            .select('SELECT changes() AS changes, total_changes() AS total')
            .single['changes'] ==
        1,
  );
  assert(
    triggerDb
            .select('SELECT changes() AS changes, total_changes() AS total')
            .single['total'] ==
        2,
  );
  triggerDb.execute('UPDATE trigger_source SET id = 2 WHERE id = 1');
  triggerDb.execute("UPDATE trigger_source SET value = 'two' WHERE id = 2");
  triggerDb.execute("UPDATE trigger_source SET value = 'two' WHERE id = 2");
  triggerDb.execute('DELETE FROM trigger_source WHERE id = 2');
  final triggerEvents = triggerDb.select(
    'SELECT event, old_value, new_value FROM trigger_audit',
  );
  assert(triggerEvents.length == 3);
  assert(triggerEvents[0]['event'] == 'insert');
  assert(triggerEvents[0]['new_value'] == 'one');
  assert(triggerEvents[1]['event'] == 'update');
  assert(triggerEvents[1]['old_value'] == 'one');
  assert(triggerEvents[1]['new_value'] == 'two');
  assert(triggerEvents[2]['event'] == 'delete');
  assert(triggerEvents[2]['old_value'] == 'two');
  triggerDb.execute('DROP TRIGGER trigger_source_update');
  triggerDb.execute('DROP TABLE trigger_source');
  assert(triggerDb.select('SELECT * FROM trigger_audit').length == 3);
  triggerDb
    ..execute(
      'CREATE TABLE trigger_source (id INTEGER PRIMARY KEY, value TEXT)',
    )
    ..execute('''
      CREATE TRIGGER trigger_source_delete AFTER DELETE ON trigger_source
      BEGIN INSERT INTO trigger_audit VALUES ('delete', OLD.value, NULL); END
    ''');

  final triggerRenameDb = PureDatabase.memory()
    ..execute('CREATE TABLE trigger_rename_source (id INTEGER, value TEXT)')
    ..execute('CREATE TABLE trigger_rename_audit (value TEXT)')
    ..execute('''
      CREATE TRIGGER trigger_rename_ai AFTER INSERT ON trigger_rename_source
      BEGIN
        INSERT INTO trigger_rename_audit
        SELECT value FROM trigger_rename_source WHERE id = NEW.id;
      END
    ''')
    ..execute(
      'ALTER TABLE trigger_rename_source RENAME TO trigger_renamed_source',
    )
    ..execute("INSERT INTO trigger_renamed_source VALUES (1, 'renamed')");
  assert(
    triggerRenameDb
            .select('SELECT value FROM trigger_rename_audit')
            .single['value'] ==
        'renamed',
  );

  final triggerRollbackDb = PureDatabase.memory();
  try {
    triggerRollbackDb.transaction((database) {
      database.execute('CREATE TABLE trigger_rollback (value INTEGER)');
      database.execute('''
        CREATE TRIGGER trigger_rollback_ai AFTER INSERT ON trigger_rollback
        BEGIN INSERT INTO trigger_rollback VALUES (NEW.value); END
      ''');
      throw StateError('rollback trigger schema');
    });
  } on StateError {
    // Expected; in-memory transaction rollback restores trigger metadata.
  }
  triggerRollbackDb
    ..execute('CREATE TABLE trigger_rollback (value INTEGER)')
    ..execute('''
      CREATE TRIGGER trigger_rollback_ai AFTER INSERT ON trigger_rollback
      BEGIN INSERT INTO trigger_rollback VALUES (NEW.value); END
    ''');

  final recursiveTriggerDb = PureDatabase.memory()
    ..execute('CREATE TABLE recursive_trigger_rows (value INTEGER)')
    ..execute('''
      CREATE TRIGGER recursive_trigger_ai AFTER INSERT ON recursive_trigger_rows
      WHEN NEW.value < 3
      BEGIN
        INSERT INTO recursive_trigger_rows VALUES (NEW.value + 1);
      END
    ''');
  assert(
    recursiveTriggerDb
            .select('PRAGMA recursive_triggers')
            .single['recursive_triggers'] ==
        0,
  );
  assert(
    recursiveTriggerDb
        .select('PRAGMA pragma_list')
        .any((row) => row['name'] == 'recursive_triggers'),
  );
  recursiveTriggerDb.execute('INSERT INTO recursive_trigger_rows VALUES (1)');
  assert(
    recursiveTriggerDb
            .select('SELECT COUNT(*) AS count FROM recursive_trigger_rows')
            .single['count'] ==
        2,
  );
  recursiveTriggerDb
    ..execute('DELETE FROM recursive_trigger_rows')
    ..execute('PRAGMA recursive_triggers = ON')
    ..execute('INSERT INTO recursive_trigger_rows VALUES (1)');
  assert(
    recursiveTriggerDb
            .select('SELECT COUNT(*) AS count FROM recursive_trigger_rows')
            .single['count'] ==
        3,
  );

  final cascadeTriggerDb = PureDatabase.memory()
    ..execute('CREATE TABLE cascade_trigger_parent (id INTEGER PRIMARY KEY)')
    ..execute('''
      CREATE TABLE cascade_trigger_child (
        id INTEGER PRIMARY KEY,
        parent_id INTEGER REFERENCES cascade_trigger_parent(id) ON DELETE CASCADE
      )
    ''')
    ..execute('CREATE TABLE cascade_trigger_audit (deleted_id INTEGER)')
    ..execute('PRAGMA foreign_keys = ON')
    ..execute('INSERT INTO cascade_trigger_parent VALUES (1)')
    ..execute('INSERT INTO cascade_trigger_child VALUES (8, 1)')
    ..execute('''
      CREATE TRIGGER cascade_child_ad AFTER DELETE ON cascade_trigger_child
      BEGIN
        INSERT INTO cascade_trigger_audit VALUES (OLD.id);
      END
    ''')
    ..execute('DELETE FROM cascade_trigger_parent WHERE id = 1');
  assert(
    cascadeTriggerDb
            .select('SELECT deleted_id FROM cascade_trigger_audit')
            .single['deleted_id'] ==
        8,
  );

  final replaceTriggerDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE replace_trigger_rows (id INTEGER PRIMARY KEY, value TEXT UNIQUE)',
    )
    ..execute('CREATE TABLE replace_trigger_audit (old_value TEXT)')
    ..execute('''
      CREATE TRIGGER replace_trigger_ad AFTER DELETE ON replace_trigger_rows
      BEGIN
        INSERT INTO replace_trigger_audit VALUES (OLD.value);
      END
    ''')
    ..execute("INSERT INTO replace_trigger_rows VALUES (1, 'first')")
    ..execute(
      "INSERT OR REPLACE INTO replace_trigger_rows VALUES (1, 'second')",
    );
  assert(
    replaceTriggerDb.select('SELECT * FROM replace_trigger_audit').isEmpty,
  );
  replaceTriggerDb
    ..execute('PRAGMA recursive_triggers = ON')
    ..execute("INSERT OR REPLACE INTO replace_trigger_rows VALUES (1, 'third')")
    ..execute("INSERT INTO replace_trigger_rows VALUES (2, 'fourth')")
    ..execute('''
      UPDATE OR REPLACE replace_trigger_rows
      SET value = 'fourth' WHERE id = 1
    ''');
  assert(
    replaceTriggerDb
            .select('SELECT old_value FROM replace_trigger_audit')
            .map((row) => row['old_value'])
            .join(',') ==
        'second,fourth',
  );
  replaceTriggerDb
    ..execute(
      'CREATE TABLE replace_trigger_alias_audit (value TEXT PRIMARY KEY)',
    )
    ..execute('''
      CREATE TRIGGER replace_trigger_alias_ai AFTER INSERT ON replace_trigger_rows
      BEGIN
        REPLACE INTO replace_trigger_alias_audit VALUES (NEW.value);
      END
    ''')
    ..execute("INSERT INTO replace_trigger_rows VALUES (3, 'trigger-alias')");
  assert(
    replaceTriggerDb
            .select('SELECT value FROM replace_trigger_alias_audit')
            .single['value'] ==
        'trigger-alias',
  );

  final beforeTriggerDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE before_trigger_rows (id INTEGER PRIMARY KEY, value TEXT)',
    )
    ..execute('''
      CREATE TABLE before_trigger_audit (
        id INTEGER PRIMARY KEY, event TEXT, old_value TEXT, new_value TEXT
      )
    ''')
    ..execute('''
      CREATE TRIGGER before_trigger_insert BEFORE INSERT ON before_trigger_rows
      BEGIN
        INSERT INTO before_trigger_audit (event, new_value)
        VALUES ('insert', NEW.value);
      END
    ''')
    ..execute('''
      CREATE TRIGGER before_trigger_update BEFORE UPDATE OF value
      ON before_trigger_rows
      BEGIN
        INSERT INTO before_trigger_audit (event, old_value, new_value)
        VALUES ('update', OLD.value, NEW.value);
      END
    ''')
    ..execute('''
      CREATE TRIGGER before_trigger_delete BEFORE DELETE ON before_trigger_rows
      BEGIN
        INSERT INTO before_trigger_audit (event, old_value)
        VALUES ('delete', OLD.value);
      END
    ''')
    ..execute("INSERT INTO before_trigger_rows VALUES (1, 'one'), (2, 'two')")
    ..execute("UPDATE before_trigger_rows SET value = value || '!'")
    ..execute('DELETE FROM before_trigger_rows WHERE id = 1');
  assert(
    beforeTriggerDb
            .select('SELECT event FROM before_trigger_audit ORDER BY id')
            .map((row) => row['event'])
            .join(',') ==
        'insert,insert,update,update,delete',
  );
  assert(
    beforeTriggerDb
            .select(
              'SELECT old_value, new_value FROM before_trigger_audit WHERE event = \'update\' ORDER BY id',
            )
            .first['old_value'] ==
        'one',
  );
  assert(
    beforeTriggerDb
            .select(
              'SELECT old_value, new_value FROM before_trigger_audit WHERE event = \'update\' ORDER BY id',
            )
            .first['new_value'] ==
        'one!',
  );

  final beforeIgnoreDb = PureDatabase.memory()
    ..execute('CREATE TABLE before_ignore_insert (value INTEGER)')
    ..execute('''
      CREATE TRIGGER before_ignore_insert_bi BEFORE INSERT ON before_ignore_insert
      WHEN NEW.value = 2 BEGIN SELECT RAISE(IGNORE); END
    ''');
  assert(
    beforeIgnoreDb.execute(
          'INSERT INTO before_ignore_insert VALUES (1), (2), (3)',
        ) ==
        2,
  );
  assert(
    beforeIgnoreDb
            .select('SELECT value FROM before_ignore_insert ORDER BY value')
            .map((row) => row['value'])
            .join(',') ==
        '1,3',
  );
  assert(beforeIgnoreDb.select('SELECT changes() AS n').single['n'] == 2);

  final beforeIgnoreUpdateDb = PureDatabase.memory()
    ..execute('CREATE TABLE before_ignore_update (value INTEGER)')
    ..execute('INSERT INTO before_ignore_update VALUES (1), (2), (3)')
    ..execute('''
      CREATE TRIGGER before_ignore_update_bu BEFORE UPDATE ON before_ignore_update
      WHEN OLD.value = 2 BEGIN SELECT RAISE(IGNORE); END
    ''');
  assert(
    beforeIgnoreUpdateDb.execute(
          'UPDATE before_ignore_update SET value = value + 10',
        ) ==
        2,
  );
  assert(
    beforeIgnoreUpdateDb
            .select('SELECT value FROM before_ignore_update ORDER BY value')
            .map((row) => row['value'])
            .join(',') ==
        '2,11,13',
  );

  final beforeIgnoreDeleteDb = PureDatabase.memory()
    ..execute('CREATE TABLE before_ignore_delete (value INTEGER)')
    ..execute('INSERT INTO before_ignore_delete VALUES (1), (2), (3)')
    ..execute('''
      CREATE TRIGGER before_ignore_delete_bd BEFORE DELETE ON before_ignore_delete
      WHEN OLD.value = 2 BEGIN SELECT RAISE(IGNORE); END
    ''');
  assert(beforeIgnoreDeleteDb.execute('DELETE FROM before_ignore_delete') == 2);
  assert(
    beforeIgnoreDeleteDb
            .select('SELECT value FROM before_ignore_delete')
            .single['value'] ==
        2,
  );

  final beforeFailDb = PureDatabase.memory()
    ..execute('CREATE TABLE before_fail_rows (value INTEGER)')
    ..execute('''
      CREATE TRIGGER before_fail_bi BEFORE INSERT ON before_fail_rows
      WHEN NEW.value = 2 BEGIN SELECT RAISE(FAIL, 'before fail'); END
    ''');
  try {
    beforeFailDb.execute('INSERT INTO before_fail_rows VALUES (1), (2), (3)');
    assert(false, 'BEFORE RAISE(FAIL) should stop at the failing row');
  } on SqliteException catch (error) {
    assert(error.message == 'before fail');
  }
  assert(beforeFailDb.select('SELECT value FROM before_fail_rows').length == 1);
  assert(beforeFailDb.select('SELECT changes() AS n').single['n'] == 1);

  final insteadOfDb = PureDatabase.memory()
    ..execute('CREATE TABLE instead_base (id INTEGER PRIMARY KEY, label TEXT)')
    ..execute("INSERT INTO instead_base VALUES (1, 'first'), (2, 'second')")
    ..execute('''
      CREATE VIEW instead_view(row_id, display) AS
      SELECT id, label FROM instead_base
    ''')
    ..execute('''
      CREATE TABLE instead_audit (
        event TEXT, old_display TEXT, new_display TEXT
      )
    ''')
    ..execute('''
      CREATE TRIGGER instead_view_insert INSTEAD OF INSERT ON instead_view
      BEGIN
        INSERT INTO instead_base VALUES (NEW.row_id, NEW.display);
        INSERT INTO instead_audit VALUES ('insert', NULL, NEW.display);
      END
    ''')
    ..execute('''
      CREATE TRIGGER instead_view_update INSTEAD OF UPDATE OF display
      ON instead_view
      BEGIN
        UPDATE instead_base SET label = NEW.display WHERE id = OLD.row_id;
        INSERT INTO instead_audit VALUES ('update', OLD.display, NEW.display);
      END
    ''')
    ..execute('''
      CREATE TRIGGER instead_view_delete INSTEAD OF DELETE ON instead_view
      BEGIN
        DELETE FROM instead_base WHERE id = OLD.row_id;
        INSERT INTO instead_audit VALUES ('delete', OLD.display, NULL);
      END
    ''');
  final insteadReturned = insteadOfDb.select('''
    INSERT INTO instead_view VALUES (3, 'third'), (4, 'fourth')
    RETURNING row_id, display
  ''');
  assert(insteadReturned.length == 2);
  assert(insteadReturned.last['display'] == 'fourth');
  assert(insteadOfDb.select('SELECT changes() AS n').single['n'] == 0);
  assert(insteadOfDb.select('SELECT total_changes() AS n').single['n'] == 6);
  final insteadUpdated = insteadOfDb.select('''
    UPDATE instead_view SET display = display || '!'
    WHERE row_id = 3 RETURNING display
  ''');
  assert(insteadUpdated.single['display'] == 'third!');
  assert(insteadOfDb.select('SELECT changes() AS n').single['n'] == 0);
  assert(insteadOfDb.select('SELECT total_changes() AS n').single['n'] == 8);
  assert(insteadOfDb.execute('DELETE FROM instead_view WHERE row_id = 4') == 0);
  assert(insteadOfDb.select('SELECT changes() AS n').single['n'] == 0);
  assert(insteadOfDb.select('SELECT total_changes() AS n').single['n'] == 10);
  assert(
    insteadOfDb
            .select('SELECT event FROM instead_audit')
            .map((row) => row['event'])
            .join(',') ==
        'insert,insert,update,delete',
  );
  final scalarSubqueryDmlDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE scalar_subquery_dml (id INTEGER PRIMARY KEY, name TEXT UNIQUE, value TEXT)',
    )
    ..execute(
      "INSERT INTO scalar_subquery_dml VALUES (1, 'base', 'old'), (2, 'source', 'from-select')",
    );
  scalarSubqueryDmlDb.execute('''
    INSERT INTO scalar_subquery_dml VALUES (3, 'base', 'ignored')
    ON CONFLICT(name) DO UPDATE SET value =
      (SELECT value FROM scalar_subquery_dml WHERE id = 2) || excluded.value
  ''');
  assert(
    scalarSubqueryDmlDb
            .select('SELECT value FROM scalar_subquery_dml WHERE id = 1')
            .single['value'] ==
        'from-selectignored',
  );
  scalarSubqueryDmlDb
    ..execute('''
      CREATE VIEW scalar_subquery_dml_view AS
      SELECT id, value FROM scalar_subquery_dml
    ''')
    ..execute('''
      CREATE TRIGGER scalar_subquery_dml_view_insert
      INSTEAD OF INSERT ON scalar_subquery_dml_view
      BEGIN
        INSERT INTO scalar_subquery_dml VALUES (NEW.id, 'view', NEW.value);
      END
    ''')
    ..execute('''
      CREATE TRIGGER scalar_subquery_dml_view_update
      INSTEAD OF UPDATE ON scalar_subquery_dml_view
      BEGIN
        UPDATE scalar_subquery_dml SET value = NEW.value WHERE id = OLD.id;
      END
    ''')
    ..execute('''
      INSERT INTO scalar_subquery_dml_view VALUES (
        4, (SELECT value FROM scalar_subquery_dml WHERE id = 2)
      )
    ''')
    ..execute('''
      UPDATE scalar_subquery_dml_view
      SET value = (SELECT value FROM scalar_subquery_dml WHERE id = 2)
      WHERE id = 1
    ''');
  assert(
    scalarSubqueryDmlDb
            .select('SELECT value FROM scalar_subquery_dml WHERE id = 4')
            .single['value'] ==
        'from-select',
  );
  assert(
    scalarSubqueryDmlDb
            .select('SELECT value FROM scalar_subquery_dml WHERE id = 1')
            .single['value'] ==
        'from-select',
  );
  final withDmlDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE with_dml_source (id INTEGER PRIMARY KEY, value TEXT)',
    )
    ..execute(
      "INSERT INTO with_dml_source VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma')",
    )
    ..execute(
      'CREATE TABLE with_dml_target (id INTEGER PRIMARY KEY, value TEXT)',
    )
    ..execute('''
      WITH source AS (SELECT value FROM with_dml_source WHERE id = 1)
      INSERT INTO with_dml_target SELECT 10, value FROM source
    ''')
    ..execute('''
      INSERT INTO with_dml_target
      WITH source AS (SELECT value FROM with_dml_source WHERE id = 2)
      SELECT 11, value FROM source
    ''')
    ..execute('''
      WITH source AS (SELECT value FROM with_dml_source WHERE id = 2)
      UPDATE with_dml_target SET value = (SELECT value FROM source) WHERE id = 10
    ''')
    ..execute('''
      WITH target AS (SELECT id FROM with_dml_source WHERE id = 3)
      DELETE FROM with_dml_source WHERE id IN (SELECT id FROM target)
    ''');
  assert(
    withDmlDb
            .select('SELECT value FROM with_dml_target ORDER BY id')
            .map((row) => row['value'])
            .join(',') ==
        'beta,beta',
  );
  assert(
    withDmlDb.select('SELECT id FROM with_dml_source ORDER BY id').length == 2,
  );
  insteadOfDb.execute(
    'CREATE VIEW instead_read_only_view AS SELECT 1 AS value',
  );
  try {
    insteadOfDb.execute('DELETE FROM instead_read_only_view');
    assert(false, 'a view DML event without a trigger should fail');
  } on SqliteException catch (error) {
    assert(
      error.message ==
          'cannot modify instead_read_only_view because it is a view',
    );
  }
  try {
    insteadOfDb.execute('''
      CREATE TRIGGER invalid_instead_trigger INSTEAD OF INSERT
      ON instead_base BEGIN SELECT 1; END
    ''');
    assert(false, 'INSTEAD OF triggers must target views');
  } on SqliteException catch (error) {
    assert(
      error.message ==
          'cannot create INSTEAD OF trigger on table: instead_base',
    );
  }

  final insteadIgnoreDb = PureDatabase.memory()
    ..execute('CREATE TABLE instead_ignore_log (value INTEGER)')
    ..execute('CREATE VIEW instead_ignore_view AS SELECT 1 AS value')
    ..execute('''
      CREATE TRIGGER instead_ignore_insert INSTEAD OF INSERT
      ON instead_ignore_view BEGIN
        INSERT INTO instead_ignore_log VALUES (NEW.value);
        SELECT RAISE(IGNORE);
        INSERT INTO instead_ignore_log VALUES (999);
      END
    ''');
  assert(
    insteadIgnoreDb.execute(
          'INSERT INTO instead_ignore_view VALUES (1), (2)',
        ) ==
        0,
  );
  assert(
    insteadIgnoreDb
            .select('SELECT value FROM instead_ignore_log')
            .map((row) => row['value'])
            .join(',') ==
        '1,2',
  );

  final insteadFailDb = PureDatabase.memory()
    ..execute('CREATE TABLE instead_fail_rows (value INTEGER)')
    ..execute(
      'CREATE VIEW instead_fail_view AS SELECT value FROM instead_fail_rows',
    )
    ..execute('''
      CREATE TRIGGER instead_fail_insert INSTEAD OF INSERT
      ON instead_fail_view BEGIN
        INSERT INTO instead_fail_rows VALUES (NEW.value);
        SELECT RAISE(FAIL, 'view trigger failed');
      END
    ''');
  try {
    insteadFailDb.execute('INSERT INTO instead_fail_view VALUES (1), (2)');
    assert(false, 'INSTEAD OF RAISE(FAIL) should surface an error');
  } on SqliteException catch (error) {
    assert(error.message == 'view trigger failed');
  }
  assert(
    insteadFailDb
            .select('SELECT value FROM instead_fail_rows')
            .single['value'] ==
        1,
  );
  assert(insteadFailDb.select('SELECT changes() AS n').single['n'] == 0);

  final insteadAbortDb = PureDatabase.memory()
    ..execute('CREATE TABLE instead_abort_rows (value INTEGER)')
    ..execute(
      'CREATE VIEW instead_abort_view AS SELECT value FROM instead_abort_rows',
    )
    ..execute('''
      CREATE TRIGGER instead_abort_insert INSTEAD OF INSERT
      ON instead_abort_view BEGIN
        INSERT INTO instead_abort_rows VALUES (NEW.value);
        SELECT RAISE(ABORT, 'view statement aborted');
      END
    ''');
  try {
    insteadAbortDb.execute('INSERT INTO instead_abort_view VALUES (1)');
    assert(false, 'INSTEAD OF RAISE(ABORT) should roll back trigger writes');
  } on SqliteException catch (error) {
    assert(error.message == 'view statement aborted');
  }
  assert(insteadAbortDb.select('SELECT * FROM instead_abort_rows').isEmpty);

  final temporaryTriggerDb = PureDatabase.memory()
    ..execute('CREATE TABLE temporary_trigger_rows (value INTEGER)')
    ..execute('CREATE TABLE temporary_trigger_main_log (value INTEGER)')
    ..execute('CREATE TABLE temporary_trigger_temp_log (value INTEGER)')
    ..execute('''
      CREATE TRIGGER duplicate_trigger_name AFTER INSERT
      ON temporary_trigger_rows BEGIN
        INSERT INTO temporary_trigger_main_log VALUES (NEW.value);
      END
    ''')
    ..execute('''
      CREATE TEMPORARY TRIGGER duplicate_trigger_name AFTER INSERT
      ON temporary_trigger_rows BEGIN
        INSERT INTO temporary_trigger_temp_log VALUES (NEW.value);
      END
    ''')
    ..execute('INSERT INTO temporary_trigger_rows VALUES (1)');
  assert(
    temporaryTriggerDb
            .select('SELECT value FROM temporary_trigger_main_log')
            .single['value'] ==
        1,
  );
  assert(
    temporaryTriggerDb
            .select('SELECT value FROM temporary_trigger_temp_log')
            .single['value'] ==
        1,
  );
  temporaryTriggerDb
    ..execute('DROP TRIGGER duplicate_trigger_name')
    ..execute('INSERT INTO temporary_trigger_rows VALUES (2)')
    ..execute('BEGIN')
    ..execute('''
      CREATE TEMP TRIGGER rolled_back_temp_trigger AFTER INSERT
      ON temporary_trigger_rows BEGIN
        INSERT INTO temporary_trigger_temp_log VALUES (999);
      END
    ''')
    ..execute('ROLLBACK')
    ..execute('INSERT INTO temporary_trigger_rows VALUES (3)');
  assert(
    temporaryTriggerDb
            .select('SELECT value FROM temporary_trigger_main_log')
            .map((row) => row['value'])
            .join(',') ==
        '1,2,3',
  );
  assert(
    temporaryTriggerDb
            .select('SELECT value FROM temporary_trigger_temp_log')
            .map((row) => row['value'])
            .join(',') ==
        '1',
  );

  final temporaryRenameDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE temporary_rename_source (id INTEGER PRIMARY KEY, label TEXT)',
    )
    ..execute(
      'CREATE TABLE temporary_rename_audit (old_value TEXT, new_value TEXT)',
    )
    ..execute("INSERT INTO temporary_rename_source VALUES (1, 'before')")
    ..execute('''
      CREATE TEMP TRIGGER temporary_rename_update
      AFTER UPDATE OF label ON temporary_rename_source BEGIN
        INSERT INTO temporary_rename_audit VALUES (OLD.label, NEW.label);
      END
    ''')
    ..execute(
      'ALTER TABLE temporary_rename_source RENAME COLUMN label TO display_label',
    )
    ..execute(
      'ALTER TABLE temporary_rename_source RENAME TO temporary_rename_target',
    )
    ..execute(
      "UPDATE temporary_rename_target SET display_label = 'after' WHERE id = 1",
    );
  assert(
    temporaryRenameDb
            .select('SELECT old_value, new_value FROM temporary_rename_audit')
            .single['new_value'] ==
        'after',
  );

  final triggerColumnDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE trigger_column_source (id INTEGER PRIMARY KEY, label TEXT, spare TEXT)',
    )
    ..execute(
      'CREATE TABLE trigger_column_audit (old_label TEXT, new_label TEXT)',
    )
    ..execute('''
      CREATE TRIGGER trigger_column_au AFTER UPDATE OF label
      ON trigger_column_source
      WHEN OLD.label IS NOT NEW.label
      BEGIN
        INSERT INTO trigger_column_audit VALUES (OLD.label, NEW.label);
      END
    ''')
    ..execute(
      "INSERT INTO trigger_column_source VALUES (1, 'before', 'unused')",
    )
    ..execute(
      'ALTER TABLE trigger_column_source RENAME COLUMN label TO display_label',
    )
    ..execute('ALTER TABLE trigger_column_source DROP COLUMN spare')
    ..execute(
      "UPDATE trigger_column_source SET display_label = 'after' WHERE id = 1",
    );
  assert(
    triggerColumnDb
            .select('SELECT old_label, new_label FROM trigger_column_audit')
            .single['old_label'] ==
        'before',
  );
  assert(
    triggerColumnDb
            .select('SELECT old_label, new_label FROM trigger_column_audit')
            .single['new_label'] ==
        'after',
  );
  final triggerBodyRenameDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE trigger_body_target (id INTEGER PRIMARY KEY, old_name TEXT)',
    )
    ..execute(
      'CREATE TABLE trigger_body_input (id INTEGER PRIMARY KEY, old_name TEXT)',
    )
    ..execute('CREATE TABLE trigger_body_audit (value TEXT)')
    ..execute('''
      CREATE TRIGGER trigger_body_input_ai AFTER INSERT ON trigger_body_input
      BEGIN
        INSERT INTO trigger_body_target (id, old_name)
        VALUES (NEW.id, NEW.old_name);
        INSERT INTO trigger_body_target (id, old_name)
        SELECT NEW.id + 1, old_name
        FROM trigger_body_target WHERE id = NEW.id;
        INSERT INTO trigger_body_target (id, old_name)
        VALUES (
          NEW.id + 2,
          (SELECT old_name FROM trigger_body_target WHERE id = NEW.id)
        );
        UPDATE trigger_body_target
        SET old_name = (
          SELECT (
            SELECT old_name FROM trigger_body_target WHERE id = NEW.id
          )
          FROM trigger_body_target WHERE id = NEW.id
        )
        WHERE id = NEW.id;
        WITH q AS (
          SELECT old_name AS old_name
          FROM trigger_body_target
        )
        SELECT old_name FROM q;
        INSERT INTO trigger_body_audit
        WITH q AS (
          SELECT old_name AS old_name
          FROM trigger_body_target WHERE id = 1
        )
        SELECT old_name FROM q;
        WITH q AS (
          SELECT old_name AS old_name
          FROM trigger_body_target WHERE id = 1
        )
        INSERT INTO trigger_body_audit SELECT old_name FROM q;
        DELETE FROM trigger_body_target
      WHERE id = -1 AND old_name = NEW.old_name;
    END
  ''')
    ..execute('''
      CREATE TRIGGER trigger_body_input_au AFTER UPDATE OF old_name
      ON trigger_body_input
      BEGIN
        UPDATE trigger_body_target
        SET old_name = NEW.old_name WHERE id = NEW.id;
      END
    ''')
    ..execute('''
      CREATE TRIGGER trigger_body_target_au AFTER UPDATE ON trigger_body_target
      BEGIN
        UPDATE trigger_body_target
        SET old_name = NEW.old_name
        WHERE id = NEW.id;
      END
    ''')
    ..execute(
      'ALTER TABLE trigger_body_target RENAME COLUMN old_name TO new_name',
    );
  var triggerBodyDropRejected = false;
  try {
    triggerBodyRenameDb.execute(
      'ALTER TABLE trigger_body_target DROP COLUMN new_name',
    );
  } on SqliteException {
    triggerBodyDropRejected = true;
  }
  assert(triggerBodyDropRejected);
  triggerBodyRenameDb.execute(
    "INSERT INTO trigger_body_input VALUES (1, 'inserted')",
  );
  assert(
    triggerBodyRenameDb
            .select('SELECT new_name FROM trigger_body_target WHERE id = 1')
            .single['new_name'] ==
        'inserted',
  );
  assert(
    triggerBodyRenameDb
            .select('SELECT new_name FROM trigger_body_target WHERE id = 2')
            .single['new_name'] ==
        'inserted',
  );
  assert(
    triggerBodyRenameDb
            .select('SELECT new_name FROM trigger_body_target WHERE id = 3')
            .single['new_name'] ==
        'inserted',
  );
  assert(
    triggerBodyRenameDb
            .select('SELECT value FROM trigger_body_audit ORDER BY rowid')
            .map((row) => row['value'])
            .join(',') ==
        'inserted,inserted',
  );
  triggerBodyRenameDb.execute(
    "UPDATE trigger_body_input SET old_name = 'source-update' WHERE id = 1",
  );
  assert(
    triggerBodyRenameDb
            .select('SELECT new_name FROM trigger_body_target WHERE id = 1')
            .single['new_name'] ==
        'source-update',
  );
  triggerBodyRenameDb.execute(
    "UPDATE trigger_body_target SET new_name = 'updated' WHERE id = 1",
  );
  assert(
    triggerBodyRenameDb
            .select('SELECT new_name FROM trigger_body_target WHERE id = 1')
            .single['new_name'] ==
        'updated',
  );
  final triggerJoinRenameDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE trigger_join_target (id INTEGER PRIMARY KEY, old_name TEXT)',
    )
    ..execute('CREATE TABLE trigger_join_aux (target_id INTEGER)')
    ..execute('CREATE TABLE trigger_join_input (id INTEGER)')
    ..execute('CREATE TABLE trigger_join_audit (value TEXT)')
    ..execute('INSERT INTO trigger_join_target VALUES (1, \'joined\')')
    ..execute('INSERT INTO trigger_join_aux VALUES (1)')
    ..execute('''
      CREATE TRIGGER trigger_join_input_ai AFTER INSERT ON trigger_join_input
      BEGIN
        INSERT INTO trigger_join_audit
        SELECT trigger_join_target.old_name
        FROM trigger_join_target
        JOIN trigger_join_aux
          ON trigger_join_aux.target_id = trigger_join_target.id
        WHERE trigger_join_target.id = NEW.id;
      END
    ''')
    ..execute(
      'ALTER TABLE trigger_join_target RENAME COLUMN old_name TO new_name',
    )
    ..execute('INSERT INTO trigger_join_input VALUES (1)');
  assert(
    triggerJoinRenameDb
            .select('SELECT value FROM trigger_join_audit')
            .single['value'] ==
        'joined',
  );
  final triggerCompoundRenameDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE trigger_compound_target (id INTEGER PRIMARY KEY, old_name TEXT)',
    )
    ..execute('CREATE TABLE trigger_compound_other (old_name TEXT)')
    ..execute('CREATE TABLE trigger_compound_input (id INTEGER)')
    ..execute('CREATE TABLE trigger_compound_audit (value TEXT)')
    ..execute("INSERT INTO trigger_compound_target VALUES (1, 'target')")
    ..execute("INSERT INTO trigger_compound_other VALUES ('other')")
    ..execute('''
      CREATE TRIGGER trigger_compound_input_ai AFTER INSERT
      ON trigger_compound_input BEGIN
        INSERT INTO trigger_compound_audit
        SELECT t.old_name FROM trigger_compound_target AS t
        UNION ALL
        SELECT o.old_name FROM trigger_compound_other AS o;
      END
    ''')
    ..execute('''
      ALTER TABLE trigger_compound_target
      RENAME COLUMN old_name TO new_name
    ''')
    ..execute('INSERT INTO trigger_compound_input VALUES (1)');
  final compoundTriggerValues = triggerCompoundRenameDb
      .select('SELECT value FROM trigger_compound_audit ORDER BY value')
      .map((row) => row['value'])
      .toList();
  assert(
    compoundTriggerValues.length == 2 &&
        compoundTriggerValues[0] == 'other' &&
        compoundTriggerValues[1] == 'target',
  );
  final unrelatedTriggerDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE trigger_unrelated_rename_target (id INTEGER, old_name TEXT)',
    )
    ..execute('CREATE TABLE trigger_unrelated_source (old_name TEXT)')
    ..execute('CREATE TABLE trigger_unrelated_audit (value TEXT)')
    ..execute('''
      CREATE TRIGGER trigger_unrelated_source_ai AFTER INSERT
      ON trigger_unrelated_source BEGIN
        INSERT INTO trigger_unrelated_audit VALUES (NEW.old_name);
      END
    ''')
    ..execute('''
      ALTER TABLE trigger_unrelated_rename_target
      RENAME COLUMN old_name TO new_name
    ''')
    ..execute('''
      ALTER TABLE trigger_unrelated_rename_target DROP COLUMN new_name
    ''')
    ..execute("INSERT INTO trigger_unrelated_source VALUES ('preserved')");
  assert(
    unrelatedTriggerDb
            .select('SELECT value FROM trigger_unrelated_audit')
            .single['value'] ==
        'preserved',
  );
  try {
    triggerColumnDb.execute(
      'ALTER TABLE trigger_column_source DROP COLUMN display_label',
    );
    assert(false, 'a column referenced by a trigger cannot be dropped');
  } on SqliteException {
    // The trigger still depends on the renamed column.
  }

  for (final (action, expectedValues, expectedAudit) in [
    ('ABORT', '', ''),
    ('FAIL', '1,2', '1,2,202'),
    ('IGNORE', '1,2', '1,2,202'),
  ]) {
    final raiseExpression = action == 'IGNORE'
        ? 'RAISE(IGNORE)'
        : "RAISE($action, '$action message')";
    final raiseDb = PureDatabase.memory()
      ..execute('CREATE TABLE raise_rows (value INTEGER)')
      ..execute(
        'CREATE TABLE raise_audit (sequence INTEGER PRIMARY KEY, value INTEGER)',
      )
      ..execute('''
        CREATE TRIGGER raise_rows_audit AFTER INSERT ON raise_rows
        BEGIN INSERT INTO raise_audit (value) VALUES (NEW.value); END
      ''')
      ..execute('''
        CREATE TRIGGER raise_rows_ai AFTER INSERT ON raise_rows
        WHEN NEW.value = 2
        BEGIN
          INSERT INTO raise_audit (value) VALUES (NEW.value + 200);
          SELECT $raiseExpression;
          INSERT INTO raise_audit (value) VALUES (NEW.value + 100);
        END
      ''');
    var raised = false;
    try {
      raiseDb.execute('INSERT INTO raise_rows VALUES (1), (2), (3)');
    } on SqliteException catch (error) {
      raised = true;
      assert(error.message == '$action message', '$action: ${error.message}');
    }
    assert(raised == (action != 'IGNORE'));
    assert(
      raiseDb
              .select('SELECT value FROM raise_rows ORDER BY value')
              .map((row) => row['value'])
              .join(',') ==
          expectedValues,
    );
    assert(
      raiseDb
              .select('SELECT value FROM raise_audit ORDER BY sequence')
              .map((row) => row['value'])
              .join(',') ==
          expectedAudit,
    );
    if (action == 'FAIL' || action == 'IGNORE') {
      assert(raiseDb.select('SELECT changes() AS n').single['n'] == 2);
    }
  }

  for (final action in ['ABORT', 'FAIL', 'IGNORE']) {
    final raiseUpdateDb = PureDatabase.memory()
      ..execute('CREATE TABLE raise_update_rows (value INTEGER PRIMARY KEY)')
      ..execute('INSERT INTO raise_update_rows VALUES (1), (2), (3)')
      ..execute('''
        CREATE TRIGGER raise_update_au AFTER UPDATE ON raise_update_rows
        WHEN NEW.value = 12
        BEGIN SELECT ${action == 'IGNORE' ? 'RAISE(IGNORE)' : "RAISE($action, '$action update')"}; END
      ''');
    var updateRaised = false;
    try {
      raiseUpdateDb.execute('UPDATE raise_update_rows SET value = value + 10');
    } on SqliteException catch (error) {
      updateRaised = true;
      assert(error.message == '$action update');
    }
    assert(updateRaised == (action != 'IGNORE'));
    assert(
      raiseUpdateDb
              .select('SELECT value FROM raise_update_rows ORDER BY value')
              .map((row) => row['value'])
              .join(',') ==
          (action == 'ABORT' ? '1,2,3' : '3,11,12'),
    );
    if (action != 'ABORT') {
      assert(raiseUpdateDb.select('SELECT changes() AS n').single['n'] == 2);
    }

    final raiseDeleteDb = PureDatabase.memory()
      ..execute('CREATE TABLE raise_delete_rows (value INTEGER PRIMARY KEY)')
      ..execute('INSERT INTO raise_delete_rows VALUES (1), (2), (3)')
      ..execute('''
        CREATE TRIGGER raise_delete_ad AFTER DELETE ON raise_delete_rows
        WHEN OLD.value = 2
        BEGIN SELECT ${action == 'IGNORE' ? 'RAISE(IGNORE)' : "RAISE($action, '$action delete')"}; END
      ''');
    var deleteRaised = false;
    try {
      raiseDeleteDb.execute('DELETE FROM raise_delete_rows');
    } on SqliteException catch (error) {
      deleteRaised = true;
      assert(error.message == '$action delete');
    }
    assert(deleteRaised == (action != 'IGNORE'));
    assert(
      raiseDeleteDb
              .select('SELECT value FROM raise_delete_rows ORDER BY value')
              .map((row) => row['value'])
              .join(',') ==
          (action == 'ABORT' ? '1,2,3' : '1'),
    );
    if (action != 'ABORT') {
      assert(raiseDeleteDb.select('SELECT changes() AS n').single['n'] == 2);
    }
  }

  final raiseRollbackDb = PureDatabase.memory()
    ..execute('CREATE TABLE raise_rollback_rows (value INTEGER)')
    ..execute('''
      CREATE TRIGGER raise_rollback_ai AFTER INSERT ON raise_rollback_rows
      WHEN NEW.value = 2
      BEGIN SELECT RAISE(ROLLBACK, 'transaction rolled back'); END
    ''')
    ..execute('BEGIN')
    ..execute('INSERT INTO raise_rollback_rows VALUES (1)');
  try {
    raiseRollbackDb.execute('INSERT INTO raise_rollback_rows VALUES (2)');
    assert(false, 'RAISE(ROLLBACK) should fail');
  } on SqliteException catch (error) {
    assert(error.message == 'transaction rolled back');
  }
  assert(raiseRollbackDb.select('SELECT * FROM raise_rollback_rows').isEmpty);
  raiseRollbackDb.execute('INSERT INTO raise_rollback_rows VALUES (3)');
  assert(
    raiseRollbackDb
            .select('SELECT value FROM raise_rollback_rows')
            .single['value'] ==
        3,
  );

  final nestedIgnoreDb = PureDatabase.memory()
    ..execute('CREATE TABLE nested_ignore_source (value INTEGER)')
    ..execute('CREATE TABLE nested_ignore_child (value INTEGER)')
    ..execute('CREATE TABLE nested_ignore_audit (value INTEGER)')
    ..execute('''
      CREATE TRIGGER nested_ignore_child_ai AFTER INSERT ON nested_ignore_child
      WHEN NEW.value = 2
      BEGIN SELECT RAISE(IGNORE); END
    ''')
    ..execute('''
      CREATE TRIGGER nested_ignore_source_ai AFTER INSERT ON nested_ignore_source
      BEGIN
        INSERT INTO nested_ignore_child VALUES (NEW.value);
        INSERT INTO nested_ignore_audit VALUES (NEW.value);
      END
    ''')
    ..execute('INSERT INTO nested_ignore_source VALUES (2)');
  assert(
    nestedIgnoreDb
            .select('SELECT value FROM nested_ignore_child')
            .single['value'] ==
        2,
  );
  assert(
    nestedIgnoreDb
            .select('SELECT value FROM nested_ignore_audit')
            .single['value'] ==
        2,
  );

  final nestedFailDb = PureDatabase.memory()
    ..execute('CREATE TABLE nested_fail_source (value INTEGER)')
    ..execute('CREATE TABLE nested_fail_child (value INTEGER)')
    ..execute('CREATE TABLE nested_fail_audit (value INTEGER)')
    ..execute('''
      CREATE TRIGGER nested_fail_child_ai AFTER INSERT ON nested_fail_child
      WHEN NEW.value = 2
      BEGIN SELECT RAISE(FAIL, 'nested fail'); END
    ''')
    ..execute('''
      CREATE TRIGGER nested_fail_source_ai AFTER INSERT ON nested_fail_source
      BEGIN
        INSERT INTO nested_fail_child VALUES (NEW.value);
        INSERT INTO nested_fail_audit VALUES (NEW.value);
      END
    ''');
  try {
    nestedFailDb.execute('INSERT INTO nested_fail_source VALUES (2)');
    assert(false, 'nested RAISE(FAIL) should fail');
  } on SqliteException catch (error) {
    assert(error.message == 'nested fail');
  }
  assert(
    nestedFailDb
            .select('SELECT value FROM nested_fail_source')
            .single['value'] ==
        2,
  );
  assert(
    nestedFailDb
            .select('SELECT value FROM nested_fail_child')
            .single['value'] ==
        2,
  );
  assert(nestedFailDb.select('SELECT * FROM nested_fail_audit').isEmpty);

  try {
    db.select("SELECT RAISE(ABORT, 'outside trigger')");
    assert(false, 'RAISE outside a trigger should fail');
  } on SqliteException catch (error) {
    assert(error.message == 'RAISE() may only be used within a trigger');
  }

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
  final deferredFkDb = PureDatabase.memory()
    ..execute('CREATE TABLE deferred_parent (id INTEGER PRIMARY KEY)')
    ..execute(
      'CREATE TABLE deferred_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES deferred_parent(id))',
    )
    ..execute('PRAGMA foreign_keys = ON')
    ..execute('BEGIN')
    ..execute('PRAGMA foreign_keys = OFF');
  assert(
    deferredFkDb.select('PRAGMA foreign_keys').single['foreign_keys'] == 1,
  );
  deferredFkDb
    ..execute('PRAGMA defer_foreign_keys = ON')
    ..execute('INSERT INTO deferred_child VALUES (1, 7)')
    ..execute('INSERT INTO deferred_parent VALUES (7)')
    ..execute('COMMIT');
  assert(deferredFkDb.select('SELECT * FROM deferred_child').length == 1);
  assert(
    deferredFkDb
            .select('PRAGMA defer_foreign_keys')
            .single['defer_foreign_keys'] ==
        0,
  );
  deferredFkDb
    ..execute('BEGIN')
    ..execute('PRAGMA defer_foreign_keys = ON')
    ..execute('UPDATE deferred_parent SET id = 8 WHERE id = 7')
    ..execute('UPDATE deferred_child SET parent_id = 8 WHERE id = 1')
    ..execute('COMMIT');
  deferredFkDb
    ..execute('BEGIN')
    ..execute('PRAGMA defer_foreign_keys = ON')
    ..execute('DELETE FROM deferred_parent WHERE id = 8')
    ..execute('INSERT INTO deferred_parent VALUES (8)')
    ..execute('COMMIT');
  assert(
    deferredFkDb
            .select('SELECT parent_id FROM deferred_child')
            .single['parent_id'] ==
        8,
  );
  deferredFkDb
    ..execute('BEGIN')
    ..execute('PRAGMA defer_foreign_keys = ON')
    ..execute('INSERT INTO deferred_child VALUES (2, 99)');
  try {
    deferredFkDb.execute('COMMIT');
    assert(false, 'unresolved deferred foreign key should fail at commit');
  } on PureSqlException {
    // Expected; the failed commit rolls back the transaction.
  }
  assert(deferredFkDb.select('SELECT * FROM deferred_child').length == 1);
  assert(
    deferredFkDb
            .select('PRAGMA defer_foreign_keys')
            .single['defer_foreign_keys'] ==
        0,
  );
  deferredFkDb.execute('PRAGMA defer_foreign_keys = ON');
  try {
    deferredFkDb.execute('INSERT INTO deferred_child VALUES (3, 88)');
    assert(
      false,
      'implicit transaction should check deferred keys at statement end',
    );
  } on PureSqlException {
    // Expected.
  }
  assert(deferredFkDb.select('SELECT * FROM deferred_child').length == 1);
  assert(
    deferredFkDb
            .select('PRAGMA defer_foreign_keys')
            .single['defer_foreign_keys'] ==
        0,
  );
  final joined = fkDb.select(
    'SELECT files.id AS file_id, folders.id AS folder_id FROM files JOIN folders ON files.folder_id = folders.id',
  );
  assert(joined.single['file_id'] == 'file');
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
    'SELECT folders.id AS folder_id, files.id AS file_id FROM folders LEFT JOIN files ON files.folder_id = folders.id ORDER BY folders.id',
  );
  assert(leftJoined.last['folder_id'] == 'folder');
  assert(leftJoined.last['file_id'] == 'file');
  assert(leftJoined.first['folder_id'] == 'empty');
  assert(leftJoined.first['file_id'] == null);

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
  final checkPragmaDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE check_pragma_rows (value INTEGER CHECK (value > 0))',
    )
    ..execute('PRAGMA ignore_check_constraints = ON');
  assert(
    checkPragmaDb
            .select('PRAGMA ignore_check_constraints')
            .single['ignore_check_constraints'] ==
        1,
  );
  checkPragmaDb.execute('INSERT INTO check_pragma_rows VALUES (-1)');
  checkPragmaDb.execute('PRAGMA ignore_check_constraints = OFF');
  try {
    checkPragmaDb.execute('UPDATE check_pragma_rows SET value = -2');
    assert(false, 'CHECK violations should fail after checks are re-enabled');
  } on PureSqlException {
    // Expected; the previously inserted row remains unchanged.
  }
  assert(
    checkPragmaDb
            .select('SELECT value FROM check_pragma_rows')
            .single['value'] ==
        -1,
  );

  final updateFailDb = PureDatabase.memory();
  updateFailDb.execute(
    'CREATE TABLE update_fail (id INTEGER PRIMARY KEY, value TEXT UNIQUE)',
  );
  updateFailDb.execute(
    "INSERT INTO update_fail VALUES (1, 'one'), (2, 'two'), (3, 'three')",
  );
  try {
    updateFailDb.execute('''
      UPDATE OR FAIL update_fail
      SET value = 'changed'
    ''');
    assert(false, 'UPDATE OR FAIL should stop at the conflicting row');
  } on PureSqlException {
    // Expected; the earlier row remains changed.
  }
  assert(
    updateFailDb
            .select('SELECT value FROM update_fail WHERE id = 1')
            .single['value'] ==
        'changed',
  );
  assert(
    updateFailDb
            .select('SELECT value FROM update_fail WHERE id = 2')
            .single['value'] ==
        'two',
  );
  assert(
    updateFailDb
            .select('SELECT value FROM update_fail WHERE id = 3')
            .single['value'] ==
        'three',
  );

  final insertFailDb = PureDatabase.memory();
  insertFailDb.execute(
    'CREATE TABLE insert_fail (id INTEGER PRIMARY KEY, value TEXT UNIQUE)',
  );
  try {
    insertFailDb.execute('''
      INSERT OR FAIL INTO insert_fail VALUES
        (1, 'one'), (2, 'two'), (3, 'two')
    ''');
    assert(false, 'INSERT OR FAIL should stop at the conflicting row');
  } on PureSqlException {
    // Expected; earlier rows remain inserted.
  }
  assert(
    insertFailDb.select('SELECT id FROM insert_fail ORDER BY id').length == 2,
  );

  final rollbackConflictDb = PureDatabase.memory();
  rollbackConflictDb.execute(
    'CREATE TABLE rollback_conflict (id INTEGER PRIMARY KEY, value TEXT UNIQUE)',
  );
  rollbackConflictDb.execute("INSERT INTO rollback_conflict VALUES (1, 'one')");
  rollbackConflictDb.execute('BEGIN');
  rollbackConflictDb.execute("INSERT INTO rollback_conflict VALUES (2, 'two')");
  try {
    rollbackConflictDb.execute(
      "UPDATE OR ROLLBACK rollback_conflict SET value = 'one' WHERE id = 2",
    );
    assert(false, 'UPDATE OR ROLLBACK should fail on a unique conflict');
  } on PureSqlException {
    // Expected; the whole SQL transaction is rolled back.
  }
  assert(
    rollbackConflictDb.select('SELECT id FROM rollback_conflict').length == 1,
  );
  rollbackConflictDb.execute('BEGIN');
  try {
    rollbackConflictDb.execute('''
      INSERT OR ROLLBACK INTO rollback_conflict VALUES
        (2, 'two'), (3, 'three'), (4, 'one')
    ''');
    assert(false, 'INSERT OR ROLLBACK should fail on a unique conflict');
  } on PureSqlException {
    // Expected; the transaction rolls back both earlier inserts.
  }
  assert(
    rollbackConflictDb.select('SELECT id FROM rollback_conflict').length == 1,
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
  renameDb.execute(
    'CREATE TEMP VIEW temp_parent_view AS SELECT value FROM old_parent',
  );
  renameDb.execute('PRAGMA foreign_keys = ON');
  renameDb.execute("INSERT INTO old_parent VALUES (1, 'value', 'key')");
  renameDb.execute('INSERT INTO old_child VALUES (1)');
  renameDb.execute('ALTER TABLE old_parent RENAME TO renamed_parent');
  assert(renameDb.select('SELECT value FROM renamed_parent').length == 1);
  assert(
    renameDb.select('SELECT value FROM temp_parent_view').single['value'] ==
        'value',
  );
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

  final legacyAlterDb = PureDatabase.memory();
  assert(
    legacyAlterDb
            .select('PRAGMA legacy_alter_table')
            .single['legacy_alter_table'] ==
        0,
  );
  legacyAlterDb.execute('BEGIN');
  legacyAlterDb.execute('PRAGMA legacy_alter_table = ON');
  legacyAlterDb.execute('ROLLBACK');
  assert(
    legacyAlterDb
            .select('PRAGMA legacy_alter_table')
            .single['legacy_alter_table'] ==
        1,
  );
  legacyAlterDb.execute('''
    CREATE TABLE legacy_parent (id INTEGER PRIMARY KEY)
  ''');
  legacyAlterDb.execute('''
    CREATE TABLE legacy_child (parent_id REFERENCES legacy_parent(id))
  ''');
  legacyAlterDb.execute('CREATE TABLE legacy_audit (count INTEGER)');
  legacyAlterDb.execute('''
    CREATE VIEW legacy_parent_view AS SELECT id FROM legacy_parent
  ''');
  legacyAlterDb.execute('''
    CREATE TRIGGER legacy_parent_ai AFTER INSERT ON legacy_parent BEGIN
      INSERT INTO legacy_audit SELECT COUNT(*) FROM legacy_parent;
    END
  ''');
  legacyAlterDb.execute(
    'ALTER TABLE legacy_parent RENAME TO legacy_parent_new',
  );
  assert(
    legacyAlterDb
            .select('PRAGMA foreign_key_list(legacy_child)')
            .single['table'] ==
        'legacy_parent',
  );
  try {
    legacyAlterDb.select('SELECT id FROM legacy_parent_view');
    assert(false, 'legacy rename leaves view SQL unchanged');
  } on PureSqlException catch (error) {
    assert(error.message == 'no such table: legacy_parent');
  }
  try {
    legacyAlterDb.execute('INSERT INTO legacy_parent_new VALUES (1)');
    assert(false, 'legacy rename leaves trigger body SQL unchanged');
  } on PureSqlException catch (error) {
    assert(error.message == 'no such table: legacy_parent');
  }
  legacyAlterDb.execute('PRAGMA legacy_alter_table = OFF');
  assert(
    legacyAlterDb
            .select('PRAGMA legacy_alter_table')
            .single['legacy_alter_table'] ==
        0,
  );

  final legacyTempAlterDb = PureDatabase.memory();
  legacyTempAlterDb.execute(
    'CREATE TEMP TABLE legacy_temp_source (id INTEGER)',
  );
  legacyTempAlterDb.execute(
    'CREATE TEMP TABLE legacy_temp_audit (count INTEGER)',
  );
  legacyTempAlterDb.execute('''
    CREATE TEMP VIEW legacy_temp_view AS SELECT id FROM legacy_temp_source
  ''');
  legacyTempAlterDb.execute('''
    CREATE TEMP TRIGGER legacy_temp_ai AFTER INSERT ON legacy_temp_source BEGIN
      INSERT INTO legacy_temp_audit SELECT COUNT(*) FROM legacy_temp_source;
    END
  ''');
  legacyTempAlterDb.execute('PRAGMA legacy_alter_table = ON');
  legacyTempAlterDb.execute(
    'ALTER TABLE legacy_temp_source RENAME TO legacy_temp_target',
  );
  try {
    legacyTempAlterDb.select('SELECT id FROM legacy_temp_view');
    assert(false, 'legacy TEMP rename leaves view SQL unchanged');
  } on PureSqlException catch (error) {
    assert(error.message == 'no such table: legacy_temp_source');
  }
  try {
    legacyTempAlterDb.execute('INSERT INTO legacy_temp_target VALUES (1)');
    assert(false, 'legacy TEMP rename retains trigger body references');
  } on PureSqlException catch (error) {
    assert(error.message == 'no such table: legacy_temp_source');
  }

  final modernForeignKeyRenameDb = PureDatabase.memory();
  modernForeignKeyRenameDb.execute(
    'CREATE TABLE modern_fk_parent (id INTEGER PRIMARY KEY)',
  );
  modernForeignKeyRenameDb.execute(
    'CREATE TABLE modern_fk_child (id INTEGER REFERENCES modern_fk_parent(id))',
  );
  modernForeignKeyRenameDb.execute(
    'ALTER TABLE modern_fk_parent RENAME TO modern_fk_parent_new',
  );
  assert(
    modernForeignKeyRenameDb
            .select('PRAGMA foreign_key_list(modern_fk_child)')
            .single['table'] ==
        'modern_fk_parent_new',
  );

  final legacyForeignKeyDb = PureDatabase.memory();
  legacyForeignKeyDb.execute(
    'CREATE TABLE legacy_fk_parent (id INTEGER PRIMARY KEY)',
  );
  legacyForeignKeyDb.execute(
    'CREATE TABLE legacy_fk_child (id INTEGER REFERENCES legacy_fk_parent(id))',
  );
  legacyForeignKeyDb.execute('PRAGMA foreign_keys = ON');
  legacyForeignKeyDb.execute('PRAGMA legacy_alter_table = ON');
  legacyForeignKeyDb.execute(
    'ALTER TABLE legacy_fk_parent RENAME TO legacy_fk_parent_new',
  );
  assert(
    legacyForeignKeyDb
            .select('PRAGMA foreign_key_list(legacy_fk_child)')
            .single['table'] ==
        'legacy_fk_parent_new',
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
  renameColumnDb
    ..execute('CREATE TABLE rename_constraint_parent (id INTEGER PRIMARY KEY)')
    ..execute('INSERT INTO rename_constraint_parent VALUES (1)')
    ..execute('''
      CREATE TABLE rename_unrelated_constraints (
        id INTEGER PRIMARY KEY,
        rename_me TEXT,
        indexed_value TEXT UNIQUE,
        CHECK (id > 0),
        FOREIGN KEY (id) REFERENCES rename_constraint_parent(id)
      )
    ''')
    ..execute(
      "INSERT INTO rename_unrelated_constraints VALUES (1, 'old', 'unique')",
    )
    ..execute('''
      CREATE VIEW rename_unrelated_view AS
      SELECT id FROM rename_unrelated_constraints
    ''')
    ..execute('''
      ALTER TABLE rename_unrelated_constraints
      RENAME COLUMN rename_me TO renamed_value
    ''');
  assert(
    renameColumnDb
            .select('SELECT renamed_value FROM rename_unrelated_constraints')
            .single['renamed_value'] ==
        'old',
  );
  assert(
    renameColumnDb
            .select('SELECT id FROM rename_unrelated_view')
            .single['id'] ==
        1,
  );
  assert(
    renameColumnDb
            .select('PRAGMA index_list(rename_unrelated_constraints)')
            .single['unique'] ==
        1,
  );
  final renameIndexedColumnDb = PureDatabase.memory();
  renameIndexedColumnDb
    ..execute('''
      CREATE TABLE rename_indexed_column (
        id INTEGER,
        email TEXT,
        active INTEGER CHECK (active >= 0),
        CHECK (active < 2)
      )
    ''')
    ..execute('''
      CREATE UNIQUE INDEX rename_indexed_column_idx
      ON rename_indexed_column (lower(email)) WHERE active = 1
    ''')
    ..execute("INSERT INTO rename_indexed_column VALUES (1, 'ada', 1)")
    ..execute(
      'ALTER TABLE rename_indexed_column RENAME COLUMN email TO address',
    )
    ..execute(
      'ALTER TABLE rename_indexed_column RENAME COLUMN active TO enabled',
    )
    ..execute("INSERT INTO rename_indexed_column VALUES (2, 'ADA', 0)");
  assert(
    renameIndexedColumnDb
            .select('SELECT address FROM rename_indexed_column ORDER BY id')
            .map((row) => row['address'])
            .join(',') ==
        'ada,ADA',
  );
  try {
    renameIndexedColumnDb.execute(
      "INSERT INTO rename_indexed_column VALUES (3, 'ADA', 1)",
    );
    assert(false, 'renamed expression and partial indexes remain enforced');
  } on PureSqlException {
    // The renamed expression and predicate still enforce the unique index.
  }
  try {
    renameIndexedColumnDb.execute(
      "INSERT INTO rename_indexed_column VALUES (4, 'valid', 2)",
    );
    assert(false, 'renamed CHECK expressions remain enforced');
  } on PureSqlException {
    // Both column and table CHECK expressions use the renamed column.
  }
  renameIndexedColumnDb
    ..execute('BEGIN')
    ..execute(
      'ALTER TABLE rename_indexed_column RENAME COLUMN address TO rolled_back',
    )
    ..execute('ROLLBACK');
  assert(
    renameIndexedColumnDb
            .select('SELECT address FROM rename_indexed_column WHERE id = 1')
            .single['address'] ==
        'ada',
  );
  final renameKeyColumnDb = PureDatabase.memory();
  renameKeyColumnDb
    ..execute('CREATE TABLE rename_key_parent (id INTEGER PRIMARY KEY)')
    ..execute('INSERT INTO rename_key_parent VALUES (1), (2)')
    ..execute('''
      CREATE TABLE rename_key_child (
        tenant_id INTEGER,
        parent_id INTEGER,
        label TEXT,
        PRIMARY KEY (tenant_id, label),
        UNIQUE (parent_id),
        FOREIGN KEY (parent_id) REFERENCES rename_key_parent (id)
      )
    ''')
    ..execute("INSERT INTO rename_key_child VALUES (1, 1, 'one')")
    ..execute(
      'ALTER TABLE rename_key_child RENAME COLUMN parent_id TO parent_ref',
    )
    ..execute(
      'ALTER TABLE rename_key_child RENAME COLUMN tenant_id TO account_id',
    )
    ..execute('ALTER TABLE rename_key_child RENAME COLUMN label TO display');
  assert(
    renameKeyColumnDb
            .select('PRAGMA foreign_key_list(rename_key_child)')
            .single['from'] ==
        'parent_ref',
  );
  try {
    renameKeyColumnDb.execute(
      "INSERT INTO rename_key_child VALUES (2, 1, 'other')",
    );
    assert(false, 'renamed UNIQUE constraint remains enforced');
  } on PureSqlException {
    // The UNIQUE constraint now keys the renamed foreign-key column.
  }
  try {
    renameKeyColumnDb.execute(
      "INSERT INTO rename_key_child VALUES (1, 2, 'one')",
    );
    assert(false, 'renamed composite primary key remains enforced');
  } on PureSqlException {
    // The composite primary-key index uses both renamed key columns.
  }
  renameColumnDb.execute('''
    CREATE TABLE rename_view_dependency (old_name TEXT, keep TEXT)
  ''');
  renameColumnDb.execute('''
    CREATE VIEW rename_dependent_view AS
    SELECT old_name FROM rename_view_dependency WHERE old_name <> ''
  ''');
  renameColumnDb.execute('''
    ALTER TABLE rename_view_dependency RENAME COLUMN old_name TO new_name
  ''');
  renameColumnDb.execute(
    "INSERT INTO rename_view_dependency VALUES ('visible', 'keep')",
  );
  assert(
    renameColumnDb
            .select('SELECT new_name FROM rename_dependent_view')
            .single['new_name'] ==
        'visible',
  );
  renameColumnDb.execute('''
    CREATE TABLE rename_grouped_view_source (old_name TEXT, category TEXT)
  ''');
  renameColumnDb.execute('''
    CREATE VIEW rename_grouped_dependent_view AS
    SELECT category, MAX(old_name) AS label
    FROM rename_grouped_view_source
    WHERE old_name <> ''
    GROUP BY category
    HAVING MAX(old_name) <> ''
    ORDER BY MAX(old_name)
  ''');
  renameColumnDb
    ..execute("INSERT INTO rename_grouped_view_source VALUES ('beta', 'x')")
    ..execute("INSERT INTO rename_grouped_view_source VALUES ('alpha', 'x')")
    ..execute('''
      ALTER TABLE rename_grouped_view_source RENAME COLUMN old_name TO new_name
    ''');
  final renamedGroupedView = renameColumnDb.select(
    'SELECT category, label FROM rename_grouped_dependent_view',
  );
  assert(renamedGroupedView.length == 1);
  assert(renamedGroupedView.single['label'] == 'beta');
  renameColumnDb.execute('''
    CREATE TABLE rename_alias_view_source (old_name TEXT, label TEXT)
  ''');
  renameColumnDb.execute('''
    CREATE VIEW rename_alias_dependent_view AS
    SELECT label AS old_name FROM rename_alias_view_source ORDER BY old_name
  ''');
  renameColumnDb
    ..execute("INSERT INTO rename_alias_view_source VALUES ('a', 'Z')")
    ..execute("INSERT INTO rename_alias_view_source VALUES ('z', 'A')")
    ..execute('''
      ALTER TABLE rename_alias_view_source RENAME COLUMN old_name TO new_name
    ''');
  assert(
    renameColumnDb
            .select('SELECT old_name FROM rename_alias_dependent_view')
            .map((row) => row['old_name'])
            .join(',') ==
        'A,Z',
    'ORDER BY must continue resolving to the view output alias after rename',
  );
  renameColumnDb
    ..execute('''
      CREATE TABLE rename_group_alias_source (old_name TEXT, label TEXT)
    ''')
    ..execute("INSERT INTO rename_group_alias_source VALUES ('a', 'first')")
    ..execute("INSERT INTO rename_group_alias_source VALUES ('a', 'again')")
    ..execute("INSERT INTO rename_group_alias_source VALUES ('b', 'second')")
    ..execute('''
      CREATE VIEW rename_group_alias_view AS
      SELECT label AS old_name, COUNT(*) AS n
      FROM rename_group_alias_source
      GROUP BY old_name HAVING old_name <> ''
    ''')
    ..execute('''
      ALTER TABLE rename_group_alias_source RENAME COLUMN old_name TO new_name
    ''');
  assert(
    renameColumnDb
            .select('SELECT n FROM rename_group_alias_view ORDER BY n')
            .map((row) => row['n'])
            .join(',') ==
        '1,2',
    'GROUP BY and HAVING names resolve to the source column before its alias',
  );
  renameColumnDb
    ..execute('CREATE TABLE rename_alias_safe_source (old_name TEXT)')
    ..execute('''
      CREATE VIEW rename_alias_safe_view AS
      SELECT 'fixed' AS old_name, old_name AS source_value
      FROM rename_alias_safe_source WHERE old_name <> ''
    ''')
    ..execute("INSERT INTO rename_alias_safe_source VALUES ('value')")
    ..execute('''
      ALTER TABLE rename_alias_safe_source RENAME COLUMN old_name TO new_name
    ''');
  final renamedAliasView = renameColumnDb
      .select('SELECT old_name, source_value FROM rename_alias_safe_view')
      .single;
  assert(renamedAliasView['old_name'] == 'fixed');
  assert(renamedAliasView['source_value'] == 'value');
  renameColumnDb
    ..execute('CREATE TABLE rename_complex_view_other (new_name TEXT)')
    ..execute('''
      CREATE VIEW rename_complex_dependent_view AS
      SELECT rename_view_dependency.new_name AS source_name,
             rename_complex_view_other.new_name AS other_name
      FROM rename_view_dependency JOIN rename_complex_view_other ON 1 = 1
    ''')
    ..execute("INSERT INTO rename_complex_view_other VALUES ('other')")
    ..execute('''
      ALTER TABLE rename_view_dependency RENAME COLUMN new_name TO newer_name
    ''');
  final renamedJoinedView = renameColumnDb.select('''
    SELECT source_name, other_name FROM rename_complex_dependent_view
  ''');
  assert(renamedJoinedView.single['source_name'] == 'visible');
  assert(renamedJoinedView.single['other_name'] == 'other');
  renameColumnDb
    ..execute('CREATE TABLE rename_unique_join_target (old_name TEXT)')
    ..execute('CREATE TABLE rename_unique_join_other (keep_name TEXT)')
    ..execute('''
      CREATE VIEW rename_unique_join_view AS
      SELECT old_name, keep_name
      FROM rename_unique_join_target JOIN rename_unique_join_other
        ON old_name <> ''
    ''')
    ..execute("INSERT INTO rename_unique_join_target VALUES ('unique')")
    ..execute("INSERT INTO rename_unique_join_other VALUES ('kept')")
    ..execute('''
      ALTER TABLE rename_unique_join_target
      RENAME COLUMN old_name TO new_name
    ''');
  final renamedUniqueJoinView = renameColumnDb.select('''
    SELECT new_name, keep_name FROM rename_unique_join_view
  ''').single;
  assert(renamedUniqueJoinView['new_name'] == 'unique');
  assert(renamedUniqueJoinView['keep_name'] == 'kept');
  renameColumnDb
    ..execute('CREATE TABLE rename_comma_target (old_name TEXT)')
    ..execute('CREATE TABLE rename_comma_other (keep_name TEXT)')
    ..execute('''
      CREATE VIEW rename_comma_view AS
      SELECT old_name, keep_name
      FROM rename_comma_target, rename_comma_other
      WHERE old_name <> ''
    ''')
    ..execute("INSERT INTO rename_comma_target VALUES ('comma')")
    ..execute("INSERT INTO rename_comma_other VALUES ('cross')")
    ..execute('''
      ALTER TABLE rename_comma_target RENAME COLUMN old_name TO new_name
    ''');
  final renamedCommaView = renameColumnDb
      .select('SELECT new_name, keep_name FROM rename_comma_view')
      .single;
  assert(renamedCommaView['new_name'] == 'comma');
  assert(renamedCommaView['keep_name'] == 'cross');
  renameColumnDb
    ..execute('CREATE TABLE rename_comma_trigger_target (old_name TEXT)')
    ..execute('CREATE TABLE rename_comma_trigger_other (keep_name TEXT)')
    ..execute('CREATE TABLE rename_comma_trigger_source (id INTEGER)')
    ..execute('CREATE TABLE rename_comma_trigger_log (value TEXT)')
    ..execute('''
      CREATE TRIGGER rename_comma_trigger_ai
      AFTER INSERT ON rename_comma_trigger_source
      BEGIN
        INSERT INTO rename_comma_trigger_log
        SELECT old_name || keep_name
        FROM rename_comma_trigger_target, rename_comma_trigger_other;
      END
    ''')
    ..execute("INSERT INTO rename_comma_trigger_target VALUES ('target')")
    ..execute("INSERT INTO rename_comma_trigger_other VALUES ('other')")
    ..execute('''
      ALTER TABLE rename_comma_trigger_target
      RENAME COLUMN old_name TO new_name
    ''')
    ..execute('INSERT INTO rename_comma_trigger_source VALUES (1)');
  assert(
    renameColumnDb
            .select('SELECT value FROM rename_comma_trigger_log')
            .single['value'] ==
        'targetother',
  );
  renameColumnDb
    ..execute(
      'CREATE TABLE rename_natural_left (old_name TEXT, left_value TEXT)',
    )
    ..execute(
      'CREATE TABLE rename_natural_right (old_name TEXT, right_value TEXT)',
    )
    ..execute('''
      CREATE VIEW rename_natural_left_view AS
      SELECT old_name FROM rename_natural_left NATURAL JOIN rename_natural_right
    ''')
    ..execute('''
      CREATE VIEW rename_natural_qualified_view AS
      SELECT rename_natural_left.old_name
      FROM rename_natural_left NATURAL JOIN rename_natural_right
    ''')
    ..execute('''
      CREATE VIEW rename_natural_star_view AS
      SELECT * FROM rename_natural_left NATURAL JOIN rename_natural_right
    ''')
    ..execute("INSERT INTO rename_natural_left VALUES ('match', 'left')")
    ..execute("INSERT INTO rename_natural_right VALUES ('match', 'right')")
    ..execute('''
      ALTER TABLE rename_natural_left
      RENAME COLUMN old_name TO new_name
    ''');
  assert(
    renameColumnDb
            .select('SELECT new_name FROM rename_natural_left_view')
            .single['new_name'] ==
        'match',
  );
  assert(
    renameColumnDb
            .select('SELECT new_name FROM rename_natural_qualified_view')
            .single['new_name'] ==
        'match',
  );
  final naturalStarColumns = renameColumnDb
      .select('SELECT * FROM rename_natural_star_view')
      .single;
  assert(naturalStarColumns['new_name'] == 'match');
  assert(naturalStarColumns['old_name'] == 'match');
  assert(naturalStarColumns['left_value'] == 'left');
  assert(naturalStarColumns['right_value'] == 'right');
  renameColumnDb
    ..execute('CREATE TABLE rename_natural_target_right (old_name TEXT)')
    ..execute('CREATE TABLE rename_natural_other_left (old_name TEXT)')
    ..execute('''
      CREATE VIEW rename_natural_right_view AS
      SELECT old_name FROM rename_natural_other_left
      NATURAL JOIN rename_natural_target_right
    ''')
    ..execute("INSERT INTO rename_natural_target_right VALUES ('target')")
    ..execute("INSERT INTO rename_natural_other_left VALUES ('left')")
    ..execute('''
      ALTER TABLE rename_natural_target_right
      RENAME COLUMN old_name TO renamed
    ''');
  assert(
    renameColumnDb
            .select('SELECT old_name FROM rename_natural_right_view')
            .single['old_name'] ==
        'left',
  );
  renameColumnDb
    ..execute('CREATE TABLE rename_using_left (old_name TEXT)')
    ..execute('CREATE TABLE rename_using_right (old_name TEXT)')
    ..execute('''
      CREATE VIEW rename_using_left_view AS
      SELECT old_name FROM rename_using_left
      JOIN rename_using_right USING (old_name)
    ''')
    ..execute('''
      ALTER TABLE rename_using_left
      RENAME COLUMN old_name TO renamed
    ''');
  var renamedUsingViewRejected = false;
  try {
    renameColumnDb.select('SELECT * FROM rename_using_left_view');
  } on PureSqlException {
    renamedUsingViewRejected = true;
  }
  assert(renamedUsingViewRejected);
  renameColumnDb
    ..execute('CREATE TABLE rename_using_other_left (old_name TEXT)')
    ..execute('CREATE TABLE rename_using_target_right (old_name TEXT)')
    ..execute('''
      CREATE VIEW rename_using_right_view AS
      SELECT old_name FROM rename_using_other_left
      JOIN rename_using_target_right USING (old_name)
    ''')
    ..execute('''
      ALTER TABLE rename_using_target_right
      RENAME COLUMN old_name TO renamed
    ''');
  var renamedRightUsingViewRejected = false;
  try {
    renameColumnDb.select('SELECT * FROM rename_using_right_view');
  } on PureSqlException {
    renamedRightUsingViewRejected = true;
  }
  assert(renamedRightUsingViewRejected);
  renameColumnDb
    ..execute('CREATE TABLE rename_nested_source (old_name TEXT)')
    ..execute('CREATE TABLE rename_nested_aux (old_name TEXT)')
    ..execute("INSERT INTO rename_nested_source VALUES ('nested')")
    ..execute("INSERT INTO rename_nested_aux VALUES ('inner')")
    ..execute('''
      CREATE VIEW rename_cte_dependent_view AS
      WITH nested(label) AS (
        SELECT old_name FROM rename_nested_source
      )
      SELECT label FROM nested
    ''')
    ..execute('''
      CREATE VIEW rename_derived_dependent_view AS
      SELECT label FROM (
        SELECT old_name AS label FROM rename_nested_source
      ) AS nested
    ''')
    ..execute('''
      CREATE VIEW rename_scalar_dependent_view AS
      SELECT (
        SELECT old_name FROM rename_nested_source LIMIT 1
      ) AS label
    ''')
    ..execute('''
      CREATE VIEW rename_mixed_nested_dependent_view AS
      SELECT source.old_name AS root_label,
             (SELECT old_name FROM rename_nested_aux LIMIT 1) AS nested_label
      FROM rename_nested_source AS source
    ''')
    ..execute('''
      CREATE VIEW rename_compound_dependent_view AS
      SELECT old_name AS label FROM rename_nested_source
      UNION ALL
      SELECT old_name AS label FROM rename_nested_source
    ''')
    ..execute('''
      ALTER TABLE rename_nested_source
      RENAME COLUMN old_name TO new_name
    ''');
  for (final view in [
    'rename_cte_dependent_view',
    'rename_derived_dependent_view',
    'rename_scalar_dependent_view',
  ]) {
    assert(
      renameColumnDb.select('SELECT label FROM $view').single['label'] ==
          'nested',
    );
  }
  final renamedCompoundView = renameColumnDb.select('''
    SELECT label FROM rename_compound_dependent_view ORDER BY label
  ''');
  assert(renamedCompoundView.length == 2);
  assert(renamedCompoundView.every((row) => row['label'] == 'nested'));
  final mixedNestedView = renameColumnDb
      .select(
        'SELECT root_label, nested_label FROM rename_mixed_nested_dependent_view',
      )
      .single;
  assert(mixedNestedView['root_label'] == 'nested');
  assert(mixedNestedView['nested_label'] == 'inner');
  renameColumnDb
    ..execute('CREATE TABLE rename_ambiguous_target (old_name TEXT)')
    ..execute('CREATE TABLE rename_ambiguous_other (old_name TEXT)')
    ..execute('''
      CREATE VIEW rename_ambiguous_view AS
      SELECT old_name FROM rename_ambiguous_target
      JOIN rename_ambiguous_other ON 1 = 1
    ''');
  try {
    renameColumnDb.execute('''
      ALTER TABLE rename_ambiguous_target
      RENAME COLUMN old_name TO new_name
    ''');
    assert(false, 'ambiguous unqualified view references must be rejected');
  } on PureSqlException {
    assert(
      renameColumnDb
              .select('PRAGMA table_info(rename_ambiguous_target)')
              .single['name'] ==
          'old_name',
    );
  }
  renameColumnDb.execute('''
    CREATE TABLE rename_column_child (
      parent_id INTEGER REFERENCES rename_column_probe
    )
  ''');
  renameColumnDb
    ..execute('PRAGMA foreign_keys = ON')
    ..execute('INSERT INTO rename_column_child VALUES (1)')
    ..execute('ALTER TABLE rename_column_probe RENAME COLUMN id TO new_id');
  assert(renameColumnDb.select('PRAGMA foreign_key_check').isEmpty);
  assert(
    renameColumnDb
            .select('SELECT new_id FROM rename_column_probe')
            .single['new_id'] ==
        1,
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
  dropColumnDb.execute(
    'CREATE TABLE drop_constraint_parent (id INTEGER PRIMARY KEY)',
  );
  dropColumnDb.execute('''
    CREATE TABLE drop_unconstrained_column (
      id INTEGER,
      keep INTEGER,
      remove_me TEXT,
      PRIMARY KEY (id, keep),
      UNIQUE (keep),
      CHECK (keep > 0),
      FOREIGN KEY (keep) REFERENCES drop_constraint_parent(id)
    )
  ''');
  dropColumnDb
    ..execute('INSERT INTO drop_constraint_parent VALUES (2)')
    ..execute("INSERT INTO drop_unconstrained_column VALUES (1, 2, 'gone')")
    ..execute('ALTER TABLE drop_unconstrained_column DROP COLUMN remove_me');
  assert(
    dropColumnDb
            .select('SELECT id, keep FROM drop_unconstrained_column')
            .single['keep'] ==
        2,
  );
  assert(
    dropColumnDb
            .select('PRAGMA foreign_key_list(drop_unconstrained_column)')
            .single['from'] ==
        'keep',
  );
  assert(
    dropColumnDb
            .select('PRAGMA table_info(drop_unconstrained_column)')
            .map((row) => row['pk'])
            .join(',') ==
        '1,2',
  );
  for (final invalidInsert in [
    'INSERT INTO drop_unconstrained_column VALUES (2, 2)',
    'INSERT INTO drop_unconstrained_column VALUES (2, -1)',
  ]) {
    try {
      dropColumnDb.execute(invalidInsert);
      assert(false, 'unrelated table constraints should remain after DROP');
    } on PureSqlException {
      // The existing UNIQUE and CHECK constraints remain active.
    }
  }
  dropColumnDb
    ..execute('CREATE TABLE drop_unrelated_view (remove_me TEXT, keep TEXT)')
    ..execute("INSERT INTO drop_unrelated_view VALUES ('gone', 'visible')")
    ..execute('''
      CREATE VIEW drop_unrelated_view_projection AS
      SELECT keep FROM drop_unrelated_view
    ''')
    ..execute('ALTER TABLE drop_unrelated_view DROP COLUMN remove_me');
  assert(
    dropColumnDb
            .select('SELECT keep FROM drop_unrelated_view_projection')
            .single['keep'] ==
        'visible',
  );
  dropColumnDb
    ..execute('CREATE TABLE drop_dependent_view (remove_me TEXT, keep TEXT)')
    ..execute("INSERT INTO drop_dependent_view VALUES ('gone', 'visible')")
    ..execute('''
      CREATE VIEW drop_dependent_view_projection AS
      SELECT remove_me FROM drop_dependent_view
    ''')
    ..execute('ALTER TABLE drop_dependent_view DROP COLUMN remove_me');
  var dependentViewFailsOnUse = false;
  try {
    dropColumnDb.select('SELECT * FROM drop_dependent_view_projection');
  } on PureSqlException catch (error) {
    dependentViewFailsOnUse = error.message.contains('no such column');
  }
  assert(dependentViewFailsOnUse);
  dropColumnDb
    ..execute('CREATE TABLE drop_wildcard_view (remove_me TEXT, keep TEXT)')
    ..execute("INSERT INTO drop_wildcard_view VALUES ('gone', 'visible')")
    ..execute(
      'CREATE VIEW drop_wildcard_view_projection AS SELECT * FROM drop_wildcard_view',
    )
    ..execute('ALTER TABLE drop_wildcard_view DROP COLUMN remove_me');
  final wildcardViewAfterDrop = dropColumnDb
      .select('SELECT * FROM drop_wildcard_view_projection')
      .single;
  assert(wildcardViewAfterDrop.length == 1);
  assert(wildcardViewAfterDrop['keep'] == 'visible');
  dropColumnDb.execute('''
    CREATE TABLE drop_unindexed_column (
      id INTEGER PRIMARY KEY,
      remove_me TEXT,
      indexed_value TEXT
    )
  ''');
  dropColumnDb.execute(
    'CREATE INDEX drop_unindexed_column_idx ON drop_unindexed_column(indexed_value)',
  );
  dropColumnDb.execute(
    "INSERT INTO drop_unindexed_column VALUES (1, 'gone', 'retained')",
  );
  dropColumnDb.execute(
    'ALTER TABLE drop_unindexed_column DROP COLUMN remove_me',
  );
  assert(
    dropColumnDb
            .select('SELECT indexed_value FROM drop_unindexed_column')
            .single['indexed_value'] ==
        'retained',
  );
  assert(
    dropColumnDb
            .select('PRAGMA index_info(drop_unindexed_column_idx)')
            .single['name'] ==
        'indexed_value',
  );
  dropColumnDb.execute('''
    CREATE TABLE drop_indexed_column (
      id INTEGER PRIMARY KEY,
      remove_me TEXT,
      indexed_value TEXT
    )
  ''');
  dropColumnDb.execute(
    'CREATE INDEX drop_indexed_column_idx ON drop_indexed_column(remove_me)',
  );
  try {
    dropColumnDb.execute('''
      ALTER TABLE drop_indexed_column DROP COLUMN remove_me
    ''');
    assert(false, 'dropping an indexed column should fail');
  } on PureSqlException {
    // Expected; the index key depends on this column.
  }
  dropColumnDb.execute('''
    CREATE TABLE drop_partial_index_column (
      id INTEGER PRIMARY KEY,
      remove_me TEXT,
      indexed_value TEXT
    )
  ''');
  dropColumnDb.execute('''
    CREATE INDEX drop_partial_index_column_idx
    ON drop_partial_index_column(indexed_value)
    WHERE remove_me IS NOT NULL
  ''');
  try {
    dropColumnDb.execute('''
      ALTER TABLE drop_partial_index_column DROP COLUMN remove_me
    ''');
    assert(false, 'dropping a partial-index predicate column should fail');
  } on PureSqlException {
    // Expected; the partial index still references this column.
  }
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
  final commaJoin = joinDb.select(
    'SELECT COUNT(*) AS count FROM join_left, join_right',
  );
  assert(commaJoin.single['count'] == 4);
  final filteredCommaJoin = joinDb.select('''
    SELECT join_left.id AS left_id, join_right.id AS right_id
    FROM join_left, join_right
    WHERE join_left.id = join_right.id
  ''');
  assert(
    filteredCommaJoin.length == 1 &&
        filteredCommaJoin.single['left_id'] == 2 &&
        filteredCommaJoin.single['right_id'] == 2,
  );
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
  grouped.execute('CREATE TABLE null_order (value INTEGER)');
  grouped.execute('INSERT INTO null_order VALUES (NULL), (2), (1)');
  final nullsLast = grouped.select(
    'SELECT value FROM null_order ORDER BY value NULLS LAST',
  );
  assert(nullsLast.map((row) => row['value']).join(',') == '1,2,null');
  final nullsFirstDescending = grouped.select(
    'SELECT value FROM null_order ORDER BY value DESC NULLS FIRST',
  );
  assert(
    nullsFirstDescending.map((row) => row['value']).join(',') == 'null,2,1',
  );
  final nullsLastWindow = grouped.select('''
    SELECT value, ROW_NUMBER() OVER (ORDER BY value NULLS LAST) AS position
    FROM null_order ORDER BY position
  ''');
  assert(nullsLastWindow.map((row) => row['value']).join(',') == '1,2,null');
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
  final cteMaterializationHints = grouped.select('''
    WITH materialized(value) AS MATERIALIZED (VALUES (3)),
         not_materialized(value) AS NOT MATERIALIZED (VALUES (4))
    SELECT materialized.value + not_materialized.value AS total
    FROM materialized CROSS JOIN not_materialized
  ''');
  assert(cteMaterializationHints.single['total'] == 7);
  final recursiveCteRows = grouped.select('''
    WITH RECURSIVE sequence(value) AS (
      SELECT 1
      UNION ALL
      SELECT value + 1 FROM sequence WHERE value < 5
    )
    SELECT value FROM sequence ORDER BY value
  ''');
  assert(recursiveCteRows.map((row) => row['value']).join(',') == '1,2,3,4,5');
  final longRecursiveCte = grouped.select('''
    WITH RECURSIVE sequence(value) AS (
      SELECT 1
      UNION ALL
      SELECT value + 1 FROM sequence WHERE value < 1105
    )
    SELECT value FROM sequence ORDER BY value
  ''');
  assert(longRecursiveCte.length == 1105);
  assert(longRecursiveCte.first['value'] == 1);
  assert(longRecursiveCte.last['value'] == 1105);
  final recursiveArms = grouped.select('''
    WITH RECURSIVE branches(value) AS (
      SELECT 1
      UNION ALL SELECT value + 1 FROM branches WHERE value < 3
      UNION ALL SELECT value + 2 FROM branches WHERE value < 3
    )
    SELECT value FROM branches ORDER BY value
  ''');
  assert(recursiveArms.map((row) => row['value']).join(',') == '1,2,3,3,4');
  final recursiveMultipleAnchors = grouped.select('''
    WITH RECURSIVE branches(value) AS (
      SELECT 1
      UNION SELECT 2
      UNION ALL
      SELECT value + 1 FROM branches WHERE value < 3
    )
    SELECT value FROM branches ORDER BY value
  ''');
  assert(
    recursiveMultipleAnchors.map((row) => row['value']).join(',') ==
        '1,2,2,3,3',
  );
  final recursivePriorityQueue = grouped.select('''
    WITH RECURSIVE priority(value) AS (
      VALUES (1)
      UNION ALL SELECT value + 1 FROM priority WHERE value < 3
      UNION ALL SELECT value + 10 FROM priority WHERE value < 2
      ORDER BY 1 DESC
      LIMIT 3
    )
    SELECT GROUP_CONCAT(value, ',') AS values FROM priority
  ''');
  assert(recursivePriorityQueue.single['values'] == '1,11,2');
  final recursiveOffset = grouped.select('''
    WITH RECURSIVE sequence(value) AS (
      VALUES (1)
      UNION ALL SELECT value + 1 FROM sequence WHERE value < 5
      LIMIT 2 OFFSET 1
    )
    SELECT GROUP_CONCAT(value, ',') AS values FROM sequence
  ''');
  assert(recursiveOffset.single['values'] == '2,3');
  final recursiveUnionBoundary = grouped.select('''
    WITH RECURSIVE stable(value) AS (
      SELECT 1
      UNION ALL SELECT 1
      UNION SELECT value FROM stable
    )
    SELECT COUNT(*) AS count FROM stable
  ''');
  assert(recursiveUnionBoundary.single['count'] == 1);
  final recursiveUnionArms = grouped.select('''
    WITH RECURSIVE branches(value) AS (
      SELECT 1
      UNION SELECT value + 1 FROM branches WHERE value < 3
      UNION SELECT value + 2 FROM branches WHERE value < 3
    )
    SELECT value FROM branches ORDER BY value
  ''');
  assert(recursiveUnionArms.map((row) => row['value']).join(',') == '1,2,3,4');
  try {
    grouped.select('''
      WITH RECURSIVE mixed(value) AS (
        SELECT 1
        UNION ALL SELECT value + 1 FROM mixed WHERE value < 2
        UNION SELECT value + 2 FROM mixed WHERE value < 2
      )
      SELECT value FROM mixed
    ''');
    assert(false, 'recursive arms with mixed UNION modes should fail');
  } on PureSqlException {
    // Expected; recursive arms use one consistent UNION mode.
  }
  try {
    grouped.select('''
      WITH RECURSIVE aggregated(value) AS (
        SELECT 1
        UNION ALL SELECT SUM(value) FROM aggregated WHERE value < 2
      )
      SELECT value FROM aggregated
    ''');
    assert(false, 'recursive arms must reject aggregate functions');
  } on PureSqlException {
    // Expected; SQLite recursive SELECTs cannot contain aggregates.
  }
  final recursiveUnion = grouped.select('''
    WITH RECURSIVE stable(value) AS (
      SELECT 1 UNION SELECT value FROM stable
    )
    SELECT COUNT(*) AS count FROM stable
  ''');
  assert(recursiveUnion.single['count'] == 1);

  final windowDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE window_rows (id INTEGER, bucket TEXT, value INTEGER)',
    )
    ..execute(
      "INSERT INTO window_rows VALUES (1, 'a', 10), (2, 'a', 20), (3, 'b', 5), (4, 'a', 20)",
    );
  final windowRows = windowDb.select('''
    SELECT id,
           ROW_NUMBER() OVER (PARTITION BY bucket ORDER BY value, id) AS row_num,
           RANK() OVER (PARTITION BY bucket ORDER BY value) AS rank_num,
           DENSE_RANK() OVER (PARTITION BY bucket ORDER BY value) AS dense_num,
           LAG(value, 1, -1) OVER (PARTITION BY bucket ORDER BY value, id) AS previous,
           LEAD(value) OVER (PARTITION BY bucket ORDER BY value, id) AS next,
           SUM(value) OVER (PARTITION BY bucket ORDER BY value) AS running_sum,
           COUNT(*) OVER (PARTITION BY bucket) AS bucket_count
    FROM window_rows
    ORDER BY id
  ''');
  assert(windowRows.length == 4);
  assert(windowRows[0]['row_num'] == 1 && windowRows[0]['rank_num'] == 1);
  assert(windowRows[0]['previous'] == -1 && windowRows[0]['next'] == 20);
  assert(
    windowRows[0]['running_sum'] == 10 && windowRows[0]['bucket_count'] == 3,
  );
  assert(windowRows[1]['row_num'] == 2 && windowRows[1]['rank_num'] == 2);
  assert(windowRows[1]['dense_num'] == 2 && windowRows[1]['previous'] == 10);
  assert(windowRows[1]['running_sum'] == 50 && windowRows[1]['next'] == 20);
  assert(windowRows[3]['row_num'] == 3 && windowRows[3]['rank_num'] == 2);
  assert(windowRows[3]['running_sum'] == 50 && windowRows[3]['next'] == null);
  final windowStringAgg = windowDb.select('''
    SELECT STRING_AGG(bucket, ',') OVER (ORDER BY id) AS labels
    FROM window_rows ORDER BY id
  ''');
  assert(
    windowStringAgg.map((row) => row['labels']).join('|') ==
        'a|a,a|a,a,b|a,a,b,a',
  );
  final windowJsonArray = windowDb.select('''
    SELECT JSON_GROUP_ARRAY(value) OVER (
      ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
    ) AS values
    FROM window_rows ORDER BY id
  ''');
  assert(
    windowJsonArray.map((row) => row['values']).join('|') ==
        '[10]|[10,20]|[20,5]|[5,20]',
  );
  final windowPercentiles = windowDb.select('''
    SELECT MEDIAN(value) OVER (
      ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
    ) AS median_value
    FROM window_rows ORDER BY id
  ''');
  assert(
    windowPercentiles.map((row) => row['median_value']).join(',') ==
        '10.0,15.0,12.5,12.5',
  );
  assert(
    windowDb
            .select('SELECT MEDIAN(value) AS median FROM window_rows WHERE 0')
            .single['median'] ==
        null,
  );
  try {
    windowDb.select('SELECT PERCENTILE_CONT(value, 1.1) FROM window_rows');
    assert(false, 'percentile fractions outside 0..1 should fail');
  } on SqliteException {
    // Expected; continuous percentiles use a fraction parameter.
  }
  final windowValues = windowDb.select('''
    SELECT id,
           FIRST_VALUE(value) OVER (PARTITION BY bucket ORDER BY value) AS first_value,
           LAST_VALUE(value) OVER (PARTITION BY bucket ORDER BY value) AS last_value,
           NTH_VALUE(value, 2) OVER (PARTITION BY bucket ORDER BY value) AS second_value,
           NTILE(2) OVER (PARTITION BY bucket ORDER BY value, id) AS tile
    FROM window_rows
    ORDER BY id
  ''');
  assert(windowValues[0]['first_value'] == 10);
  assert(windowValues[0]['last_value'] == 10);
  assert(
    windowValues[0]['second_value'] == null && windowValues[0]['tile'] == 1,
  );
  assert(windowValues[1]['second_value'] == 20);
  assert(windowValues[1]['last_value'] == 20 && windowValues[1]['tile'] == 1);
  assert(windowValues[3]['tile'] == 2);
  final rankedWindow = windowDb.select('''
    SELECT id,
           PERCENT_RANK() OVER (ORDER BY value) AS percent_rank,
           CUME_DIST() OVER (ORDER BY value) AS cumulative_distribution
    FROM window_rows
    ORDER BY id
  ''');
  assert(rankedWindow[0]['percent_rank'] == 1 / 3);
  assert(rankedWindow[1]['percent_rank'] == 2 / 3);
  assert(rankedWindow[1]['cumulative_distribution'] == 1.0);
  final rowsFrame = windowDb.select('''
    SELECT id,
           SUM(value) OVER (
             PARTITION BY bucket ORDER BY id
             ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
           ) AS rolling_sum,
           SUM(value) OVER (
             PARTITION BY bucket ORDER BY id ROWS UNBOUNDED PRECEDING
           ) AS row_running_sum
    FROM window_rows
    ORDER BY id
  ''');
  assert(rowsFrame.map((row) => row['rolling_sum']).join(',') == '10,30,5,40');
  assert(
    rowsFrame.map((row) => row['row_running_sum']).join(',') == '10,30,5,50',
  );
  final excludedFrames = windowDb.select('''
    SELECT id,
           COUNT(*) OVER (
             ORDER BY value ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             EXCLUDE CURRENT ROW
           ) AS exclude_current,
           COUNT(*) OVER (
             ORDER BY value ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             EXCLUDE GROUP
           ) AS exclude_group,
           COUNT(*) OVER (
             ORDER BY value ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             EXCLUDE TIES
           ) AS exclude_ties,
           NTH_VALUE(value, 2) OVER (
             ORDER BY value ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             EXCLUDE CURRENT ROW
           ) AS second_after_exclusion,
           COUNT(*) OVER (
             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
             EXCLUDE GROUP
           ) AS no_order_group
    FROM window_rows
    ORDER BY id
  ''');
  assert(
    excludedFrames.map((row) => row['exclude_current']).join(',') == '1,2,0,3',
  );
  assert(
    excludedFrames.map((row) => row['exclude_group']).join(',') == '1,2,0,2',
  );
  assert(
    excludedFrames.map((row) => row['exclude_ties']).join(',') == '2,3,1,3',
  );
  assert(
    excludedFrames
            .map((row) => row['second_after_exclusion'] ?? '-')
            .join(',') ==
        '-,10,-,10',
  );
  assert(excludedFrames.every((row) => row['no_order_group'] == 0));
  final groupsFrames = windowDb.select('''
    SELECT id,
           SUM(value) OVER (
             ORDER BY value GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW
           ) AS preceding_group_sum,
           SUM(value) OVER (
             ORDER BY value GROUPS BETWEEN CURRENT ROW AND CURRENT ROW
           ) AS peer_group_sum,
           COUNT(*) OVER (
             ORDER BY value GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW
             EXCLUDE GROUP
           ) AS prior_rows
    FROM window_rows
    ORDER BY id
  ''');
  assert(
    groupsFrames.map((row) => row['preceding_group_sum']).join(',') ==
        '15,50,5,50',
  );
  assert(
    groupsFrames.map((row) => row['peer_group_sum']).join(',') == '10,40,5,40',
  );
  assert(groupsFrames.map((row) => row['prior_rows']).join(',') == '1,1,0,1');
  final rangeFrames = windowDb.select('''
    SELECT id,
           SUM(value) OVER (
             ORDER BY value RANGE BETWEEN 5 PRECEDING AND CURRENT ROW
           ) AS range_preceding,
           SUM(value) OVER (
             ORDER BY value DESC RANGE BETWEEN 5 PRECEDING AND CURRENT ROW
           ) AS descending_preceding,
           SUM(value) OVER (
             ORDER BY value RANGE BETWEEN CURRENT ROW AND 5 FOLLOWING
           ) AS range_following,
           SUM(value) OVER (
             ORDER BY value RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS range_running
    FROM window_rows
    ORDER BY id
  ''');
  assert(
    rangeFrames.map((row) => row['range_preceding']).join(',') == '15,40,5,40',
  );
  assert(
    rangeFrames.map((row) => row['descending_preceding']).join(',') ==
        '10,40,15,40',
  );
  assert(
    rangeFrames.map((row) => row['range_following']).join(',') == '10,40,15,40',
  );
  assert(
    rangeFrames.map((row) => row['range_running']).join(',') == '15,55,5,55',
  );
  final fractionalRangeDb = PureDatabase.memory()
    ..execute(
      'CREATE TABLE fractional_range (id INTEGER, x REAL, value INTEGER)',
    )
    ..execute(
      'INSERT INTO fractional_range VALUES (1, 1.0, 1), (2, 2.2, 2), (3, 2.5, 3), (4, 4.0, 4)',
    );
  final fractionalRange = fractionalRangeDb.select('''
    SELECT id,
           SUM(value) OVER (
             ORDER BY x RANGE BETWEEN 1.0 PRECEDING AND CURRENT ROW
           ) AS preceding,
           SUM(value) OVER (
             ORDER BY x RANGE BETWEEN CURRENT ROW AND 1.0 FOLLOWING
           ) AS following
    FROM fractional_range
    ORDER BY id
  ''');
  assert(fractionalRange.map((row) => row['preceding']).join(',') == '1,2,5,4');
  assert(fractionalRange.map((row) => row['following']).join(',') == '1,5,3,4');
  final parameterRange = fractionalRangeDb.select(
    '''
    SELECT SUM(value) OVER (
      ORDER BY x RANGE BETWEEN ? PRECEDING AND CURRENT ROW
    ) AS total
    FROM fractional_range
    ORDER BY id
  ''',
    [1.0],
  );
  assert(parameterRange.map((row) => row['total']).join(',') == '1,2,5,4');
  final textRangeDb = PureDatabase.memory()
    ..execute('CREATE TABLE text_range (key TEXT, value INTEGER)')
    ..execute(
      "INSERT INTO text_range VALUES ('a', 1), ('b', 2), ('b', 3), ('c', 4)",
    );
  assert(
    textRangeDb
            .select('''
              SELECT SUM(value) OVER (
                ORDER BY key RANGE BETWEEN 1 PRECEDING AND CURRENT ROW
              ) AS total
              FROM text_range ORDER BY key
            ''')
            .map((row) => row['total'])
            .join(',') ==
        '1,5,5,4',
  );
  final namedWindows = windowDb.select('''
    SELECT id,
           ROW_NUMBER() OVER by_bucket AS row_num,
           SUM(value) OVER running AS running_sum
    FROM window_rows
    WINDOW by_bucket AS (PARTITION BY bucket ORDER BY id),
           running AS (
             PARTITION BY bucket ORDER BY id
             ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
           )
    ORDER BY id
  ''');
  assert(namedWindows.map((row) => row['row_num']).join(',') == '1,2,1,3');
  assert(
    namedWindows.map((row) => row['running_sum']).join(',') == '10,30,5,40',
  );
  final groupedWindows = windowDb.select('''
    SELECT bucket,
           COUNT(*) AS count,
           ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, bucket) AS rank,
           LAG(COUNT(*)) OVER (ORDER BY bucket) AS previous_count,
           SUM(COUNT(*)) OVER () AS total_count,
           SUM(SUM(value)) OVER (
             ORDER BY bucket ROWS UNBOUNDED PRECEDING
           ) AS running_value
    FROM window_rows
    GROUP BY bucket
    ORDER BY bucket
  ''');
  assert(groupedWindows[0]['count'] == 3 && groupedWindows[0]['rank'] == 1);
  assert(groupedWindows[0]['previous_count'] == null);
  assert(groupedWindows[0]['total_count'] == 4);
  assert(groupedWindows[0]['running_value'] == 50);
  assert(groupedWindows[1]['count'] == 1 && groupedWindows[1]['rank'] == 2);
  assert(groupedWindows[1]['previous_count'] == 3);
  assert(groupedWindows[1]['total_count'] == 4);
  assert(groupedWindows[1]['running_value'] == 55);
  final havingWindows = windowDb.select('''
    SELECT bucket, COUNT(*) AS count,
           ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rank
    FROM window_rows
    GROUP BY bucket
    HAVING COUNT(*) > 1
  ''');
  assert(havingWindows.length == 1 && havingWindows.single['rank'] == 1);
  try {
    windowDb.select('SELECT ROW_NUMBER() OVER missing FROM window_rows');
    assert(false, 'unknown named windows should be rejected');
  } on PureSqlException {
    // Expected; named windows must be declared by the SELECT.
  }
  final chainedWindow = windowDb.select('''
    SELECT id,
           SUM(value) OVER (
             by_bucket ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
           ) AS running_sum,
           SUM(value) OVER (by_bucket RANGE 1 PRECEDING) AS range_sum
    FROM window_rows
    WINDOW by_bucket AS (PARTITION BY bucket ORDER BY id)
    ORDER BY id
  ''');
  assert(
    chainedWindow.map((row) => row['running_sum']).join(',') == '10,30,5,40',
  );
  assert(
    chainedWindow.map((row) => row['range_sum']).join(',') == '10,30,5,20',
  );
  final chainedDefinition = windowDb.select('''
    SELECT id, SUM(value) OVER running AS running_sum
    FROM window_rows
    WINDOW by_bucket AS (PARTITION BY bucket),
           running AS (
             by_bucket ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
           )
    ORDER BY id
  ''');
  assert(
    chainedDefinition.map((row) => row['running_sum']).join(',') ==
        '10,30,5,40',
  );
  final forwardWindowReference = windowDb.select('''
    SELECT id, SUM(value) OVER child AS running_sum
    FROM window_rows
    WINDOW child AS (parent ORDER BY id),
           parent AS (PARTITION BY bucket)
    ORDER BY id
  ''');
  assert(
    forwardWindowReference.map((row) => row['running_sum']).join(',') ==
        '10,30,35,55',
  );
  for (final invalidWindow in [
    '''SELECT ROW_NUMBER() OVER (by_bucket PARTITION BY bucket)
       FROM window_rows WINDOW by_bucket AS (ORDER BY id)''',
    '''SELECT ROW_NUMBER() OVER child FROM window_rows
       WINDOW parent AS (ORDER BY id), child AS (parent ORDER BY value)''',
    '''SELECT ROW_NUMBER() OVER child FROM window_rows
       WINDOW parent AS (ORDER BY id ROWS CURRENT ROW), child AS (parent)''',
  ]) {
    try {
      windowDb.select(invalidWindow);
      assert(false, 'invalid inherited window specifications should fail');
    } on PureSqlException {
      // Chaining cannot override PARTITION/ORDER or inherit a frame.
    }
  }
  for (final invalidRange in [
    'SELECT SUM(value) OVER (ORDER BY value, id RANGE 1 PRECEDING) FROM window_rows',
    'SELECT SUM(value) OVER (RANGE 1 PRECEDING) FROM window_rows',
    'SELECT SUM(value) OVER (ORDER BY value RANGE value PRECEDING) FROM window_rows',
    'SELECT SUM(value) OVER (ORDER BY value RANGE -1 PRECEDING) FROM window_rows',
  ]) {
    try {
      windowDb.select(invalidRange);
      assert(false, 'invalid RANGE offsets/order terms should be rejected');
    } on PureSqlException {
      // Expected; offset boundaries need a single key and non-negative value.
    }
  }
  try {
    windowDb.select(
      'SELECT SUM(value) OVER (EXCLUDE CURRENT ROW) FROM window_rows',
    );
    assert(false, 'EXCLUDE without a frame should be rejected');
  } on PureSqlException {
    // Expected; EXCLUDE is a component of a frame specification.
  }

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
  final patternFunctions = db.select('''
    SELECT LIKE('a%', 'ABC') AS like_function,
           GLOB('a*', 'abc') AS glob_function,
           UNHEX('4D-5A', '-') AS decoded,
           UNHEX('4D-A5', 'A-') AS hex_ignore,
           UNHEX('-4D--5A-', '-') AS byte_separators,
           UNHEX('4-D', '-') AS split_byte,
           UNHEX('4D5', '-') AS invalid_hex,
           IF(0, 'first', 1, 'second', 'else') AS if_branch,
           IIF(0, 'first', 1, 'second', 'else') AS later_branch,
           IIF(NULL, 'first', 'fallback') AS null_condition,
           IIF(0, 'first') AS no_else
  ''').single;
  assert(patternFunctions['like_function'] == true);
  assert(patternFunctions['glob_function'] == true);
  assert((patternFunctions['decoded'] as List<int>).join(',') == '77,90');
  assert((patternFunctions['hex_ignore'] as List<int>).join(',') == '77,165');
  assert(
    (patternFunctions['byte_separators'] as List<int>).join(',') == '77,90',
  );
  assert(patternFunctions['split_byte'] == null);
  assert(patternFunctions['invalid_hex'] == null);
  assert(patternFunctions['if_branch'] == 'second');
  assert(patternFunctions['later_branch'] == 'second');
  assert(patternFunctions['null_condition'] == 'fallback');
  assert(patternFunctions['no_else'] == null);
  final jsonFunctions = db.select(r'''
    SELECT json_valid('{"a":null}') AS valid_object,
           json_valid('null') AS valid_null,
           json_valid('not JSON') AS invalid_json,
           json_valid('{a:1}') AS strict_json5_invalid,
           json_valid('{a:01}', 2) AS invalid_json5_number,
           json_valid('{"a":1}', 1) AS strict_flag,
           json_valid('{"a":1}', 2) AS json5_flag,
           json_valid('{a:1}', 2) AS json5_valid,
           json_valid('[]', 4) AS jsonb_only,
           json_error_position('{"a":1}') AS valid_json_position,
           json_error_position('{') AS missing_json_position,
           json_error_position('{a:1,}') AS json5_position,
           json_error_position('abc') AS invalid_json_position,
           json_error_position(NULL) AS null_json_position,
           json_pretty('{"a":[1,2]}') AS pretty_json,
           json_pretty('{"a":1}', '.') AS custom_pretty_json,
           json_valid(CAST('{"a":1}' AS BLOB)) AS valid_json_blob,
           json_valid(NULL) AS null_input,
           json(' { "a" : 1 } ') AS normalized_json,
           json('{unquoted: ''single'', \u006bey: ''escaped'', list:[+0x10,.5,1.,], /* comment */ trailing:''ok'',}') AS normalized_json5,
           json('{n:qNaN}') AS qnan_json5,
           json('{p:+INF}') AS positive_inf_json5,
           json('{m:-InF}') AS negative_inf_json5,
           json_pretty('{pos:Infinity}') AS pretty_nonfinite_json5,
           json_extract('{unquoted: ''single''}', '$.unquoted') AS extracted_json5,
           json_array(1, 'x', NULL, TRUE) AS constructed_array,
           json_array() AS empty_array,
           json_array_insert('[1,2,3]', '$[1]', 9) AS inserted_array_value,
           json_array_insert('{"items":[1,2]}', '$.items[#]', 3) AS appended_array_value,
           json_array_insert('[1,2,3]', '$[0]', 0, '$[2]', 9) AS sequential_array_values,
           json_object('a', 1, 'b', 'x') AS constructed_object,
           json_object() AS empty_object,
           json_set('{"a":1,"items":[2,3]}', '$.a', 9, '$.b', 'new') AS set_values,
           json_insert('{"a":1}', '$.a', 2, '$.b', 3) AS inserted_values,
           json_replace('{"a":1}', '$.a', 2, '$.missing', 3) AS replaced_values,
           json_remove('{"a":1,"items":[2,3]}', '$.a', '$.items[0]') AS removed_values,
           json_set('[1]', '$[#]', 2) AS appended_value,
           json_patch('{"a":1,"b":2}', '{"a":null,"c":[3]}') AS patched_value,
           json_type('{"items":[null,true,1,1.5,"x",{}]}', '$.items[1]') AS boolean_type,
           json_type('{"items":[null,true,1,1.5,"x",{}]}', '$.items[3]') AS real_type,
           json_type('null') AS null_type,
           json_array_length('{"items":[1,2]}', '$.items') AS array_length,
           json_array_length('{"items":1}', '$.items') AS scalar_length,
           json_array_length('{"items":[1]}', '$.missing') AS missing_length,
           json_extract('{"items":[true,2],"quoted.key":9}', '$.items[0]') AS extracted_boolean,
           json_extract('{"items":[true,2],"quoted.key":9}', '$.items[#-1]') AS extracted_last,
           json_extract('{"items":[true,2]}', '$.items') AS extracted_array,
           json_extract('{"items":[2]}', '$.items[0]', '$.missing') AS extracted_paths,
           json_extract('{"items":[2]}', '$.missing') AS missing_value,
           json_extract('{"quoted.key":9}', '$."quoted.key"') AS quoted_key,
           json_quote('a "quote"') AS quoted_text,
           json_quote(TRUE) AS quoted_boolean,
           json_quote(NULL) AS quoted_null
  ''').single;
  assert(jsonFunctions['valid_object'] == 1);
  assert(jsonFunctions['valid_null'] == 1);
  assert(jsonFunctions['invalid_json'] == 0);
  assert(jsonFunctions['strict_json5_invalid'] == 0);
  assert(jsonFunctions['invalid_json5_number'] == 0);
  assert(jsonFunctions['strict_flag'] == 1);
  assert(jsonFunctions['json5_flag'] == 1);
  assert(jsonFunctions['json5_valid'] == 1);
  assert(jsonFunctions['jsonb_only'] == 0);
  assert(jsonFunctions['valid_json_position'] == 0);
  assert(jsonFunctions['missing_json_position'] == 2);
  assert(jsonFunctions['json5_position'] == 0);
  assert(jsonFunctions['invalid_json_position'] == 1);
  assert(jsonFunctions['null_json_position'] == null);
  assert(
    jsonFunctions['pretty_json'] ==
        '{\n    "a": [\n        1,\n        2\n    ]\n}',
  );
  assert(jsonFunctions['custom_pretty_json'] == '{\n."a": 1\n}');
  assert(jsonFunctions['valid_json_blob'] == 1);
  assert(jsonFunctions['null_input'] == null);
  assert(jsonFunctions['normalized_json'] == '{"a":1}');
  assert(
    jsonFunctions['normalized_json5'] ==
        '{"unquoted":"single","key":"escaped","list":[16,0.5,1.0],"trailing":"ok"}',
  );
  assert(jsonFunctions['qnan_json5'] == '{"n":null}');
  assert(jsonFunctions['positive_inf_json5'] == '{"p":9e999}');
  assert(jsonFunctions['negative_inf_json5'] == '{"m":-9e999}');
  assert(jsonFunctions['pretty_nonfinite_json5'] == '{\n    "pos": 9e999\n}');
  assert(jsonFunctions['extracted_json5'] == 'single');
  assert(jsonFunctions['constructed_array'] == '[1,"x",null,1]');
  assert(jsonFunctions['empty_array'] == '[]');
  assert(jsonFunctions['inserted_array_value'] == '[1,9,2,3]');
  assert(jsonFunctions['appended_array_value'] == '{"items":[1,2,3]}');
  assert(jsonFunctions['sequential_array_values'] == '[0,1,9,2,3]');
  assert(jsonFunctions['constructed_object'] == '{"a":1,"b":"x"}');
  assert(jsonFunctions['empty_object'] == '{}');
  assert(jsonFunctions['set_values'] == '{"a":9,"items":[2,3],"b":"new"}');
  assert(jsonFunctions['inserted_values'] == '{"a":1,"b":3}');
  assert(jsonFunctions['replaced_values'] == '{"a":2}');
  assert(jsonFunctions['removed_values'] == '{"items":[3]}');
  assert(jsonFunctions['appended_value'] == '[1,2]');
  assert(jsonFunctions['patched_value'] == '{"b":2,"c":[3]}');
  assert(jsonFunctions['boolean_type'] == 'true');
  assert(jsonFunctions['real_type'] == 'real');
  assert(jsonFunctions['null_type'] == 'null');
  assert(jsonFunctions['array_length'] == 2);
  assert(jsonFunctions['scalar_length'] == 0);
  assert(jsonFunctions['missing_length'] == null);
  assert(jsonFunctions['extracted_boolean'] == 1);
  assert(jsonFunctions['extracted_last'] == 2);
  assert(jsonFunctions['extracted_array'] == '[true,2]');
  assert(jsonFunctions['extracted_paths'] == '[2,null]');
  assert(jsonFunctions['missing_value'] == null);
  assert(jsonFunctions['quoted_key'] == 9);
  assert(jsonFunctions['quoted_text'] == '"a \\"quote\\""');
  assert(jsonFunctions['quoted_boolean'] == '1');
  assert(jsonFunctions['quoted_null'] == 'null');
  final jsonSubtypes = db.select(r'''
    SELECT subtype(NULL) AS null_value,
           subtype(json('[]')) AS json_text,
           subtype(jsonb('[]')) AS jsonb_blob,
           subtype(json_extract('{"a":[1]}', '$.a')) AS extracted_array,
           subtype(json_extract('{"a":"[1]"}', '$.a')) AS extracted_text,
           subtype('[]' -> '$') AS json_arrow,
           subtype('[]' ->> '$') AS scalar_arrow,
           subtype(coalesce(json('[]'), '[]')) AS coalesced,
           subtype(CAST(json('[]') AS TEXT)) AS casted,
           subtype(CASE WHEN 1 THEN json('[]') ELSE '[]' END) AS cased,
           subtype(json_group_array(1)) AS text_aggregate,
           subtype(jsonb_group_array(1)) AS blob_aggregate
  ''').single;
  assert(jsonSubtypes['null_value'] == 0);
  assert(jsonSubtypes['json_text'] == 74);
  assert(jsonSubtypes['jsonb_blob'] == 0);
  assert(jsonSubtypes['extracted_array'] == 74);
  assert(jsonSubtypes['extracted_text'] == 0);
  assert(jsonSubtypes['json_arrow'] == 74);
  assert(jsonSubtypes['scalar_arrow'] == 0);
  assert(jsonSubtypes['coalesced'] == 74);
  assert(jsonSubtypes['casted'] == 74);
  assert(jsonSubtypes['cased'] == 74);
  assert(jsonSubtypes['text_aggregate'] == 74);
  assert(jsonSubtypes['blob_aggregate'] == 0);
  final jsonbValue = db.select("SELECT jsonb('[]') AS value").single['value'];
  assert(jsonbValue is List<int>);
  assert((jsonbValue as List<int>).join(',') == '11');
  final jsonbFunctions = db.select(r'''
    SELECT jsonb(' {"a":[1,true,"x"]} ') AS encoded,
           typeof(jsonb(' {"a":[1,true,"x"]} ')) AS encoded_type,
           json(jsonb(' {"a":[1,true,"x"]} ')) AS round_trip,
           json(x'8c17615b1331011778') AS native_blob,
           json(jsonb_array(1, 'x', NULL)) AS array_value,
           json(jsonb_object('a', 1, 'b', jsonb_array(2, 3))) AS object_value,
           json(jsonb_set(jsonb('{"a":1}'), '$.a', 9)) AS set_value,
           json(jsonb_patch(jsonb('{"a":1,"b":2}'), '{"a":null,"c":3}')) AS patch_value,
           json(jsonb_extract(jsonb('{"a":[1,2]}'), '$.a')) AS extracted_array,
           jsonb_extract(jsonb('{"a":1}'), '$.a') AS extracted_scalar,
           json_valid(jsonb('[1,2]'), 4) AS superficial_valid,
           json_valid(jsonb('[1,2]'), 8) AS strict_valid,
           json_valid(x'1bff', 4) AS shallow_only_valid,
           json_valid(x'1bff', 8) AS deep_invalid,
           json_error_position(jsonb('{"a":1}')) AS binary_error_position
  ''').single;
  assert(
    (jsonbFunctions['encoded'] as List<int>).join(',') ==
        '140,23,97,91,19,49,1,23,120',
  );
  assert(jsonbFunctions['encoded_type'] == 'blob');
  assert(jsonbFunctions['round_trip'] == '{"a":[1,true,"x"]}');
  assert(jsonbFunctions['native_blob'] == '{"a":[1,true,"x"]}');
  assert(jsonbFunctions['array_value'] == '[1,"x",null]');
  assert(jsonbFunctions['object_value'] == '{"a":1,"b":[2,3]}');
  assert(jsonbFunctions['set_value'] == '{"a":9}');
  assert(jsonbFunctions['patch_value'] == '{"b":2,"c":3}');
  assert(jsonbFunctions['extracted_array'] == '[1,2]');
  assert(jsonbFunctions['extracted_scalar'] == 1);
  assert(jsonbFunctions['superficial_valid'] == 1);
  assert(jsonbFunctions['strict_valid'] == 1);
  assert(jsonbFunctions['shallow_only_valid'] == 1);
  assert(jsonbFunctions['deep_invalid'] == 0);
  assert(jsonbFunctions['binary_error_position'] == 0);
  final jsonbAggregate = db.select('''
        SELECT json(jsonb_group_array(1)) AS value,
               typeof(jsonb_group_array(1)) AS value_type
      ''').single;
  assert(jsonbAggregate['value'] == '[1]');
  assert(jsonbAggregate['value_type'] == 'blob');
  final jsonOperators = db.select(r'''
    SELECT '{"name":"Ada","items":[10,20],"flag":true,"nil":null}' -> 'name' AS json_string,
           '{"name":"Ada","items":[10,20],"flag":true,"nil":null}' ->> 'name' AS text_string,
           '{"items":[10,20]}' -> '$.items[1]' AS indexed_json,
           '{"items":[10,20]}' ->> '$.items[#-1]' AS indexed_value,
           '[10,20]' -> 1 AS numeric_index,
           '[10,20]' ->> -1 AS negative_index,
           '{"items":[10,20]}' -> 'items' ->> 0 AS chained_value,
           '{"flag":true}' ->> 'flag' AS boolean_value,
           '{"nil":null}' -> 'nil' AS json_null,
           '{"nil":null}' ->> 'nil' AS sql_null,
           '{"name":"Ada"}' ->> 'missing' AS missing_value
  ''').single;
  assert(jsonOperators['json_string'] == '"Ada"');
  assert(jsonOperators['text_string'] == 'Ada');
  assert(jsonOperators['indexed_json'] == '20');
  assert(jsonOperators['indexed_value'] == 20);
  assert(jsonOperators['numeric_index'] == '20');
  assert(jsonOperators['negative_index'] == 20);
  assert(jsonOperators['chained_value'] == 10);
  assert(jsonOperators['boolean_value'] == 1);
  assert(jsonOperators['json_null'] == 'null');
  assert(jsonOperators['sql_null'] == null);
  assert(jsonOperators['missing_value'] == null);
  final jsonEachRows = db.select(r'''
    SELECT key, value, type, atom, id, parent, fullkey, path
    FROM json_each('{"name":"Ada","items":[true,2],"dotted.key":"ok"}')
    ORDER BY id
  ''');
  assert(jsonEachRows.length == 3);
  assert(jsonEachRows[0]['key'] == 'name');
  assert(jsonEachRows[0]['value'] == 'Ada');
  assert(jsonEachRows[0]['type'] == 'text');
  assert(jsonEachRows[0]['atom'] == 'Ada');
  assert(jsonEachRows[0]['id'] == 0);
  assert(jsonEachRows[0]['parent'] == null);
  assert(jsonEachRows[0]['fullkey'] == r'$.name');
  assert(jsonEachRows[0]['path'] == r'$');
  assert(jsonEachRows[1]['value'] == '[true,2]');
  assert(jsonEachRows[1]['type'] == 'array');
  assert(jsonEachRows[1]['atom'] == null);
  assert(jsonEachRows[2]['fullkey'] == r'$.' + '"dotted.key"');
  final jsonbEachRow = db.select('''
        SELECT key, type, typeof(value) AS value_type, json(value) AS value
        FROM jsonb_each(jsonb('{"items":[1,2]}'))
      ''').single;
  assert(jsonbEachRow['key'] == 'items');
  assert(jsonbEachRow['type'] == 'array');
  assert(jsonbEachRow['value_type'] == 'blob');
  assert(jsonbEachRow['value'] == '[1,2]');
  final jsonbTreeRoot = db.select('''
        SELECT type, typeof(value) AS value_type, json(value) AS value
        FROM jsonb_tree(jsonb('{"items":[1,2]}'))
        ORDER BY id LIMIT 1
      ''').single;
  assert(jsonbTreeRoot['type'] == 'object');
  assert(jsonbTreeRoot['value_type'] == 'blob');
  assert(jsonbTreeRoot['value'] == '{"items":[1,2]}');
  final jsonTreeRows = db.select(r'''
    SELECT key, value, type, atom, id, parent, fullkey, path
    FROM json_tree('{"name":"Ada","items":[true,2],"dotted.key":"ok"}')
    ORDER BY id
  ''');
  assert(jsonTreeRows.length == 6);
  assert(jsonTreeRows[0]['type'] == 'object');
  assert(jsonTreeRows[0]['parent'] == null);
  assert(jsonTreeRows[2]['key'] == 'items');
  assert(jsonTreeRows[2]['id'] == 2);
  assert(jsonTreeRows[3]['key'] == 0);
  assert(jsonTreeRows[3]['parent'] == 2);
  assert(jsonTreeRows[3]['type'] == 'true');
  assert(jsonTreeRows[3]['value'] == 1);
  assert(jsonTreeRows[3]['atom'] == 1);
  assert(jsonTreeRows[3]['path'] == r'$.items');
  assert(jsonTreeRows[5]['fullkey'] == r'$.' + '"dotted.key"');
  final jsonTreePathRows = db.select(r'''
    SELECT key, value, parent, fullkey, path
    FROM json_tree('{"a":{"b":5}}', '$.a')
    ORDER BY id
  ''');
  assert(jsonTreePathRows[0]['key'] == 'a');
  assert(jsonTreePathRows[0]['parent'] == null);
  assert(jsonTreePathRows[0]['fullkey'] == r'$.a');
  assert(jsonTreePathRows[0]['path'] == r'$');
  assert(jsonTreePathRows[1]['key'] == 'b');
  assert(jsonTreePathRows[1]['parent'] == 0);
  assert(jsonTreePathRows[1]['fullkey'] == r'$.a.b');
  assert(jsonTreePathRows[1]['path'] == r'$.a');
  final jsonEachPathRow = db
      .select(
        r"SELECT key, value, fullkey, path FROM json_each('[10,20]', '$[1]')",
      )
      .single;
  assert(jsonEachPathRow['key'] == null);
  assert(jsonEachPathRow['value'] == 20);
  assert(jsonEachPathRow['fullkey'] == r'$[1]');
  assert(jsonEachPathRow['path'] == r'$[1]');
  assert(db.select("SELECT * FROM json_each('42')").single['value'] == 42);
  assert(db.select(r"SELECT * FROM json_each('{}', '$.missing')").isEmpty);
  db
    ..execute('CREATE TABLE json_docs (id INTEGER PRIMARY KEY, payload TEXT)')
    ..execute(
      "INSERT INTO json_docs VALUES (1, '{\"values\":[3,4]}'), (2, '{\"values\":[5]}')",
    );
  final correlatedJsonRows = db.select(r'''
    SELECT d.id AS id, item.value AS value
    FROM json_docs AS d
    CROSS JOIN json_each(d.payload, '$.values') AS item
    ORDER BY d.id, item.key
  ''');
  assert(
    correlatedJsonRows.map((row) => '${row['id']}:${row['value']}').join(',') ==
        '1:3,1:4,2:5',
    '$correlatedJsonRows',
  );
  final leftJsonRows = db.select(r'''
    SELECT d.id AS id, item.value AS value
    FROM json_docs AS d
    LEFT JOIN json_each(d.payload, '$.values') AS item
      ON item.value > 4
    ORDER BY d.id, item.value
  ''');
  assert(leftJsonRows.length == 2);
  assert(leftJsonRows[0]['id'] == 1 && leftJsonRows[0]['value'] == null);
  assert(leftJsonRows[1]['id'] == 2 && leftJsonRows[1]['value'] == 5);
  final rightJsonRows = db.select(r'''
    SELECT d.id AS id, item.value AS value
    FROM json_docs AS d
    RIGHT JOIN json_each(json_array(d.id, d.id + 10)) AS item
      ON d.id = item.value
    ORDER BY item.value
  ''');
  assert(rightJsonRows.length == 3);
  assert(rightJsonRows.any((row) => row['id'] == 1 && row['value'] == 1));
  assert(rightJsonRows.any((row) => row['id'] == 2 && row['value'] == 2));
  assert(rightJsonRows.any((row) => row['id'] == null && row['value'] == null));
  final fullJsonRows = db.select(r'''
    SELECT d.id AS id, item.value AS value
    FROM json_docs AS d
    FULL JOIN json_each(json_array(d.id, d.id + 10)) AS item ON 0
  ''');
  assert(fullJsonRows.length == 4);
  assert(fullJsonRows.where((row) => row['id'] != null).length == 2);
  assert(fullJsonRows.every((row) => row['value'] == null));
  final uncorrelatedRightJsonRows = db.select(r'''
    SELECT d.id AS id, item.value AS value
    FROM json_docs AS d
    RIGHT JOIN json_each('[2,3]') AS item ON d.id = item.value
  ''');
  assert(uncorrelatedRightJsonRows.length == 2);
  assert(
    uncorrelatedRightJsonRows.any((row) => row['id'] == 2 && row['value'] == 2),
  );
  assert(
    uncorrelatedRightJsonRows.any(
      (row) => row['id'] == null && row['value'] == 3,
    ),
  );
  final rightJsonWithoutLeftRows = db.select(r'''
    SELECT d.id AS id, item.value AS value
    FROM (SELECT id FROM json_docs WHERE 0) AS d
    RIGHT JOIN json_each('[9]') AS item ON d.id = item.value
  ''');
  assert(rightJsonWithoutLeftRows.length == 1);
  assert(
    rightJsonWithoutLeftRows.single['id'] == null &&
        rightJsonWithoutLeftRows.single['value'] == 9,
  );
  for (final invalidJsonQuery in [
    "SELECT json_type('invalid')",
    "SELECT json_extract('{}', 'not-a-path')",
    "SELECT json('{invalid}')",
    "SELECT json_valid('[]', 0)",
    "SELECT json_object('name')",
    "SELECT json_object(NULL, 1)",
    r"SELECT json_array_insert('{}', '$.a', 1)",
    r"SELECT json_set('{}', '$.a')",
  ]) {
    try {
      db.select(invalidJsonQuery);
      assert(false, 'malformed JSON inputs and paths should be rejected');
    } on PureSqlException {
      // JSON_TYPE/EXTRACT report malformed JSON and paths as SQL errors.
    }
  }
  final formatFunctions = db.select('''
    SELECT FORMAT('%s:%04d:%.2f:%Q:%%', 'x', 7, 2.5, 'O''Reilly') AS formatted,
           printf('%*s', 5, 'x') AS padded,
           FORMAT('%!4s|%4s', '猫', '猫') AS widths,
           FORMAT('%,d', 1234567) AS grouped,
           FORMAT('%e|%E', 1, 1) AS exponential,
           FORMAT('%#Q', CHAR(10)) AS control_quote,
           PRINTF('%s|%Q|%d', NULL, NULL, NULL) AS null_values,
           FORMAT('%n%d', 7) AS ignored_count
  ''').single;
  assert(formatFunctions['formatted'] == "x:0007:2.50:'O''Reilly':%");
  assert(formatFunctions['padded'] == '    x');
  assert(formatFunctions['widths'] == '   猫| 猫');
  assert(formatFunctions['grouped'] == '1,234,567');
  assert(formatFunctions['exponential'] == '1.000000e+00|1.000000E+00');
  assert(formatFunctions['control_quote'] == r"unistr('\n')");
  assert(formatFunctions['null_values'] == '|NULL|0');
  assert(formatFunctions['ignored_count'] == '7');
  assert(
    db
            .select(
              "SELECT FORMAT('%#g|%#g|%!g|%!.4g', 1.2, 1, 1, 1.2) AS value",
            )
            .single['value'] ==
        '1.20000|1.00000|1.0|1.2',
  );
  assert(
    db
            .select(
              "SELECT printf('%.25f|%.25e', 1.2345678901234567, 1.2345678901234567) AS value",
            )
            .single['value'] ==
        '1.2345678901234570000000000|1.2345678901234570000000000e+00',
  );
  assert(
    db
            .select(
              "SELECT printf('%!f|%!.4f|%#!.4f|%!e|%!.4g', 1.2, 1.2, 1.2, 1.2, 1.2) AS value",
            )
            .single['value'] ==
        '1.2|1.2|1.2|1.2e+00|1.2',
  );
  assert(
    db
            .select(
              "SELECT printf('%#.0f|%!.0f|%#!.0f|%#.0e|%!.0e|%p|%#p', 1.0, 1.0, 1.0, 1.0, 1.0, 48879, 48879) AS value",
            )
            .single['value'] ==
        '1.|1.0|1.0|1.e+00|1.0e+00|BEEF|0xBEEF',
  );
  assert(
    db.select("SELECT hex(printf('%c', NULL)) AS value").single['value'] ==
        '00',
  );
  assert(
    db
            .select(
              "SELECT printf('%f|%+f|% f|%#f', -0.0, -0.0, -0.0, -0.0) AS value",
            )
            .single['value'] ==
        '0.000000|+0.000000| 0.000000|0.000000',
  );
  assert(
    db
        .select('PRAGMA function_list')
        .where((row) => row['builtin'] == 1)
        .map((row) => row['name'])
        .toSet()
        .containsAll([
          'FORMAT',
          'PRINTF',
          '->',
          '->>',
          'JSON',
          'JSON_ARRAY',
          'JSON_ARRAY_INSERT',
          'JSON_ARRAY_LENGTH',
          'JSONB',
          'JSONB_ARRAY',
          'JSONB_ARRAY_INSERT',
          'JSONB_EXTRACT',
          'JSONB_GROUP_ARRAY',
          'JSONB_GROUP_OBJECT',
          'JSONB_INSERT',
          'JSONB_OBJECT',
          'JSONB_PATCH',
          'JSONB_REMOVE',
          'JSONB_REPLACE',
          'JSONB_SET',
          'JSON_EXTRACT',
          'JSON_INSERT',
          'JSON_OBJECT',
          'JSON_PATCH',
          'JSON_PRETTY',
          'JSON_QUOTE',
          'JSON_REMOVE',
          'JSON_REPLACE',
          'JSON_SET',
          'JSON_TYPE',
          'JSON_VALID',
        ]),
  );
  assert(
    db
        .select('PRAGMA module_list')
        .map((row) => row['name'])
        .toSet()
        .containsAll(['json_each', 'json_tree', 'jsonb_each', 'jsonb_tree']),
  );
  assert(
    db.select("SELECT FORMAT('%#q', ?) AS escaped", [
          'a\\b',
        ]).single['escaped'] ==
        r'a\\b',
  );
  db.execute('PRAGMA case_sensitive_like = ON');
  assert(
    db.select("SELECT 'ABC' LIKE 'a%' AS matched").single['matched'] == false,
  );
  assert(
    db.select("SELECT LIKE('a%', 'ABC') AS matched").single['matched'] == false,
  );
  assert(
    db.select('PRAGMA case_sensitive_like').single['case_sensitive_like'] == 1,
  );
  db.execute('PRAGMA case_sensitive_like = OFF');
  assert(
    db.select("SELECT 'ABC' LIKE 'a%' AS matched").single['matched'] == true,
  );
  db
    ..execute('CREATE TEMP TABLE reverse_select_probe (value INTEGER)')
    ..execute('INSERT INTO reverse_select_probe VALUES (1), (2), (3)')
    ..execute('PRAGMA reverse_unordered_selects = OFF');
  List<int> reverseProbeValues(String query) =>
      db.select(query).map((row) => row['value'] as int).toList();
  assert(
    reverseProbeValues('SELECT value FROM reverse_select_probe').join(',') ==
        '1,2,3',
  );
  db.execute('PRAGMA reverse_unordered_selects = ON');
  assert(
    db
            .select('PRAGMA reverse_unordered_selects')
            .single['reverse_unordered_selects'] ==
        1,
  );
  assert(
    reverseProbeValues('SELECT value FROM reverse_select_probe').join(',') ==
        '3,2,1',
  );
  assert(
    reverseProbeValues(
          'SELECT value FROM reverse_select_probe LIMIT 2',
        ).join(',') ==
        '3,2',
  );
  assert(
    reverseProbeValues(
          'SELECT value FROM reverse_select_probe ORDER BY value',
        ).join(',') ==
        '1,2,3',
  );
  assert(
    db
            .select('SELECT 1 AS value UNION ALL SELECT 2 AS value')
            .map((row) => row['value'])
            .join(',') ==
        '1,2',
  );
  assert(
    db
        .select('PRAGMA pragma_list')
        .any((row) => row['name'] == 'reverse_unordered_selects'),
  );
  db.execute('PRAGMA reverse_unordered_selects = OFF');
  final unicodeFunctions = db.select(
    r'''SELECT UNISTR('A\u0042\+01F600\\C') AS decoded,
                   UNISTR_QUOTE(UNISTR('line\u000Aquote''\\')) AS quoted,
                   UNISTR_QUOTE('plain') AS plain''',
  ).single;
  assert(unicodeFunctions['decoded'] == r'AB😀\C');
  assert(unicodeFunctions['quoted'] == r"unistr('line\nquote''\\')");
  assert(unicodeFunctions['plain'] == "'plain'");
  final changeCounters = PureDatabase.memory()
    ..execute('CREATE TABLE counter_rows (id INTEGER PRIMARY KEY, value TEXT)')
    ..execute("INSERT INTO counter_rows VALUES (10, 'a'), (20, 'b')");
  var counters = changeCounters
      .select(
        'SELECT changes() AS changed, total_changes() AS total, '
        'last_insert_rowid() AS last',
      )
      .single;
  assert(counters['changed'] == 2);
  assert(counters['total'] == 2);
  assert(counters['last'] == 20);
  changeCounters.execute("UPDATE counter_rows SET value = 'A' WHERE id = 10");
  changeCounters.execute('PRAGMA user_version = 3');
  counters = changeCounters
      .select(
        'SELECT changes() AS changed, total_changes() AS total, '
        'last_insert_rowid() AS last',
      )
      .single;
  assert(counters['changed'] == 1);
  assert(counters['total'] == 3);
  assert(counters['last'] == 20);
  changeCounters.execute(
    "INSERT OR IGNORE INTO counter_rows VALUES (20, 'duplicate')",
  );
  counters = changeCounters
      .select('SELECT changes() AS changed, total_changes() AS total')
      .single;
  assert(counters['changed'] == 0);
  assert(counters['total'] == 3);
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
  assert(db.select('SELECT ?1 AS value', {'?1': 9}).single['value'] == 9);
  final mixedParameterMap = db.select(
    'SELECT ? AS first, ?3 AS third, :named AS named',
    {'1': 'one', '3': 'three', 'named': 'label'},
  ).single;
  assert(mixedParameterMap['first'] == 'one');
  assert(mixedParameterMap['third'] == 'three');
  assert(mixedParameterMap['named'] == 'label');
  try {
    db.select('SELECT ?', const {});
    assert(false, 'missing positional parameters should fail');
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
  final concatenation = db.select('''
    SELECT CONCAT('a', NULL, 'b') AS joined,
           CONCAT_WS('|', 'a', NULL, 'b') AS separated
  ''').single;
  assert(concatenation['joined'] == 'ab');
  assert(concatenation['separated'] == 'a|b');
  for (final expression in const ["CONCAT()", "CONCAT_WS('|')"]) {
    try {
      db.select('SELECT $expression');
      assert(false, '$expression must reject too few arguments');
    } on PureSqlException {
      // Expected.
    }
  }
  final mathFunctions = db.select('''
    SELECT PI() AS pi,
           CEIL(1.2) AS ceiling,
           FLOOR(1.9) AS floor,
           LOG(100) AS log10,
           LOG(2, 8) AS log_base,
           LN(EXP(1)) AS natural_log,
           POWER(2, 3) AS power,
           MOD(5, 2) AS remainder,
           MOD(-5, 2) AS negative_remainder,
           MOD(5, -2) AS negative_divisor_remainder,
           MOD(5, 0) AS zero_divisor,
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
  assert(mathFunctions['negative_remainder'] == -1.0);
  assert(mathFunctions['negative_divisor_remainder'] == 1.0);
  assert(mathFunctions['zero_divisor'] == null);
  assert(mathFunctions['sign'] == -1.0);
  assert(mathFunctions['invalid_root'] == null);
  assert(mathFunctions['numeric_text'] == 3.0);
  assert(mathFunctions['invalid_text'] == null);
  final soundex = db.select('''
    SELECT soundex('Robert') AS robert,
           SOUNDEX('Rupert') AS rupert,
           soundex('Ashcraft') AS ashcraft,
           soundex('123') AS no_letters,
           soundex(NULL) AS null_input
  ''').single;
  assert(soundex['robert'] == 'R163');
  assert(soundex['rupert'] == 'R163');
  assert(soundex['ashcraft'] == 'A226');
  assert(soundex['no_letters'] == '?000');
  assert(soundex['null_input'] == '?000');
  db.execute('CREATE TABLE 数据表 (编号 INTEGER PRIMARY KEY, 名称 TEXT)');
  db.execute("INSERT INTO 数据表 VALUES (1, '咖啡')");
  assert(db.select('SELECT 名称 FROM 数据表 WHERE 编号 = 1').single['名称'] == '咖啡');

  final compatible = PureDatabase.memory();
  compatible
    ..execute('CREATE TABLE replace_rows (id INTEGER PRIMARY KEY, value TEXT)')
    ..execute("INSERT INTO replace_rows VALUES (1, 'before')")
    ..execute("REPLACE INTO replace_rows VALUES (1, 'after')");
  assert(
    compatible
            .select('SELECT value FROM replace_rows WHERE id = 1')
            .single['value'] ==
        'after',
  );
  assert(
    compatible
            .select(
              "REPLACE INTO replace_rows VALUES (1, 'returned') RETURNING value",
            )
            .single['value'] ==
        'returned',
  );
  compatible.execute('''
    WITH replacement(value) AS (VALUES ('from cte'))
    REPLACE INTO replace_rows SELECT 1, value FROM replacement
  ''');
  assert(
    compatible
            .select('SELECT value FROM replace_rows WHERE id = 1')
            .single['value'] ==
        'from cte',
  );
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
           OCTET_LENGTH('数据库') AS bytes,
           SUBSTR('abcdef', 2, 3) AS middle,
           ABS(-3) AS magnitude,
           ROUND(2.56, 1) AS rounded,
           LOWER('ÄA') AS ascii_lower,
           UPPER('äa') AS ascii_upper,
           IFNULL(NULL, 'fallback') AS fallback,
           NULLIF(1, 1) AS null_value
  ''').single;
  assert(scalarFunctions['len'] == 3);
  assert(scalarFunctions['bytes'] == 9);
  assert(scalarFunctions['middle'] == 'bcd');
  assert(scalarFunctions['magnitude'] == 3);
  assert(scalarFunctions['rounded'] == 2.6);
  assert(scalarFunctions['ascii_lower'] == 'Äa');
  assert(scalarFunctions['ascii_upper'] == 'äA');
  assert(scalarFunctions['fallback'] == 'fallback');
  assert(scalarFunctions['null_value'] == null);
  assert(
    compatible.select('SELECT QUOTE(?) AS quoted', [
          'a\u0000b',
        ]).single['quoted'] ==
        "'a'",
  );
  assert(
    compatible
        .select('PRAGMA function_list')
        .any((row) => row['name'] == 'OCTET_LENGTH'),
  );
  final aggregateFunctions = compatible.select('''
    SELECT MIN(amount) AS minimum,
           MAX(amount) AS maximum,
           AVG(amount) AS average,
           TOTAL(amount) AS total,
           GROUP_CONCAT("group name", '-') AS names,
           STRING_AGG("group name", '-') AS string_names,
           JSON_GROUP_ARRAY(amount) AS json_values,
           JSON_GROUP_OBJECT("group name", amount) AS json_members,
           MEDIAN(amount) AS median,
           PERCENTILE(amount, 50) AS percentile,
           PERCENTILE_CONT(amount, 0.25) AS percentile_cont,
           PERCENTILE_DISC(amount, 0.25) AS percentile_disc
    FROM "group"
  ''').single;
  assert(aggregateFunctions['minimum'] == 2);
  assert(aggregateFunctions['maximum'] == 5);
  assert(aggregateFunctions['average'] == 10 / 3);
  assert(aggregateFunctions['total'] == 10.0);
  assert(aggregateFunctions['names'] == 'a-a-b');
  assert(aggregateFunctions['string_names'] == 'a-a-b');
  assert(aggregateFunctions['json_values'] == '[2,3,5]');
  assert(aggregateFunctions['json_members'] == '{"a":2,"a":3,"b":5}');
  assert(aggregateFunctions['median'] == 3.0);
  assert(aggregateFunctions['percentile'] == 3.0);
  assert(aggregateFunctions['percentile_cont'] == 2.5);
  assert(aggregateFunctions['percentile_disc'] == 2);
  final filteredAggregates = compatible.select('''
    SELECT COUNT(*) FILTER (WHERE amount >= 3) AS count,
           GROUP_CONCAT("group name", '-') FILTER (WHERE amount > 3) AS names
    FROM "group"
  ''').single;
  assert(filteredAggregates['count'] == 2);
  assert(filteredAggregates['names'] == 'b');
  final filteredWindowAggregate = compatible.select('''
    SELECT amount,
           SUM(amount) FILTER (WHERE amount >= 3) OVER (
             ORDER BY amount ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS running_sum
    FROM "group" ORDER BY amount
  ''');
  assert(
    filteredWindowAggregate.map((row) => row['running_sum']).join(',') ==
        'null,3,8',
  );
  try {
    compatible.select("SELECT LENGTH('x') FILTER (WHERE 1)");
    assert(false, 'FILTER is only valid on aggregate functions');
  } on SqliteException catch (error) {
    assert(error.message.contains('aggregate'));
  }
  assert(
    compatible
        .select('PRAGMA function_list')
        .any((row) => row['name'] == 'STRING_AGG' && row['type'] == 'w'),
  );
  final emptyJsonAggregates = compatible.select('''
    SELECT JSON_GROUP_ARRAY(amount) AS values,
           JSON_GROUP_OBJECT("group name", amount) AS members
    FROM "group" WHERE 0
  ''').single;
  assert(emptyJsonAggregates['values'] == '[]');
  assert(emptyJsonAggregates['members'] == '{}');

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
  assert(
    compatible
        .select('PRAGMA pragma_list')
        .any((row) => row['name'] == 'ignore_check_constraints'),
  );
  final runtimeFunctions = compatible.select('''
        SELECT CURRENT_DATE AS today,
               CURRENT_TIME AS clock,
               CURRENT_TIMESTAMP AS now,
               CURRENT_TIMESTAMP = CURRENT_TIMESTAMP AS stable,
               sqlite_version() AS sqlite_version,
               sqlite_source_id() AS source_id,
               sqlite_compileoption_get(0) AS option,
               sqlite_compileoption_used('THREADSAFE') AS used
      ''').single;
  assert(
    RegExp(
      r'^\d{4}-\d{2}-\d{2}$',
    ).hasMatch(runtimeFunctions['today'] as String),
  );
  assert(
    RegExp(
      r'^\d{2}:\d{2}:\d{2}$',
    ).hasMatch(runtimeFunctions['clock'] as String),
  );
  assert(
    RegExp(
      r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$',
    ).hasMatch(runtimeFunctions['now'] as String),
  );
  assert(runtimeFunctions['stable'] == true);
  assert(runtimeFunctions['sqlite_version'] == '3.51.0');
  assert(
    runtimeFunctions['source_id'] ==
        '2025-06-12 13:14:41 f0ca7bba1c5e232e5d279fad6338121ab55af0c8c68b84cdfb18ba5114dcaapl',
  );
  assert(runtimeFunctions['option'] == null && runtimeFunctions['used'] == 0);
  final sqliteLogs = <(int, String?)>[];
  final sqliteLogDb = PureDatabase.memory(
    onLog: (code, message) => sqliteLogs.add((code, message)),
  );
  assert(
    sqliteLogDb
            .select("SELECT sqlite_log(4.8, 'probe') AS result")
            .single['result'] ==
        null,
  );
  assert(sqliteLogs.length == 1 && sqliteLogs.single == (4, 'probe'));
  assert(
    sqliteLogDb
        .select('PRAGMA function_list')
        .any((row) => row['name'] == 'SQLITE_LOG' && row['builtin'] == 1),
  );
  try {
    sqliteLogDb.select("SELECT sqlite_log(4)");
    assert(false, 'sqlite_log must require exactly two arguments');
  } on PureSqlException {
    // Expected.
  }
  final runtimeFunctionNames = {
    for (final row in compatible.select('PRAGMA function_list')) row['name'],
  };
  assert(runtimeFunctionNames.contains('SQLITE_VERSION'));
  assert(runtimeFunctionNames.contains('SQLITE_SOURCE_ID'));
  assert(runtimeFunctionNames.contains('SUBTYPE'));
  final dateModifiers = compatible.select('''
    SELECT date(0, 'unixepoch') AS unix_epoch,
           date(0, 'auto') AS automatic,
           date('2024-01-31', '+1 month') AS month_ceiling,
           date('2024-01-31', '+1 month', 'floor') AS month_floor,
           date('2024-02-29', '+1 year') AS year_ceiling,
           date('2024-02-29', '+1 year', 'floor') AS year_floor,
           date('2024-01-02', 'weekday 1') AS next_monday,
           time('2000-01-01 01:02:03.456', 'subsec') AS fractional_time,
           datetime('2000-01-01 01:02:03.456', 'subsecond') AS fractional_datetime,
           unixepoch('1970-01-01 00:00:01.250', 'subsec') AS fractional_epoch,
           strftime('%s', '1970-01-01 00:00:01.250', 'subsec') AS formatted_epoch
  ''').single;
  assert(dateModifiers['unix_epoch'] == '1970-01-01');
  assert(dateModifiers['automatic'] == '-4713-11-24');
  assert(dateModifiers['month_ceiling'] == '2024-03-02');
  assert(dateModifiers['month_floor'] == '2024-02-29');
  assert(dateModifiers['year_ceiling'] == '2025-03-01');
  assert(dateModifiers['year_floor'] == '2025-02-28');
  assert(dateModifiers['next_monday'] == '2024-01-08');
  assert(dateModifiers['fractional_time'] == '01:02:03.456');
  assert(dateModifiers['fractional_datetime'] == '2000-01-01 01:02:03.456');
  assert(dateModifiers['fractional_epoch'] == 1.25);
  assert(dateModifiers['formatted_epoch'] == '1.250');
  final strftimeConversions = compatible.select('''
    SELECT strftime(
      '%F|%G|%g|%H|%I|%k|%l|%p|%P|%R|%T|%U|%u|%V|%W',
      '2021-01-01 00:05:06.125'
    ) AS conversions,
    strftime('%U|%W|%G|%g|%V', '2021-01-04') AS monday_boundary,
    strftime('%U|%W|%G|%g|%V', '2021-01-03') AS sunday_boundary,
    strftime(
      '%d|%e|%f|%F|%G|%g|%H|%I|%j|%J|%k|%l|%m|%M|%p|%P|%R|%s|%S|%T|%U|%u|%V|%w|%W|%Y|%%',
      '2021-01-01 00:05:06.125'
    ) AS all_conversions,
    strftime('%q', '2021-01-01') AS unsupported_conversion
  ''').single;
  assert(
    strftimeConversions['conversions'] ==
        '2021-01-01|2020|20|00|12| 0|12|AM|am|00:05|00:05:06|00|5|53|00',
  );
  assert(strftimeConversions['monday_boundary'] == '01|01|2021|21|01');
  assert(strftimeConversions['sunday_boundary'] == '01|01|2020|20|53');
  assert(
    strftimeConversions['all_conversions'] ==
        '01| 1|06.125|2021-01-01|2020|20|00|12|001|2459215.503543113| 0|12|01|05|AM|am|00:05|1609459506|06|00:05:06|00|5|53|5|00|2021|%',
  );
  assert(strftimeConversions['unsupported_conversion'] == null);
  final timeDifferences = compatible.select('''
        SELECT timediff('2023-03-15', '2023-02-15') AS forward_month,
               timediff('2023-02-15', '2023-03-15') AS backward_month,
               timediff('2024-02-29', '2025-02-28') AS leap_day,
               timediff('2023-03-31', '2023-02-28') AS month_end,
               timediff('2023-03-01 08:30:45.125',
                        '2023-03-01 07:00:00') AS fractional,
               timediff(NULL, '2023-01-01') AS null_input,
               timediff('not a date', '2023-01-01') AS invalid_input
      ''').single;
  assert(timeDifferences['forward_month'] == '+0000-01-00 00:00:00.000');
  assert(timeDifferences['backward_month'] == '-0000-01-00 00:00:00.000');
  assert(timeDifferences['leap_day'] == '-0000-11-28 00:00:00.000');
  assert(timeDifferences['month_end'] == '+0000-01-03 00:00:00.000');
  assert(timeDifferences['fractional'] == '+0000-00-00 01:30:45.125');
  assert(timeDifferences['null_input'] == null);
  assert(timeDifferences['invalid_input'] == null);
  assert(
    compatible
        .select('PRAGMA function_list')
        .any((row) => row['name'] == 'CURRENT_TIMESTAMP'),
  );
  final binaryEncodings = compatible.select('''
    SELECT base64(X'6869') AS base64_text,
           base85(X'6869') AS base85_text,
           hex(base64('aGk!!')) AS base64_blob,
           hex(base85(' &aM ')) AS base85_blob,
           length(base64(zeroblob(54))) AS base64_exact_line,
           length(base64(zeroblob(57))) AS base64_wrapped,
           length(base85(zeroblob(64))) AS base85_exact_line,
           length(base85(zeroblob(68))) AS base85_wrapped,
           length(base64(base64(zeroblob(57)))) AS base64_roundtrip,
           length(base85(base85(zeroblob(68)))) AS base85_roundtrip
  ''').single;
  assert(binaryEncodings['base64_text'] == 'aGk=\n');
  assert(binaryEncodings['base85_text'] == '&aM\n');
  assert(binaryEncodings['base64_blob'] == '6869');
  assert(binaryEncodings['base85_blob'] == '6869');
  assert(binaryEncodings['base64_exact_line'] == 73);
  assert(binaryEncodings['base64_wrapped'] == 78);
  assert(binaryEncodings['base85_exact_line'] == 81);
  assert(binaryEncodings['base85_wrapped'] == 87);
  assert(binaryEncodings['base64_roundtrip'] == 57);
  assert(binaryEncodings['base85_roundtrip'] == 68);
  assert(
    compatible
        .select('PRAGMA function_list')
        .where((row) => row['name'] == 'BASE64' || row['name'] == 'BASE85')
        .every((row) => row['builtin'] == 0 && row['narg'] == 1),
  );
  assert(
    compatible
        .select('PRAGMA function_list')
        .any((row) => row['name'] == 'TIMEDIFF' && row['type'] == 's'),
  );
  final pragmaNames = compatible
      .select('PRAGMA pragma_list')
      .map((row) => row['name'])
      .toSet();
  assert(
    compatible.select('PRAGMA journal_mode').single['journal_mode'] == 'memory',
  );
  compatible.execute('PRAGMA journal_mode = OFF');
  assert(
    compatible.select('PRAGMA journal_mode').single['journal_mode'] == 'off',
  );
  compatible.execute('PRAGMA journal_mode = MEMORY');
  assert(
    compatible.select('PRAGMA journal_mode').single['journal_mode'] == 'memory',
  );
  for (final pragma in const [
    'analysis_limit',
    'automatic_index',
    'cache_size',
    'count_changes',
    'default_cache_size',
    'collation_list',
    'compile_options',
    'database_list',
    'foreign_key_check',
    'foreign_key_list',
    'full_column_names',
    'function_list',
    'index_info',
    'index_list',
    'index_xinfo',
    'journal_size_limit',
    'mmap_size',
    'read_uncommitted',
    'secure_delete',
    'shrink_memory',
    'short_column_names',
    'threads',
    'temp_store',
    'wal_autocheckpoint',
  ]) {
    assert(pragmaNames.contains(pragma), 'pragma_list should include $pragma');
  }
  final columnNameDb = PureDatabase.memory()
    ..execute('CREATE TABLE pragma_column_names (value TEXT)')
    ..execute("INSERT INTO pragma_column_names VALUES ('ok')");
  assert(
    columnNameDb
            .select('PRAGMA full_column_names')
            .single['full_column_names'] ==
        0,
  );
  assert(
    columnNameDb
            .select('PRAGMA short_column_names')
            .single['short_column_names'] ==
        1,
  );
  assert(
    columnNameDb
            .select('SELECT pragma_column_names.value FROM pragma_column_names')
            .single
            .keys
            .single ==
        'value',
  );
  columnNameDb.execute('PRAGMA short_column_names = OFF');
  assert(
    columnNameDb
            .select('SELECT pragma_column_names.value FROM pragma_column_names')
            .single
            .keys
            .single ==
        'pragma_column_names.value',
  );
  columnNameDb.execute('PRAGMA full_column_names = ON');
  assert(
    columnNameDb
            .select('SELECT value FROM pragma_column_names')
            .single
            .keys
            .single ==
        'pragma_column_names.value',
  );
  assert(
    columnNameDb
            .select('SELECT source.value FROM pragma_column_names AS source')
            .single
            .keys
            .single ==
        'pragma_column_names.value',
  );
  assert(
    columnNameDb
            .select('''
              SELECT value, COUNT(*) AS row_count
              FROM pragma_column_names GROUP BY value
            ''')
            .single
            .keys
            .first ==
        'pragma_column_names.value',
  );
  assert(
    columnNameDb
            .select('SELECT rowid FROM pragma_column_names')
            .single
            .keys
            .single ==
        'pragma_column_names.rowid',
  );
  assert(
    columnNameDb
            .select('SELECT value AS explicit_name FROM pragma_column_names')
            .single
            .keys
            .single ==
        'explicit_name',
  );
  assert(
    columnNameDb
            .select('SELECT * FROM pragma_column_names')
            .single
            .keys
            .single ==
        'value',
  );
  columnNameDb
    ..execute('PRAGMA full_column_names = OFF')
    ..execute('PRAGMA short_column_names = ON');
  assert(
    compatible
            .select('PRAGMA default_cache_size')
            .single['default_cache_size'] ==
        -2000,
  );
  compatible.execute('PRAGMA default_cache_size = -64');
  assert(
    compatible
            .select('PRAGMA default_cache_size')
            .single['default_cache_size'] ==
        64,
  );
  compatible.execute('PRAGMA analysis_limit = 100');
  assert(
    compatible.select('PRAGMA analysis_limit').single['analysis_limit'] == 100,
  );
  compatible.execute('PRAGMA analysis_limit = -1');
  assert(
    compatible.select('PRAGMA analysis_limit').single['analysis_limit'] == 100,
  );
  assert(
    compatible.select('PRAGMA read_uncommitted').single['read_uncommitted'] ==
        0,
  );
  assert(
    compatible.select('PRAGMA automatic_index').single['automatic_index'] == 1,
  );
  assert(compatible.select('PRAGMA threads').single['threads'] == 0);
  compatible.execute('PRAGMA threads = 4');
  assert(compatible.select('PRAGMA threads').single['threads'] == 4);
  compatible.execute('PRAGMA threads = -1');
  assert(compatible.select('PRAGMA threads').single['threads'] == 4);
  compatible.execute('PRAGMA threads = 999999');
  assert(compatible.select('PRAGMA threads').single['threads'] == 8);
  compatible.execute('PRAGMA temp.threads = 3');
  assert(compatible.select('PRAGMA threads').single['threads'] == 3);
  compatible.execute('PRAGMA secure_delete = FAST');
  assert(
    compatible.select('PRAGMA secure_delete').single['secure_delete'] == 2,
  );
  compatible.execute('PRAGMA secure_delete = 2');
  assert(
    compatible.select('PRAGMA secure_delete').single['secure_delete'] == 1,
  );
  compatible.execute('PRAGMA temp.secure_delete = FAST');
  assert(
    compatible.select('PRAGMA temp.secure_delete').single['secure_delete'] == 2,
  );
  assert(
    compatible.select('PRAGMA secure_delete').single['secure_delete'] == 1,
  );
  assert(compatible.select('PRAGMA shrink_memory').isEmpty);
  compatible.execute('PRAGMA shrink_memory');
  assert(compatible.select('PRAGMA mmap_size').isEmpty);
  assert(compatible.select('PRAGMA temp.mmap_size').isEmpty);
  compatible.execute('PRAGMA mmap_size = 1048576');
  assert(compatible.select('PRAGMA mmap_size').isEmpty);
  compatible.execute('PRAGMA automatic_index = OFF');
  assert(
    compatible.select('PRAGMA automatic_index').single['automatic_index'] == 0,
  );
  compatible.execute('PRAGMA temp.automatic_index = ON');
  assert(
    compatible.select('PRAGMA automatic_index').single['automatic_index'] == 1,
  );
  compatible.execute('PRAGMA read_uncommitted = ON');
  assert(
    compatible.select('PRAGMA read_uncommitted').single['read_uncommitted'] ==
        1,
  );
  compatible.execute('PRAGMA read_uncommitted = OFF');
  assert(
    compatible.select('PRAGMA read_uncommitted').single['read_uncommitted'] ==
        0,
  );
  compatible.execute('PRAGMA unsupported_compat_flag = ON');
  assert(compatible.select('PRAGMA unsupported_compat_flag').isEmpty);
  compatible.execute('PRAGMA temp.unsupported_compat_flag = ON');
  assert(compatible.select('PRAGMA temp.unsupported_compat_flag').isEmpty);
  compatible.execute('PRAGMA temp.read_uncommitted = ON');
  assert(
    compatible.select('PRAGMA read_uncommitted').single['read_uncommitted'] ==
        1,
  );
  compatible.execute('PRAGMA temp.read_uncommitted = OFF');
  assert(
    compatible.select('PRAGMA read_uncommitted').single['read_uncommitted'] ==
        0,
  );

  final countChangesDb = PureDatabase.memory()
    ..execute('PRAGMA count_changes = ON')
    ..execute('CREATE TABLE count_changes_probe (id INTEGER)');
  assert(
    countChangesDb.select('PRAGMA count_changes').single['count_changes'] == 1,
  );
  final insertedCount = countChangesDb.select(
    'INSERT INTO count_changes_probe VALUES (1), (2)',
  );
  assert(insertedCount.single['rows inserted'] == 2);
  final zeroUpdateCount = countChangesDb.select(
    'UPDATE count_changes_probe SET id = 3 WHERE id = 99',
  );
  assert(zeroUpdateCount.single['rows updated'] == 0);
  final updatedCount = countChangesDb.select(
    'UPDATE count_changes_probe SET id = id + 1',
  );
  assert(updatedCount.single['rows updated'] == 2);
  final deletedCount = countChangesDb.select(
    'DELETE FROM count_changes_probe WHERE id > 0',
  );
  assert(deletedCount.single['rows deleted'] == 2);
  countChangesDb.execute('PRAGMA count_changes = OFF');
  var countChangesSelectDisabled = false;
  try {
    countChangesDb.select('DELETE FROM count_changes_probe');
  } on PureSqlException {
    countChangesSelectDisabled = true;
  }
  assert(countChangesSelectDisabled);

  final tempStoreDb = PureDatabase.memory()
    ..execute('CREATE TABLE main_temp_store_probe (value INTEGER)')
    ..execute('INSERT INTO main_temp_store_probe VALUES (7)');
  assert(tempStoreDb.select('PRAGMA temp_store').single['temp_store'] == 0);
  tempStoreDb.execute('PRAGMA temp_store = DEFAULT');
  tempStoreDb.execute('PRAGMA temp_store = MEMORY');
  assert(tempStoreDb.select('PRAGMA temp_store').single['temp_store'] == 2);
  tempStoreDb
    ..execute('CREATE TEMP TABLE temp_store_rows (value INTEGER)')
    ..execute('INSERT INTO temp_store_rows VALUES (1)')
    ..execute('CREATE TEMP INDEX temp_store_index ON temp_store_rows(value)')
    ..execute(
      'CREATE TEMP VIEW temp_store_view AS SELECT value FROM temp_store_rows',
    )
    ..execute('CREATE TEMP TABLE temp_store_log (value INTEGER)')
    ..execute('''
      CREATE TEMP TRIGGER temp_store_trigger AFTER INSERT ON temp_store_rows BEGIN
        INSERT INTO temp_store_log VALUES (NEW.value);
      END
    ''')
    ..execute('PRAGMA temp.application_id = 23')
    ..execute('PRAGMA temp.user_version = 7')
    ..execute('PRAGMA temp.schema_version = 99')
    ..execute('PRAGMA temp.temp_store = FILE');
  assert(tempStoreDb.select('PRAGMA temp_store').single['temp_store'] == 1);
  assert(
    tempStoreDb.select('PRAGMA temp.temp_store').single['temp_store'] == 1,
  );
  for (final (name, expected) in const [
    ('application_id', 0),
    ('schema_version', 0),
    ('user_version', 0),
  ]) {
    assert(tempStoreDb.select('PRAGMA temp.$name').single[name] == expected);
  }
  assert(
    tempStoreDb
            .select('SELECT value FROM main_temp_store_probe')
            .single['value'] ==
        7,
  );
  // Recreating each object also verifies that the mode change cleared it.
  tempStoreDb
    ..execute('CREATE TEMP TABLE temp_store_rows (value INTEGER)')
    ..execute('INSERT INTO temp_store_rows VALUES (2)')
    ..execute('CREATE TEMP INDEX temp_store_index ON temp_store_rows(value)')
    ..execute(
      'CREATE TEMP VIEW temp_store_view AS SELECT value FROM temp_store_rows',
    )
    ..execute('CREATE TEMP TABLE temp_store_log (value INTEGER)')
    ..execute('''
      CREATE TEMP TRIGGER temp_store_trigger AFTER INSERT ON temp_store_rows BEGIN
        INSERT INTO temp_store_log VALUES (NEW.value);
      END
    ''');
  try {
    tempStoreDb.transaction((db) => db.execute('PRAGMA temp_store = MEMORY'));
    assert(false, 'temp_store cannot change in a transaction callback');
  } on PureSqlException {
    // The in-memory transaction callback is still a SQL transaction boundary.
  }
  tempStoreDb.execute('BEGIN');
  tempStoreDb.execute('PRAGMA temp_store = FILE');
  try {
    tempStoreDb.execute('PRAGMA temp_store = MEMORY');
    assert(false, 'temp_store cannot change in a transaction');
  } on PureSqlException {
    // Changing the value would discard TEMP schema objects.
  }
  tempStoreDb.execute('ROLLBACK');
  assert(tempStoreDb.select('PRAGMA temp_store').single['temp_store'] == 1);
  assert(
    tempStoreDb.select('SELECT value FROM temp_store_view').single['value'] ==
        2,
  );
  for (final value in ['3', 'ON', 'invalid']) {
    tempStoreDb.execute('PRAGMA temp_store = $value');
    assert(tempStoreDb.select('PRAGMA temp_store').single['temp_store'] == 1);
  }
  tempStoreDb.execute('PRAGMA temp_store = DEFAULT');
  assert(tempStoreDb.select('PRAGMA temp_store').single['temp_store'] == 0);

  final tempPragmaDb = PureDatabase.memory();
  for (final (name, expected) in const [
    ('application_id', 0),
    ('busy_timeout', 0),
    ('cache_size', 2000),
    ('default_cache_size', 2000),
    ('journal_mode', 'delete'),
    ('journal_size_limit', 32768),
    ('max_page_count', 1073741823),
    ('page_size', 4096),
    ('schema_version', 0),
    ('synchronous', 0),
    ('user_version', 0),
    ('wal_autocheckpoint', 1000),
  ]) {
    assert(tempPragmaDb.select('PRAGMA temp.$name').single[name] == expected);
  }
  final mainSchemaVersion = tempPragmaDb
      .select('PRAGMA schema_version')
      .single['schema_version'];
  tempPragmaDb
    ..execute('PRAGMA temp.page_size = 8192')
    ..execute('PRAGMA temp.application_id = 23')
    ..execute('PRAGMA temp.user_version = 7')
    ..execute('PRAGMA temp.cache_size = -32')
    ..execute('PRAGMA temp.default_cache_size = -77')
    ..execute('PRAGMA temp.max_page_count = 5000')
    ..execute('PRAGMA temp.synchronous = FULL')
    ..execute('PRAGMA temp.synchronous = BOGUS')
    ..execute('PRAGMA temp.journal_mode = MEMORY')
    ..execute('PRAGMA temp.journal_size_limit = 4096')
    ..execute('PRAGMA temp.wal_autocheckpoint = 17')
    ..execute('PRAGMA temp.busy_timeout = 13');
  assert(
    tempPragmaDb
            .select('PRAGMA temp.application_id')
            .single['application_id'] ==
        23,
  );
  assert(
    tempPragmaDb.select('PRAGMA temp.user_version').single['user_version'] == 7,
  );
  assert(
    tempPragmaDb.select('PRAGMA temp.cache_size').single['cache_size'] == 77,
  );
  assert(
    tempPragmaDb
            .select('PRAGMA temp.default_cache_size')
            .single['default_cache_size'] ==
        77,
  );
  assert(
    tempPragmaDb.select('PRAGMA temp.page_size').single['page_size'] == 8192,
  );
  assert(
    tempPragmaDb
            .select('PRAGMA temp.max_page_count')
            .single['max_page_count'] ==
        5000,
  );
  assert(
    tempPragmaDb.select('PRAGMA temp.synchronous').single['synchronous'] == 0,
  );
  assert(
    tempPragmaDb.select('PRAGMA temp.journal_mode').single['journal_mode'] ==
        'memory',
  );
  assert(
    tempPragmaDb
            .select('PRAGMA temp.journal_size_limit')
            .single['journal_size_limit'] ==
        4096,
  );
  assert(
    tempPragmaDb
            .select('PRAGMA temp.wal_autocheckpoint')
            .single['wal_autocheckpoint'] ==
        17,
  );
  assert(
    tempPragmaDb
            .select('PRAGMA wal_autocheckpoint')
            .single['wal_autocheckpoint'] ==
        17,
  );
  assert(
    tempPragmaDb.select('PRAGMA busy_timeout').single['busy_timeout'] == 13,
  );
  tempPragmaDb.execute('PRAGMA busy_timeout = 0');
  assert(
    tempPragmaDb.select('PRAGMA application_id').single['application_id'] == 0,
  );
  assert(
    tempPragmaDb.select('PRAGMA user_version').single['user_version'] == 0,
  );
  assert(tempPragmaDb.select('PRAGMA cache_size').single['cache_size'] == 2000);
  assert(
    tempPragmaDb.select('PRAGMA temp.wal_checkpoint(NOOP)').single['log'] == -1,
  );
  assert(
    tempPragmaDb
            .select('PRAGMA temp.schema_version')
            .single['schema_version'] ==
        0,
  );
  tempPragmaDb.execute('CREATE TEMP TABLE temp_pragma_probe (value INTEGER)');
  assert(
    tempPragmaDb
            .select('PRAGMA temp.schema_version')
            .single['schema_version'] ==
        1,
  );
  assert(
    tempPragmaDb.select('PRAGMA schema_version').single['schema_version'] ==
        mainSchemaVersion,
  );
  assert(
    tempPragmaDb
        .select('PRAGMA temp.table_list')
        .every((row) => row['schema'] == 'temp'),
  );
  tempPragmaDb.execute('BEGIN');
  try {
    tempPragmaDb.execute('PRAGMA temp.synchronous = OFF');
    assert(false, 'TEMP synchronous cannot change inside a transaction');
  } on PureSqlException {
    // SQLite rejects changes to synchronous while a transaction is active.
  }
  tempPragmaDb.execute('ROLLBACK');
  tempPragmaDb.execute('SAVEPOINT temp_pragma_rollback');
  tempPragmaDb
    ..execute('PRAGMA temp.cache_size = 123')
    ..execute('PRAGMA temp.default_cache_size = 99')
    ..execute('PRAGMA temp.cache_size = 123')
    ..execute('PRAGMA temp.journal_mode = DELETE')
    ..execute('PRAGMA temp.user_version = 88')
    ..execute('CREATE TEMP TABLE temp_pragma_rolled_back (value INTEGER)')
    ..execute('ROLLBACK TO temp_pragma_rollback')
    ..execute('RELEASE temp_pragma_rollback');
  assert(
    tempPragmaDb.select('PRAGMA temp.user_version').single['user_version'] == 7,
  );
  assert(
    tempPragmaDb
            .select('PRAGMA temp.default_cache_size')
            .single['default_cache_size'] ==
        77,
  );
  assert(
    tempPragmaDb.select('PRAGMA temp.cache_size').single['cache_size'] == 123,
  );
  assert(
    tempPragmaDb.select('PRAGMA temp.journal_mode').single['journal_mode'] ==
        'delete',
  );
  assert(
    tempPragmaDb
            .select('PRAGMA temp.schema_version')
            .single['schema_version'] ==
        1,
  );
  assert(
    tempPragmaDb
        .select('PRAGMA temp.table_list')
        .every((row) => row['name'] != 'temp_pragma_rolled_back'),
  );
  tempPragmaDb.execute('PRAGMA temp.page_size = 4096');
  assert(
    tempPragmaDb.select('PRAGMA temp.page_size').single['page_size'] == 8192,
  );

  final tempPageSizeTransactionDb = PureDatabase.memory()
    ..execute('BEGIN')
    ..execute('PRAGMA temp.page_size = 8192')
    ..execute('ROLLBACK');
  assert(
    tempPageSizeTransactionDb
            .select('PRAGMA temp.page_size')
            .single['page_size'] ==
        8192,
  );
  final tempHeaderRollbackDb = PureDatabase.memory()
    ..execute('BEGIN')
    ..execute('PRAGMA temp.user_version = 1')
    ..execute('ROLLBACK')
    ..execute('PRAGMA temp.page_size = 8192');
  assert(
    tempHeaderRollbackDb
            .select('PRAGMA temp.user_version')
            .single['user_version'] ==
        0,
  );
  assert(
    tempHeaderRollbackDb.select('PRAGMA temp.page_size').single['page_size'] ==
        4096,
  );
  final tempDdlRollbackDb = PureDatabase.memory()
    ..execute('BEGIN')
    ..execute('CREATE TEMP TABLE rolled_back_temp_page (value INTEGER)')
    ..execute('ROLLBACK')
    ..execute('PRAGMA temp.page_size = 8192');
  assert(
    tempDdlRollbackDb.select('PRAGMA temp.page_size').single['page_size'] ==
        4096,
  );

  final scopedTempPragmaDb = PureDatabase.memory()
    ..execute('CREATE TABLE parent (id INTEGER PRIMARY KEY)')
    ..execute(
      'CREATE TABLE child (id INTEGER REFERENCES parent(id), main_marker TEXT)',
    )
    ..execute('INSERT INTO child(id) VALUES (99)')
    ..execute('CREATE TEMP TABLE parent (id INTEGER PRIMARY KEY)')
    ..execute('CREATE TEMP TABLE temp_child (id INTEGER REFERENCES parent(id))')
    ..execute('INSERT INTO temp_child VALUES (99)')
    ..execute('CREATE INDEX same_index_name ON child(main_marker)')
    ..execute('CREATE TEMP INDEX same_index_name ON temp_child(id)');
  assert(
    scopedTempPragmaDb.select('PRAGMA foreign_key_check').single['table'] ==
        'child',
  );
  assert(
    scopedTempPragmaDb
            .select('PRAGMA temp.foreign_key_check')
            .single['table'] ==
        'temp_child',
  );
  assert(
    scopedTempPragmaDb
            .select('PRAGMA main.index_info(same_index_name)')
            .single['name'] ==
        'main_marker',
  );
  assert(
    scopedTempPragmaDb
            .select('PRAGMA temp.index_info(same_index_name)')
            .single['name'] ==
        'id',
  );
  assert(
    scopedTempPragmaDb
            .select('PRAGMA temp.integrity_check')
            .single['integrity_check'] ==
        'ok',
  );

  assert(compatible.select('PRAGMA compile_options').isEmpty);
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
  final compatibleDatabaseList = compatible.select('PRAGMA database_list');
  assert(compatibleDatabaseList.first['name'] == 'main');
  assert(compatibleDatabaseList.any((row) => row['name'] == 'temp'));
  final functionList = compatible.select('PRAGMA function_list');
  assert(functionList.isNotEmpty);
  assert(functionList.any((row) => row['name'] == 'LOG'));
  assert(functionList.every((row) => row.containsKey('narg')));
  assert(functionList.every((row) => row.containsKey('flags')));
  assert(
    functionList.any(
      (row) =>
          row['name'] == 'ABS' && row['narg'] == 1 && row['flags'] == 0x200800,
    ),
  );
  assert(
    functionList.any(
      (row) =>
          row['name'] == 'COUNT' &&
          row['narg'] == 1 &&
          row['flags'] == 0x200000,
    ),
  );
  assert(
    functionList.any(
      (row) => row['name'] == 'COUNT' && row['narg'] == 1 && row['type'] == 'w',
    ),
  );
  assert(
    functionList.any(
      (row) => row['name'] == 'MAX' && row['narg'] == -3 && row['type'] == 's',
    ),
  );
  assert(
    functionList.any(
      (row) => row['name'] == 'MAX' && row['narg'] == 1 && row['type'] == 'w',
    ),
  );
  assert(
    functionList
            .where((row) => row['name'] == 'SUBSTR')
            .map((row) => row['narg'])
            .toSet()
            .join(',') ==
        '2,3',
  );
  assert(
    functionList.any((row) => row['name'] == 'REPLACE' && row['narg'] == 3),
  );
  assert(
    functionList.any(
      (row) => row['name'] == 'SQLITE_OFFSET' && row['narg'] == 1,
    ),
  );
  compatible.execute('CREATE TABLE offset_memory (value TEXT)');
  compatible.execute("INSERT INTO offset_memory VALUES ('in memory')");
  assert(
    compatible
            .select('SELECT sqlite_offset(value) AS offset FROM offset_memory')
            .single['offset'] ==
        null,
  );
  compatible.execute('CREATE TEMP TABLE offset_temporary (value TEXT)');
  compatible.execute("INSERT INTO offset_temporary VALUES ('temporary')");
  assert(
    compatible
            .select(
              'SELECT sqlite_offset(value) AS offset FROM offset_temporary',
            )
            .single['offset'] ==
        null,
  );
  assert(
    compatible
            .select('SELECT sqlite_offset(1) AS literal_offset')
            .single['literal_offset'] ==
        null,
  );
  try {
    compatible.select('SELECT sqlite_offset()');
    assert(false, 'sqlite_offset must require one argument');
  } on PureSqlException catch (error) {
    assert(error.message.contains('one argument'));
  }
  assert(
    functionList
            .where((row) => row['name'] == 'LOAD_EXTENSION')
            .map((row) => row['narg'])
            .toSet()
            .join(',') ==
        '1,2',
  );
  assert(
    functionList.any(
      (row) =>
          row['name'] == 'SOUNDEX' && row['builtin'] == 1 && row['type'] == 's',
    ),
  );
  for (final function in const [
    'ROW_NUMBER',
    'RANK',
    'DENSE_RANK',
    'PERCENT_RANK',
    'CUME_DIST',
    'NTILE',
    'LAG',
    'LEAD',
    'FIRST_VALUE',
    'LAST_VALUE',
    'NTH_VALUE',
  ]) {
    assert(
      functionList.any((row) => row['name'] == function && row['type'] == 'w'),
      'function_list should include built-in window function $function',
    );
  }
  for (final expression in const [
    "load_extension('untrusted.so')",
    "load_extension('untrusted.so', 'entry')",
  ]) {
    try {
      compatible.select('SELECT $expression');
      assert(false, 'native extension loading must stay disabled');
    } on PureSqlException catch (error) {
      assert(error.message == 'not authorized');
    }
  }
  try {
    compatible.select('SELECT load_extension()');
    assert(false, 'load_extension must require a filename');
  } on PureSqlException catch (error) {
    assert(error.message.contains('one or two arguments'));
  }
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
  compatible.execute('''
    CREATE TABLE multiple_upserts (
      id INTEGER PRIMARY KEY,
      email TEXT UNIQUE,
      handle TEXT UNIQUE,
      value TEXT
    )
  ''');
  compatible.execute(
    "INSERT INTO multiple_upserts VALUES (1, 'a@example', 'first', 'old')",
  );
  compatible.execute('''
    INSERT INTO multiple_upserts VALUES (2, 'b@example', 'first', 'updated')
    ON CONFLICT(id) DO NOTHING
    ON CONFLICT(handle) DO UPDATE SET value = excluded.value
  ''');
  assert(
    compatible.select('SELECT value FROM multiple_upserts').single['value'] ==
        'updated',
  );
  compatible.execute('''
    INSERT INTO multiple_upserts VALUES (3, 'a@example', 'first', 'ignored')
    ON CONFLICT(email) DO NOTHING
    ON CONFLICT(handle) DO UPDATE SET value = excluded.value
  ''');
  assert(
    compatible.select('SELECT value FROM multiple_upserts').single['value'] ==
        'updated',
  );
  compatible.execute(
    'CREATE TABLE upsert_collation (value TEXT COLLATE NOCASE UNIQUE)',
  );
  compatible.execute("INSERT INTO upsert_collation VALUES ('first')");
  compatible.execute('''
    INSERT INTO upsert_collation VALUES ('FIRST')
    ON CONFLICT(value COLLATE NOCASE DESC) DO UPDATE SET value = excluded.value
  ''');
  assert(
    compatible.select('SELECT value FROM upsert_collation').single['value'] ==
        'FIRST',
  );
  try {
    compatible.execute('''
      INSERT INTO upsert_collation VALUES ('first')
      ON CONFLICT(value COLLATE BINARY) DO NOTHING
    ''');
    assert(false, 'mismatched UPSERT target collation should fail');
  } on PureSqlException {
    // Expected; the target collation does not match the unique key.
  }
  final analyzeDb = PureDatabase.memory();
  analyzeDb.execute('CREATE TABLE analyze_rows (a, b)');
  analyzeDb.execute('CREATE INDEX analyze_rows_ab ON analyze_rows (a, b)');
  analyzeDb.execute('INSERT INTO analyze_rows VALUES (1, 2), (1, 3), (2, 4)');
  analyzeDb.execute('ANALYZE main.analyze_rows');
  assert(
    analyzeDb.select('SELECT stat FROM sqlite_stat1').single['stat'] == '3 2 1',
  );
  analyzeDb.execute('ANALYZE');
  assert(
    analyzeDb.select('SELECT stat FROM sqlite_stat1').single['stat'] == '3 2 1',
  );
  analyzeDb.execute('INSERT INTO analyze_rows VALUES (2, 5)');
  analyzeDb.execute('ANALYZE analyze_rows_ab');
  assert(
    analyzeDb.select('SELECT stat FROM sqlite_stat1').single['stat'] == '4 2 1',
  );
  final limitedAnalyzeDb = PureDatabase.memory();
  limitedAnalyzeDb.execute('CREATE TABLE limited_rows (a, b)');
  limitedAnalyzeDb.execute(
    'CREATE INDEX limited_rows_ab ON limited_rows(a, b)',
  );
  limitedAnalyzeDb.execute(
    'INSERT INTO limited_rows VALUES ${List.filled(12, '(?, ?)').join(', ')}',
    [
      for (var value = 0; value < 12; value++) ...[value ~/ 3, value],
    ],
  );
  limitedAnalyzeDb.execute('PRAGMA analysis_limit = 2');
  limitedAnalyzeDb.execute('ANALYZE limited_rows_ab');
  final approximateStat = limitedAnalyzeDb
      .select('SELECT stat FROM sqlite_stat1')
      .single['stat'];
  assert(approximateStat == '12 2 1');
  limitedAnalyzeDb.execute('PRAGMA analysis_limit = 0');
  limitedAnalyzeDb.execute('ANALYZE limited_rows_ab');
  assert(
    limitedAnalyzeDb.select('SELECT stat FROM sqlite_stat1').single['stat'] ==
        '12 3 1',
  );
  analyzeDb.execute('CREATE TABLE analyze_plain (value)');
  analyzeDb.execute('INSERT INTO analyze_plain VALUES (1), (2)');
  analyzeDb.execute('ANALYZE analyze_plain');
  assert(
    analyzeDb
            .select(
              'SELECT stat FROM sqlite_stat1 WHERE tbl = \'analyze_plain\'',
            )
            .single['stat'] ==
        '2',
  );
  analyzeDb.execute('CREATE TEMP TABLE analyze_temp (value)');
  analyzeDb.execute(
    'CREATE TEMP INDEX analyze_temp_idx ON analyze_temp (value)',
  );
  analyzeDb.execute('INSERT INTO analyze_temp VALUES (1), (1)');
  analyzeDb.execute('ANALYZE temp.analyze_temp');
  assert(
    analyzeDb
            .select(
              'SELECT stat FROM sqlite_stat1 WHERE idx = \'analyze_temp_idx\'',
            )
            .single['stat'] ==
        '2 2',
  );
  analyzeDb.execute('ANALYZE temp');
  assert(
    analyzeDb
            .select(
              'SELECT stat FROM sqlite_stat1 WHERE idx = \'analyze_temp_idx\'',
            )
            .single['stat'] ==
        '2 2',
  );
  final reindexDb = PureDatabase.memory()
    ..execute('CREATE TABLE reindex_rows (value TEXT)')
    ..execute(
      'CREATE INDEX reindex_rows_value ON reindex_rows(value COLLATE NOCASE)',
    )
    ..execute("INSERT INTO reindex_rows VALUES ('b'), ('A')")
    ..execute('CREATE TEMP TABLE reindex_temp (value TEXT)')
    ..execute('CREATE TEMP INDEX reindex_temp_value ON reindex_temp(value)');
  reindexDb.execute('REINDEX');
  reindexDb.execute('REINDEX NOCASE');
  reindexDb.execute('REINDEX reindex_rows');
  reindexDb.execute('REINDEX main.reindex_rows_value');
  reindexDb.execute('REINDEX temp.reindex_temp_value');
  try {
    reindexDb.execute('REINDEX missing_reindex_target');
    assert(false, 'REINDEX must reject an unknown target');
  } on PureSqlException {
    // Expected: the target is neither a collation, table, nor index.
  }
  try {
    analyzeDb.execute('ANALYZE attached.analyze_rows');
    assert(false, 'ANALYZE should reject unattached schemas');
  } on PureSqlException catch (error) {
    assert(error.message == 'no such database: attached');
  }
  analyzeDb.execute('VACUUM');
  analyzeDb.execute('BEGIN');
  try {
    analyzeDb.execute('VACUUM');
    assert(false, 'VACUUM must fail inside a transaction');
  } on PureSqlException catch (error) {
    assert(error.message == 'cannot VACUUM from within a transaction');
  }
  analyzeDb.execute('ROLLBACK');
  compatible.execute('''
    CREATE TABLE partial_upsert (
      id INTEGER PRIMARY KEY,
      email TEXT,
      active INTEGER,
      value TEXT
    )
  ''');
  compatible.execute('''
    CREATE UNIQUE INDEX partial_upsert_active
    ON partial_upsert(email) WHERE active = 1
  ''');
  compatible.execute(
    "INSERT INTO partial_upsert VALUES (1, 'same@example', 1, 'old')",
  );
  compatible.execute('''
    INSERT INTO partial_upsert VALUES (2, 'same@example', 1, 'updated')
    ON CONFLICT(email) WHERE active = 1
    DO UPDATE SET value = excluded.value
  ''');
  compatible.execute('''
    INSERT INTO partial_upsert VALUES (3, 'same@example', 0, 'inactive')
    ON CONFLICT(email) WHERE active = 1
    DO UPDATE SET value = excluded.value
  ''');
  assert(
    compatible.select('SELECT COUNT(*) AS n FROM partial_upsert').single['n'] ==
        2,
  );
  try {
    compatible.execute('''
      INSERT INTO partial_upsert VALUES (4, 'same@example', 1, 'bad')
      ON CONFLICT(email) WHERE active = 0 DO NOTHING
    ''');
    assert(false, 'mismatched UPSERT target predicates should fail');
  } on PureSqlException {
    // Expected; the predicate does not identify the partial unique index.
  }
  final expressionUpsert = PureDatabase.memory();
  expressionUpsert.execute(
    'CREATE TABLE expression_upsert (id INTEGER PRIMARY KEY, email TEXT, value TEXT)',
  );
  expressionUpsert.execute(
    'CREATE UNIQUE INDEX expression_upsert_email ON expression_upsert (lower(email))',
  );
  expressionUpsert.execute(
    "INSERT INTO expression_upsert VALUES (1, 'Ada@Example.test', 'old')",
  );
  expressionUpsert.execute('''
    INSERT INTO expression_upsert VALUES (2, 'ADA@EXAMPLE.TEST', 'new')
    ON CONFLICT(lower(email)) DO UPDATE SET value = excluded.value
  ''');
  final expressionUpsertResult = expressionUpsert
      .select('SELECT id, value FROM expression_upsert')
      .single;
  assert(
    expressionUpsertResult['id'] == 1 &&
        expressionUpsertResult['value'] == 'new',
  );
  assert(
    expressionUpsert
            .select('PRAGMA index_info(expression_upsert_email)')
            .single['cid'] ==
        -2,
  );
  expressionUpsert.execute('''
    CREATE TABLE expression_partial (id INTEGER PRIMARY KEY, email TEXT, active INTEGER, value TEXT)
  ''');
  expressionUpsert.execute('''
    CREATE UNIQUE INDEX expression_partial_email
    ON expression_partial (lower(email)) WHERE active = 1
  ''');
  expressionUpsert.execute(
    "INSERT INTO expression_partial VALUES (1, 'same@example.test', 1, 'old')",
  );
  expressionUpsert.execute('''
    INSERT INTO expression_partial VALUES (2, 'SAME@EXAMPLE.TEST', 1, 'new')
    ON CONFLICT(lower(email)) WHERE active = 1
    DO UPDATE SET value = excluded.value
  ''');
  expressionUpsert.execute('''
    INSERT INTO expression_partial VALUES (3, 'same@example.test', 0, 'inactive')
    ON CONFLICT(lower(email)) WHERE active = 1 DO NOTHING
  ''');
  assert(
    expressionUpsert
            .select('SELECT COUNT(*) AS n FROM expression_partial')
            .single['n'] ==
        2,
  );
  try {
    expressionUpsert.execute('''
      INSERT INTO expression_upsert VALUES (3, 'other@example.test', 'bad')
      ON CONFLICT(trim(email)) DO NOTHING
    ''');
    assert(false, 'non-matching expression UPSERT targets must fail');
  } on PureSqlException catch (error) {
    assert(error.message == 'ON CONFLICT target does not match a UNIQUE key');
  }
  expressionUpsert.execute(
    'CREATE TABLE collated_upsert (email TEXT, value TEXT)',
  );
  expressionUpsert.execute(
    'CREATE UNIQUE INDEX collated_upsert_email ON collated_upsert (email COLLATE NOCASE)',
  );
  expressionUpsert.execute("INSERT INTO collated_upsert VALUES ('A', 'old')");
  expressionUpsert.execute('''
    INSERT INTO collated_upsert VALUES ('a', 'new')
    ON CONFLICT(email COLLATE NOCASE) DO UPDATE SET value = excluded.value
  ''');
  assert(
    expressionUpsert
            .select('SELECT value FROM collated_upsert')
            .single['value'] ==
        'new',
  );
  try {
    expressionUpsert.execute(
      'CREATE INDEX expression_nondeterministic ON expression_upsert (random())',
    );
    assert(false, 'non-deterministic index expressions must fail');
  } on PureSqlException catch (error) {
    assert(error.message.startsWith('non-deterministic expression in index'));
  }
  compatible.execute('''
    CREATE TABLE returning_rows (
      id INTEGER PRIMARY KEY,
      value TEXT UNIQUE,
      note TEXT
    )
  ''');
  final insertedRows = compatible.select('''
    INSERT INTO returning_rows (value, note)
    VALUES ('first', 'initial'), ('second', 'initial')
    RETURNING id, value AS label
  ''');
  assert(insertedRows.length == 2 && insertedRows.first['id'] == 1);
  final upsertedRows = compatible.select('''
    INSERT INTO returning_rows VALUES (3, 'first', 'updated')
    ON CONFLICT(value) DO UPDATE SET note = excluded.note
    RETURNING id, note
  ''');
  assert(
    upsertedRows.single['id'] == 1 && upsertedRows.single['note'] == 'updated',
  );
  final updatedRows = compatible.select('''
    UPDATE returning_rows SET note = 'changed' WHERE id = 2
    RETURNING *
  ''');
  assert(updatedRows.single['value'] == 'second');
  final deletedRows = compatible.select('''
    DELETE FROM returning_rows WHERE id = 2 RETURNING value
  ''');
  assert(deletedRows.single['value'] == 'second');
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
  final valuesRows = compatible.select('VALUES (?, ?), (?, ?)', [
    2,
    'b',
    1,
    'a',
  ]);
  assert(valuesRows.length == 2);
  assert(
    valuesRows.first['column1'] == 2 && valuesRows.first['column2'] == 'b',
  );
  assert(valuesRows.last['column1'] == 1 && valuesRows.last['column2'] == 'a');
  final valuesCompound = compatible.select('''
    VALUES (1), (1)
    UNION ALL SELECT 2
    ORDER BY column1 DESC
    LIMIT 2
  ''');
  assert(valuesCompound.map((row) => row['column1']).join(',') == '2,1');
  final valuesCte = compatible.select('''
    WITH values_cte AS (VALUES (3), (4))
    SELECT column1 FROM values_cte ORDER BY column1
  ''');
  assert(valuesCte.map((row) => row['column1']).join(',') == '3,4');
  try {
    compatible.select('VALUES (1), (2, 3)');
    assert(false, 'VALUES rows with different column counts should fail');
  } on PureSqlException {
    // Expected.
  }
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
    SELECT names.name AS name, wanted.value AS wanted_value
    FROM (SELECT DISTINCT "group name" AS name FROM "group") AS names
    LEFT JOIN (SELECT value FROM wanted) AS wanted ON names.name = wanted.value
    ORDER BY names.name
  ''');
  assert(joinedDerivedTables.length == 2);
  assert(joinedDerivedTables.first['wanted_value'] == 'a');
  assert(joinedDerivedTables.last['wanted_value'] == null);
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
  compatible.execute('''
    CREATE TABLE row_values (
      id INTEGER PRIMARY KEY,
      a INTEGER,
      b INTEGER,
      value TEXT,
      UNIQUE (a, b)
    )
  ''');
  compatible.execute('''
    INSERT INTO row_values VALUES
      (1, 1, 2, 'first'),
      (2, 1, 3, 'second'),
      (3, 2, 0, 'third'),
      (4, NULL, 2, 'null')
  ''');
  compatible.execute('CREATE TABLE empty_row_source (a INTEGER, b INTEGER)');
  assert(
    compatible
            .select('SELECT (1, 2) IN (SELECT * FROM empty_row_source)')
            .single
            .values
            .single ==
        false,
  );
  assert(
    compatible
            .select('SELECT id FROM row_values WHERE (a, b) = (1, 2)')
            .single['id'] ==
        1,
  );
  assert(
    compatible
            .select('SELECT id FROM row_values WHERE (a, b) < (2, 0)')
            .map((row) => row['id'])
            .join(',') ==
        '1,2',
  );
  assert(
    compatible
            .select('''
              SELECT id FROM row_values
              WHERE (a, b) IN ((1, 2), (2, 0))
              ORDER BY id
            ''')
            .map((row) => row['id'])
            .join(',') ==
        '1,3',
  );
  assert(
    compatible
            .select('''
              SELECT id FROM row_values
              WHERE (a, b) IN (
                SELECT a, b FROM row_values WHERE id IN (1, 3)
              )
              ORDER BY id
            ''')
            .map((row) => row['id'])
            .join(',') ==
        '1,3',
  );
  final rowNullSemantics = compatible.select('''
        SELECT (1, NULL) = (2, NULL) AS definite_false,
               (1, NULL) = (1, NULL) AS unknown_equal,
               (1, NULL) IS (1, NULL) AS null_safe_equal,
               (1, 2) < (1, NULL) AS unknown_order
      ''').single;
  assert(rowNullSemantics['definite_false'] == false);
  assert(rowNullSemantics['unknown_equal'] == null);
  assert(rowNullSemantics['null_safe_equal'] == true);
  assert(rowNullSemantics['unknown_order'] == null);
  try {
    compatible.select(
      'SELECT (1, 2) IN (SELECT a FROM row_values WHERE id = 0)',
    );
    assert(false, 'row-value arity should be checked for empty subqueries');
  } on PureSqlException {
    // Expected.
  }
  try {
    compatible.select('SELECT (1, 2)');
    assert(false, 'a row value cannot be projected as a scalar');
  } on PureSqlException {
    // Expected.
  }
  compatible.execute('UPDATE row_values SET (a, b) = (b, a) WHERE id = 1');
  final swappedRow = compatible
      .select('SELECT a, b FROM row_values WHERE id = 1')
      .single;
  assert(swappedRow['a'] == 2 && swappedRow['b'] == 1);
  compatible.execute('''
    INSERT INTO row_values VALUES (5, 2, 1, 'upsert')
    ON CONFLICT(a, b) DO UPDATE SET (a, b) = (excluded.b, excluded.a)
  ''');
  final rowUpsert = compatible
      .select('SELECT a, b, value FROM row_values WHERE id = 1')
      .single;
  assert(rowUpsert['a'] == 1 && rowUpsert['b'] == 2);
  assert(rowUpsert['value'] == 'first');
  compatible.execute('''
    CREATE TABLE auto_ids (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      value TEXT UNIQUE
    )
  ''');
  compatible.execute("INSERT INTO auto_ids (value) VALUES ('one'), ('two')");
  compatible.execute('DELETE FROM auto_ids WHERE id = 2');
  compatible.execute("INSERT INTO auto_ids (value) VALUES ('three')");
  assert(
    compatible
            .select("SELECT id FROM auto_ids WHERE value = 'three'")
            .single['id'] ==
        3,
  );
  compatible.execute("INSERT INTO auto_ids VALUES (10, 'ten')");
  compatible.execute('DELETE FROM auto_ids WHERE id = 10');
  compatible.execute("INSERT INTO auto_ids (value) VALUES ('eleven')");
  assert(
    compatible
            .select("SELECT id FROM auto_ids WHERE value = 'eleven'")
            .single['id'] ==
        11,
  );
  compatible.execute("UPDATE auto_ids SET id = 50 WHERE value = 'eleven'");
  compatible.execute('DELETE FROM auto_ids WHERE id = 50');
  compatible.execute("INSERT INTO auto_ids (value) VALUES ('twelve')");
  assert(
    compatible
            .select("SELECT id FROM auto_ids WHERE value = 'twelve'")
            .single['id'] ==
        12,
  );
  compatible.execute(
    "UPDATE sqlite_sequence SET seq = 20 WHERE name = 'auto_ids'",
  );
  compatible.execute("INSERT INTO auto_ids (value) VALUES ('twenty-one')");
  assert(
    compatible
            .select("SELECT id FROM auto_ids WHERE value = 'twenty-one'")
            .single['id'] ==
        21,
  );
  compatible.execute('ALTER TABLE auto_ids RENAME TO renamed_auto_ids');
  assert(
    compatible
            .select(
              "SELECT name FROM sqlite_sequence WHERE name = 'renamed_auto_ids'",
            )
            .length ==
        1,
  );
  compatible.execute('DROP TABLE renamed_auto_ids');
  assert(
    compatible
        .select(
          "SELECT name FROM sqlite_sequence WHERE name = 'renamed_auto_ids'",
        )
        .isEmpty,
  );
  for (final invalidAutoIncrement in [
    'CREATE TABLE bad_auto (id INT PRIMARY KEY AUTOINCREMENT)',
    'CREATE TABLE bad_auto (id INTEGER AUTOINCREMENT)',
  ]) {
    try {
      compatible.execute(invalidAutoIncrement);
      assert(false, 'invalid AUTOINCREMENT declaration should fail');
    } on PureSqlException {
      // Expected; AUTOINCREMENT requires an INTEGER PRIMARY KEY.
    }
  }
  final customFunctions = PureDatabase.memory()
    ..registerFunction(
      'plus_one',
      1,
      (arguments) => (arguments.single as int) + 1,
    )
    ..registerFunction(
      'sum_values',
      -1,
      (arguments) =>
          arguments.fold<num>(0, (sum, value) => sum + (value as num)),
    )
    ..registerFunction(
      'is_even',
      1,
      (arguments) => (arguments.single as int).isEven,
    )
    ..registerAggregateFunction(
      'custom_sum',
      1,
      (rows) => rows.fold<num>(0, (sum, row) => sum + (row.single as num)),
    )
    ..registerAggregateFunction('custom_count', 1, (rows) => rows.length)
    ..registerAggregateFunction('custom_arg_rows', -1, (rows) => rows.length)
    ..registerWindowFunction(
      'frame_probe',
      1,
      (partition, currentRow, frame) =>
          '${partition.length}:$currentRow:${frame.length}',
    );
  final customResults = customFunctions.select('''
        SELECT plus_one(41) AS next,
               sum_values(1, 2, 3) AS total,
               is_even(42) AS even
      ''').single;
  assert(customResults['next'] == 42);
  assert(customResults['total'] == 6);
  assert(customResults['even'] == 1);
  assert(
    customFunctions
        .select('PRAGMA function_list')
        .any((row) => row['name'] == 'PLUS_ONE' && row['builtin'] == 0),
  );
  assert(
    customFunctions
        .select('PRAGMA function_list')
        .any(
          (row) =>
              row['name'] == 'CUSTOM_SUM' &&
              row['builtin'] == 0 &&
              row['type'] == 'a' &&
              row['narg'] == 1,
        ),
  );
  assert(
    customFunctions
        .select('PRAGMA function_list')
        .any(
          (row) =>
              row['name'] == 'FRAME_PROBE' &&
              row['builtin'] == 0 &&
              row['type'] == 'w' &&
              row['narg'] == 1,
        ),
  );
  customFunctions
    ..execute('CREATE TABLE aggregate_rows (bucket TEXT, value INTEGER)')
    ..execute(
      "INSERT INTO aggregate_rows VALUES ('a', 1), ('a', 2), ('a', 2), ('b', 5)",
    );
  final aggregateRows = customFunctions.select('''
    SELECT bucket,
           custom_sum(value) AS total,
           custom_count(DISTINCT value) AS distinct_count
    FROM aggregate_rows
    GROUP BY bucket
    ORDER BY bucket
  ''');
  assert(aggregateRows[0]['total'] == 5);
  assert(aggregateRows[0]['distinct_count'] == 2);
  assert(aggregateRows[1]['total'] == 5);
  assert(
    customFunctions.select('''
              SELECT custom_sum(value) FILTER (WHERE value > 2) AS total
              FROM aggregate_rows
            ''').single['total'] ==
        5,
  );
  assert(
    customFunctions
            .select(
              'SELECT custom_arg_rows(value, bucket) AS count FROM aggregate_rows',
            )
            .single['count'] ==
        4,
  );
  assert(
    customFunctions.select('''
              SELECT custom_count(value) AS count
              FROM aggregate_rows
              WHERE value < 0
            ''').single['count'] ==
        0,
  );
  final customWindow = customFunctions.select('''
    SELECT value,
           custom_sum(value) OVER (
             ORDER BY value ROWS UNBOUNDED PRECEDING
           ) AS running
    FROM aggregate_rows
    ORDER BY value
  ''');
  assert(customWindow.map((row) => row['running']).join(',') == '1,3,5,10');
  final filteredCustomWindow = customFunctions.select('''
    SELECT value,
           custom_sum(value) FILTER (WHERE value > 1) OVER (
             ORDER BY value ROWS UNBOUNDED PRECEDING
           ) AS running
    FROM aggregate_rows
    ORDER BY value
  ''');
  assert(
    filteredCustomWindow.map((row) => row['running']).join(',') == '0,2,4,9',
  );
  final customWindowRows = customFunctions.select('''
    SELECT value,
           frame_probe(value) OVER (
             ORDER BY value ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
           ) AS frame_info
    FROM aggregate_rows
    ORDER BY value
  ''');
  assert(
    customWindowRows.map((row) => row['frame_info']).join(',') ==
        '4:0:1,4:1:2,4:2:2,4:3:2',
  );
  final excludedCustomWindow = customFunctions.select('''
    SELECT frame_probe(value) OVER (
             ORDER BY value ROWS BETWEEN UNBOUNDED PRECEDING
             AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW
           ) AS frame_info
    FROM aggregate_rows
    ORDER BY value
  ''');
  assert(
    excludedCustomWindow.map((row) => row['frame_info']).join(',') ==
        '4:0:3,4:1:3,4:2:3,4:3:3',
  );
  final customGroupedWindow = customFunctions.select('''
    SELECT bucket, custom_sum(COUNT(*)) OVER () AS total
    FROM aggregate_rows
    GROUP BY bucket
    ORDER BY bucket
  ''');
  assert(customGroupedWindow.map((row) => row['total']).join(',') == '4,4');
  customFunctions.unregisterAggregateFunction('custom_count');
  customFunctions.unregisterWindowFunction('frame_probe');
  try {
    customFunctions.select(
      'SELECT frame_probe(value) OVER () FROM aggregate_rows',
    );
    assert(false, 'unregistered window functions should stop resolving');
  } on PureSqlException {
    // Expected.
  }
  try {
    customFunctions.select('SELECT custom_count(value) FROM aggregate_rows');
    assert(false, 'unregistered aggregate functions should stop resolving');
  } on PureSqlException {
    // Expected.
  }
  customFunctions.execute(
    'CREATE TABLE function_checks (value INTEGER CHECK (plus_one(value) > 0))',
  );
  customFunctions
    ..registerFunction('like', 2, (arguments) => arguments[0] == 'x%')
    ..registerFunction('glob', 2, (arguments) => arguments[0] == 'x*')
    ..registerFunction(
      'match',
      2,
      (arguments) => arguments[0] == 'target' && arguments[1] == 'source',
    );
  final overriddenPatterns = customFunctions.select('''
    SELECT 'anything' LIKE 'x%' AS like_operator,
           LIKE('x%', 'anything') AS like_function,
           'anything' GLOB 'x*' AS glob_operator,
           'source' MATCH 'target' AS match_operator,
           'source' NOT MATCH 'target' AS not_match_operator
  ''').single;
  assert(overriddenPatterns['like_operator'] == 1);
  assert(overriddenPatterns['like_function'] == 1);
  assert(overriddenPatterns['glob_operator'] == 1);
  assert(overriddenPatterns['match_operator'] == 1);
  assert(overriddenPatterns['not_match_operator'] == 0);
  customFunctions.execute('INSERT INTO function_checks VALUES (1)');
  try {
    customFunctions.execute('INSERT INTO function_checks VALUES (-2)');
    assert(false, 'registered functions should run in CHECK constraints');
  } on PureSqlException {
    // Expected; plus_one(-2) violates the CHECK.
  }
  customFunctions.unregisterFunction('plus_one', argumentCount: 1);
  try {
    customFunctions.select('SELECT plus_one(1)');
    assert(false, 'unregistered SQL functions should no longer resolve');
  } on PureSqlException {
    // Expected.
  }
  try {
    compatible.select('SELECT 1 IN (SELECT value, value FROM wanted)');
    assert(false, 'IN subquery must return exactly one column');
  } on PureSqlException {
    // Expected.
  }

  final rowIdDml = PureDatabase.memory()
    ..execute('CREATE TABLE rowid_aliases (id INTEGER PRIMARY KEY, value)')
    ..execute('CREATE TABLE implicit_rowid (value)')
    ..execute("INSERT INTO implicit_rowid(rowid, value) VALUES (42, 'before')");
  final implicitUpdate = rowIdDml.select(
    "UPDATE implicit_rowid SET _rowid_ = rowid - 35 "
    'WHERE oid = 42 RETURNING rowid',
  );
  assert(implicitUpdate.single['rowid'] == 7);
  final primaryKeyInsert = rowIdDml.select(
    "INSERT INTO rowid_aliases(rowid, value) VALUES (21, 'before') "
    'RETURNING id, rowid',
  );
  assert(primaryKeyInsert.single['id'] == 21);
  assert(primaryKeyInsert.single['rowid'] == 21);
  final primaryKeyUpdate = rowIdDml.select(
    'UPDATE rowid_aliases SET oid = 22 WHERE id = 21 RETURNING id, rowid',
  );
  assert(primaryKeyUpdate.single['id'] == 22);
  assert(primaryKeyUpdate.single['rowid'] == 22);
  rowIdDml
    ..execute('CREATE TABLE rowid_audit (old_id, new_id)')
    ..execute('''
      CREATE TRIGGER implicit_rowid_audit AFTER UPDATE ON implicit_rowid
      BEGIN
        INSERT INTO rowid_audit VALUES (OLD.rowid, NEW.oid);
      END
    ''')
    ..execute('UPDATE implicit_rowid SET rowid = rowid + 1 WHERE rowid = 7');
  final rowIdAudit = rowIdDml
      .select('SELECT old_id, new_id FROM rowid_audit')
      .single;
  assert(rowIdAudit['old_id'] == 7);
  assert(rowIdAudit['new_id'] == 8);
}
