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
  assert(database.select('PRAGMA mmap_size').single['mmap_size'] == 0);
  database.execute('PRAGMA mmap_size = 1048576');
  assert(database.select('PRAGMA mmap_size').single['mmap_size'] == 0);
  final secureDeletePath = '${directory.path}/secure-delete.sqlite';
  final secureDeleteDb = PureDatabase.open(secureDeletePath)
    ..execute('CREATE TABLE secure_delete_probe (payload TEXT)')
    ..execute('PRAGMA secure_delete = ON');
  const forensicMarker = 'sensitive-payload-forensic-marker';
  secureDeleteDb.execute('INSERT INTO secure_delete_probe VALUES (?)', [
    'a' * 8000 + forensicMarker + 'z' * 8000,
  ]);
  secureDeleteDb.execute('DELETE FROM secure_delete_probe');
  assert(
    (secureDeleteDb.select('PRAGMA freelist_count').single['freelist_count']
            as int) >
        0,
    'rewriting a row must return its overflow pages to the freelist',
  );
  secureDeleteDb.close();
  final securelyDeletedBytes = File(
    secureDeletePath,
  ).readAsBytesSync().toList();
  assert(
    !String.fromCharCodes(securelyDeletedBytes).contains(forensicMarker),
    'secure_delete=ON must scrub deleted overflow payload bytes',
  );

  final fastSecureDeletePath = '${directory.path}/secure-delete-fast.sqlite';
  final fastSecureDeleteDb = PureDatabase.open(fastSecureDeletePath)
    ..execute('CREATE TABLE secure_delete_probe (payload TEXT)')
    ..execute('PRAGMA secure_delete = FAST')
    ..execute('INSERT INTO secure_delete_probe VALUES (?)', [
      'a' * 8000 + forensicMarker + 'z' * 8000,
    ])
    ..execute('DELETE FROM secure_delete_probe');
  assert(
    fastSecureDeleteDb.select('PRAGMA secure_delete').single['secure_delete'] ==
        2,
  );
  fastSecureDeleteDb.close();
  assert(
    String.fromCharCodes(
      File(fastSecureDeletePath).readAsBytesSync(),
    ).contains(forensicMarker),
    'secure_delete=FAST may retain deleted bytes on freelist pages',
  );

  final attachedPath = '${directory.path}/attached.sqlite';
  final attachedFixture = PureDatabase.open(attachedPath);
  attachedFixture.execute(
    'CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)',
  );
  attachedFixture.execute("INSERT INTO items VALUES (1, 'attached')");
  attachedFixture.execute('CREATE INDEX items_value_idx ON items(value)');
  attachedFixture.execute('CREATE VIEW item_view AS SELECT value FROM items');
  attachedFixture.execute('CREATE TABLE copied_items (id INTEGER, value TEXT)');
  attachedFixture.execute('PRAGMA user_version = 23');
  attachedFixture.close();
  final secondAttachedPath = '${directory.path}/attached-second.sqlite';
  final secondAttachedFixture = PureDatabase.open(secondAttachedPath);
  secondAttachedFixture.execute('CREATE TABLE items (id INTEGER, value TEXT)');
  secondAttachedFixture.execute("INSERT INTO items VALUES (1, 'second')");
  secondAttachedFixture.close();

  final attachmentDb = PureDatabase.open(
    '${directory.path}/attachment-main.sqlite',
  );
  attachmentDb.execute('PRAGMA secure_delete = FAST');
  attachmentDb.execute('ATTACH DATABASE ? AS archive', [attachedPath]);
  assert(
    attachmentDb
            .select('PRAGMA archive.secure_delete')
            .single['secure_delete'] ==
        2,
    'newly attached schemas inherit main secure_delete mode',
  );
  attachmentDb.execute('PRAGMA secure_delete = ON');
  assert(
    attachmentDb
            .select('PRAGMA archive.secure_delete')
            .single['secure_delete'] ==
        1,
    'unqualified secure_delete changes attached schemas too',
  );
  final databaseList = attachmentDb.select('PRAGMA database_list');
  assert(databaseList.length == 2);
  assert(databaseList[0]['name'] == 'main');
  assert(databaseList[1]['name'] == 'archive');
  assert(databaseList[1]['seq'] == 2);
  assert(databaseList[1]['file'] == attachedPath);
  assert(
    attachmentDb.select('SELECT value FROM archive.items').single['value'] ==
        'attached',
  );
  assert(
    attachmentDb
            .select(
              "SELECT name FROM pragma_table_info('items', 'archive') ORDER BY cid",
            )
            .map((row) => row['name'])
            .join(',') ==
        'id,value',
  );
  assert(
    attachmentDb
            .select(
              "SELECT name FROM archive.pragma_table_info('items') ORDER BY cid",
            )
            .map((row) => row['name'])
            .join(',') ==
        'id,value',
  );
  assert(
    attachmentDb
            .select("SELECT schema FROM pragma_table_list('items')")
            .single['schema'] ==
        'archive',
  );
  assert(
    attachmentDb
            .select("PRAGMA archive.table_list('items')")
            .single['schema'] ==
        'archive',
  );
  attachmentDb.execute('CREATE TEMP TABLE pragma_temp_probe (value TEXT)');
  assert(
    attachmentDb
            .select(
              "SELECT name FROM pragma_table_info('pragma_temp_probe', 'temp')",
            )
            .single['name'] ==
        'value',
  );
  attachmentDb.execute(
    'ATTACH DATABASE \'file:$secondAttachedPath?mode=ro\' AS readonly_archive',
  );
  assert(
    attachmentDb
            .select('SELECT value FROM readonly_archive.items')
            .single['value'] ==
        'second',
  );
  attachmentDb.execute('BEGIN');
  assert(
    attachmentDb
            .select('SELECT value FROM readonly_archive.items')
            .single['value'] ==
        'second',
  );
  attachmentDb.execute('ROLLBACK');
  var attachedReadOnlyWriteRejected = false;
  try {
    attachmentDb.execute("UPDATE readonly_archive.items SET value = 'blocked'");
  } on PureSqlException {
    attachedReadOnlyWriteRejected = true;
  }
  assert(attachedReadOnlyWriteRejected);
  attachmentDb.execute('DETACH readonly_archive');
  assert(
    attachmentDb.select('SELECT value FROM items').single['value'] ==
        'attached',
  );
  final threePartColumn = attachmentDb.select(
    'SELECT archive.items.value AS value FROM archive.items',
  );
  assert(threePartColumn.single['value'] == 'attached');
  assert(
    attachmentDb
            .select('SELECT value FROM archive.item_view')
            .single['value'] ==
        'attached',
  );
  assert(
    attachmentDb
            .select('PRAGMA archive.table_info(items)')
            .map((row) => row['name'])
            .join(',') ==
        'id,value',
  );
  assert(
    attachmentDb.select('PRAGMA archive.user_version').single['user_version'] ==
        23,
  );
  assert(
    attachmentDb.select('PRAGMA archive.database_list').length ==
        attachmentDb.select('PRAGMA database_list').length,
  );
  attachmentDb.execute('PRAGMA archive.foreign_keys = ON');
  assert(
    attachmentDb.select('PRAGMA foreign_keys').single['foreign_keys'] == 1,
  );
  attachmentDb.execute('PRAGMA archive.synchronous = NORMAL');
  assert(
    attachmentDb.select('PRAGMA archive.synchronous').single['synchronous'] ==
        1,
  );
  assert(
    attachmentDb.select('PRAGMA main.synchronous').single['synchronous'] == 2,
  );
  attachmentDb.execute('PRAGMA archive.journal_size_limit = 128');
  assert(
    attachmentDb
            .select('PRAGMA archive.journal_size_limit')
            .single['journal_size_limit'] ==
        128,
  );
  assert(
    attachmentDb
            .select('PRAGMA main.journal_size_limit')
            .single['journal_size_limit'] ==
        -1,
  );
  attachmentDb.execute(
    "UPDATE archive.items SET value = 'attached-updated' WHERE id = 1",
  );
  assert(
    attachmentDb
            .select('PRAGMA archive.journal_size_limit')
            .single['journal_size_limit'] ==
        128,
  );
  attachmentDb.execute("UPDATE archive.items SET value = 'attached'");
  attachmentDb.execute('PRAGMA foreign_keys = OFF');
  attachmentDb.execute('PRAGMA archive.user_version = 24');
  assert(
    attachmentDb.select('PRAGMA archive.user_version').single['user_version'] ==
        24,
  );
  attachmentDb.execute('PRAGMA archive.user_version = 23');
  attachmentDb.execute('CREATE TEMP TABLE temp_probe (value TEXT)');
  var databaseListWithTemp = attachmentDb.select('PRAGMA database_list');
  assert(databaseListWithTemp.length == 3);
  assert(databaseListWithTemp[1]['name'] == 'temp');
  assert(databaseListWithTemp[1]['seq'] == 1);
  attachmentDb.execute('DROP TABLE temp_probe');
  databaseListWithTemp = attachmentDb.select('PRAGMA database_list');
  assert(databaseListWithTemp.any((row) => row['name'] == 'temp'));
  attachmentDb.execute('CREATE TEMP TABLE temp.shadow (id INTEGER)');
  attachmentDb.execute('CREATE TABLE main.shadow (id INTEGER)');
  attachmentDb.execute('ALTER TABLE main.shadow ADD COLUMN main_only INTEGER');
  assert(attachmentDb.select('PRAGMA main.table_info(shadow)').length == 2);
  attachmentDb.execute('DROP TABLE main.shadow');
  assert(attachmentDb.select('PRAGMA temp.table_info(shadow)').length == 1);
  attachmentDb.execute('DROP TABLE temp.shadow');
  attachmentDb.execute('ATTACH DATABASE ? AS archive2', [secondAttachedPath]);
  final listWithTwoAttachments = attachmentDb.select('PRAGMA database_list');
  assert(listWithTwoAttachments.last['name'] == 'archive2');
  assert(listWithTwoAttachments.last['seq'] == 3);
  assert(
    attachmentDb.select('SELECT value FROM items').single['value'] ==
        'attached',
  );
  attachmentDb.execute('CREATE TABLE local_items (id INTEGER PRIMARY KEY)');
  attachmentDb.execute('INSERT INTO local_items VALUES (1)');
  attachmentDb.execute('CREATE TABLE source_items (id INTEGER, value TEXT)');
  attachmentDb.execute("INSERT INTO source_items VALUES (3, 'from-main')");
  attachmentDb.execute('''
    CREATE TABLE archive.attachment_ddl (id INTEGER PRIMARY KEY, value TEXT)
  ''');
  attachmentDb.execute("INSERT INTO archive.attachment_ddl VALUES (1, 'ddl')");
  attachmentDb.execute('''
    ALTER TABLE archive.attachment_ddl ADD COLUMN note TEXT DEFAULT 'added'
  ''');
  attachmentDb.execute('''
    ALTER TABLE archive.attachment_ddl RENAME COLUMN note TO note2
  ''');
  attachmentDb.execute('''
    CREATE INDEX archive.attachment_ddl_idx ON attachment_ddl(value)
  ''');
  attachmentDb.execute('''
    CREATE VIEW archive.attachment_ddl_view AS
    SELECT value, note2 FROM attachment_ddl
  ''');
  assert(
    attachmentDb
            .select('SELECT note2 FROM archive.attachment_ddl_view')
            .single['note2'] ==
        'added',
  );
  attachmentDb.execute('''
    CREATE TABLE archive.attachment_audit (value TEXT)
  ''');
  attachmentDb.execute('''
    CREATE TRIGGER archive.attachment_audit_trigger
    AFTER UPDATE ON attachment_ddl
    BEGIN INSERT INTO attachment_audit VALUES (NEW.value); END
  ''');
  attachmentDb.execute(
    "UPDATE archive.attachment_ddl SET value = 'triggered' WHERE id = 1",
  );
  assert(
    attachmentDb
            .select('SELECT value FROM archive.attachment_audit')
            .single['value'] ==
        'triggered',
  );
  attachmentDb.execute('ANALYZE archive.attachment_ddl');
  attachmentDb.execute('REINDEX archive.items_value_idx');
  attachmentDb.execute('REINDEX archive.items');
  attachmentDb.execute('REINDEX');
  assert(
    attachmentDb
            .select('PRAGMA archive.integrity_check')
            .single['integrity_check'] ==
        'ok',
  );
  attachmentDb.execute('VACUUM archive');
  final archiveVacuumPath = '${directory.path}/attached-vacuum.sqlite';
  attachmentDb.execute('VACUUM archive INTO ?', [archiveVacuumPath]);
  final vacuumedAttachment = PureDatabase.open(archiveVacuumPath);
  assert(
    vacuumedAttachment
            .select('SELECT note2 FROM attachment_ddl')
            .single['note2'] ==
        'added',
  );
  vacuumedAttachment.close();
  attachmentDb.execute('DROP TRIGGER archive.attachment_audit_trigger');
  attachmentDb.execute('DROP TABLE archive.attachment_audit');
  attachmentDb.execute('''
    CREATE TRIGGER archive.rollback_trigger
    BEFORE UPDATE ON items WHEN NEW.value = 'rollback'
    BEGIN SELECT RAISE(ROLLBACK, 'attached rollback'); END
  ''');
  attachmentDb.execute('DROP VIEW archive.attachment_ddl_view');
  attachmentDb.execute('DROP INDEX archive.attachment_ddl_idx');
  attachmentDb.execute('ALTER TABLE archive.attachment_ddl DROP COLUMN note2');
  attachmentDb.execute('DROP TABLE archive.attachment_ddl');
  attachmentDb.execute('''
    CREATE TABLE archive.attachment_ctas AS
    SELECT id, value FROM main.source_items
  ''');
  assert(
    attachmentDb
            .select('SELECT value FROM archive.attachment_ctas')
            .single['value'] ==
        'from-main',
  );
  attachmentDb.execute('DROP TABLE archive.attachment_ctas');
  final attachedJoinRows = attachmentDb.select('''
    SELECT item.value AS value
    FROM main.local_items AS local
    JOIN archive.items AS item ON local.id = item.id
  ''');
  assert(attachedJoinRows.single['value'] == 'attached');
  final changesBeforeAttachedWrites =
      attachmentDb.select('SELECT total_changes() AS count').single['count']
          as int;
  attachmentDb.registerFunction(
    'attach_prefix',
    1,
    (arguments) => 'prefix-${arguments.single}',
  );
  assert(
    attachmentDb.execute(
          'UPDATE archive.items SET value = attach_prefix(value) WHERE id = 1',
        ) ==
        1,
  );
  assert(attachmentDb.select('SELECT changes() AS count').single['count'] == 1);
  final insertedAttachedRow = attachmentDb
      .select(
        "INSERT INTO archive.items VALUES (2, 'inserted') RETURNING id, value",
      )
      .single;
  assert(insertedAttachedRow['id'] == 2);
  assert(insertedAttachedRow['value'] == 'inserted');
  assert(
    attachmentDb.select('SELECT last_insert_rowid() AS id').single['id'] == 2,
  );
  assert(
    attachmentDb.execute("UPDATE items SET value = 'updated' WHERE id = 2") ==
        1,
  );
  final deletedAttachedRow = attachmentDb
      .select('DELETE FROM archive.items WHERE id = 2 RETURNING id')
      .single;
  assert(deletedAttachedRow['id'] == 2);
  assert(
    attachmentDb.select('SELECT total_changes() AS count').single['count'] ==
        changesBeforeAttachedWrites + 4,
  );
  final copiedAttachedRow = attachmentDb.select('''
        INSERT INTO archive.copied_items
        SELECT id, value FROM main.source_items
        RETURNING id, value
      ''').single;
  assert(copiedAttachedRow['id'] == 3);
  assert(copiedAttachedRow['value'] == 'from-main');
  assert(
    attachmentDb.select('SELECT total_changes() AS count').single['count'] ==
        changesBeforeAttachedWrites + 5,
  );
  assert(
    attachmentDb.select('SELECT value FROM archive.items').single['value'] ==
        'prefix-attached',
  );
  final attachedWriter = PureDatabase.open(attachedPath);
  attachedWriter.execute("UPDATE items SET value = 'updated' WHERE id = 1");
  attachedWriter.close();
  assert(
    attachmentDb.select('SELECT value FROM archive.items').single['value'] ==
        'updated',
  );
  assert(
    attachmentDb.select('SELECT value FROM items').single['value'] == 'updated',
  );
  attachmentDb.execute('CREATE TABLE items (id INTEGER, value TEXT)');
  attachmentDb.execute("INSERT INTO items VALUES (1, 'main')");
  assert(
    attachmentDb.select('SELECT value FROM items').single['value'] == 'main',
  );
  attachmentDb.execute('DROP TABLE items');
  assert(
    attachmentDb.select('SELECT value FROM items').single['value'] == 'updated',
  );
  var duplicateAttachmentRejected = false;
  try {
    attachmentDb.execute('ATTACH DATABASE ? AS archive', [attachedPath]);
  } on PureSqlException {
    duplicateAttachmentRejected = true;
  }
  assert(duplicateAttachmentRejected);
  var reservedSchemaRejected = false;
  try {
    attachmentDb.execute('ATTACH DATABASE ? AS main', [attachedPath]);
  } on PureSqlException {
    reservedSchemaRejected = true;
  }
  assert(reservedSchemaRejected);
  attachmentDb.execute('BEGIN');
  attachmentDb.execute('PRAGMA archive.user_version = 77');
  attachmentDb.execute('''
    CREATE TABLE archive.rollback_probe (id INTEGER)
  ''');
  attachmentDb.execute("UPDATE archive.items SET value = 'transactional'");
  attachmentDb.execute('SAVEPOINT attached_sp');
  attachmentDb.execute("UPDATE archive.items SET value = 'savepoint'");
  attachmentDb.execute('ROLLBACK TO attached_sp');
  assert(
    attachmentDb.select('SELECT value FROM archive.items').single['value'] ==
        'transactional',
  );
  attachmentDb.execute('RELEASE attached_sp');
  var detachUsedDatabaseRejected = false;
  try {
    attachmentDb.execute('DETACH archive');
  } on PureSqlException {
    detachUsedDatabaseRejected = true;
  }
  assert(detachUsedDatabaseRejected);
  attachmentDb.execute("ATTACH DATABASE ':memory:' AS pending");
  attachmentDb.execute('ROLLBACK');
  var attachedDdlRollbackWorked = false;
  try {
    attachmentDb.select('SELECT * FROM archive.rollback_probe');
  } on PureSqlException {
    attachedDdlRollbackWorked = true;
  }
  assert(attachedDdlRollbackWorked);
  assert(
    attachmentDb
        .select('PRAGMA database_list')
        .any((row) => row['name'] == 'pending'),
  );
  assert(
    attachmentDb.select('SELECT value FROM archive.items').single['value'] ==
        'updated',
  );
  assert(
    attachmentDb.select('PRAGMA archive.user_version').single['user_version'] ==
        23,
  );
  attachmentDb.execute('DETACH pending');
  attachmentDb.execute('BEGIN');
  attachmentDb.execute("UPDATE archive.items SET value = 'committed'");
  attachmentDb.execute('COMMIT');
  assert(
    attachmentDb.select('SELECT value FROM archive.items').single['value'] ==
        'committed',
  );
  attachmentDb.execute("UPDATE archive.items SET value = 'updated'");
  attachmentDb.execute('CREATE TABLE archive.persisted_ddl (id INTEGER)');
  attachmentDb.execute('ROLLBACK');
  attachmentDb.execute('BEGIN');
  attachmentDb.execute('UPDATE local_items SET id = 2 WHERE id = 1');
  var attachedTriggerRolledBack = false;
  try {
    attachmentDb.execute("UPDATE archive.items SET value = 'rollback'");
  } on PureSqlException catch (error) {
    attachedTriggerRolledBack = error.message == 'attached rollback';
  }
  assert(attachedTriggerRolledBack);
  assert(attachmentDb.select('SELECT id FROM local_items').single['id'] == 1);
  assert(
    attachmentDb.select('SELECT value FROM archive.items').single['value'] ==
        'updated',
  );
  attachmentDb.execute('DROP TRIGGER archive.rollback_trigger');
  attachmentDb.execute('DETACH archive2');
  attachmentDb.execute("ATTACH DATABASE ':memory:' AS scratch");
  assert(attachmentDb.select('PRAGMA database_list').length == 4);
  attachmentDb.execute('DETACH DATABASE scratch');
  attachmentDb.execute("ATTACH DATABASE '' AS ephemeral");
  assert(
    attachmentDb
            .select('PRAGMA database_list')
            .singleWhere((row) => row['name'] == 'ephemeral')['file'] ==
        '',
  );
  attachmentDb.execute('DETACH ephemeral');
  attachmentDb.execute('DETACH archive');
  final listAfterDetach = attachmentDb.select('PRAGMA database_list');
  assert(listAfterDetach.length == 2);
  assert(listAfterDetach.last['name'] == 'temp');
  var detachedReadRejected = false;
  try {
    attachmentDb.select('SELECT value FROM archive.items');
  } on PureSqlException {
    detachedReadRejected = true;
  }
  assert(detachedReadRejected);
  final reopenedAttached = PureDatabase.open(attachedPath);
  assert(
    reopenedAttached.select('PRAGMA table_info(persisted_ddl)').length == 1,
  );
  reopenedAttached.execute('DROP TABLE persisted_ddl');
  reopenedAttached.close();
  attachmentDb.close();

  final parallelOpen = PureDatabase.open(path);
  assert(
    parallelOpen.select('PRAGMA user_version').single['user_version'] == 0,
  );
  parallelOpen.close();
  assert(database.select('PRAGMA user_version').single['user_version'] == 0);

  final cacheSizePath = '${directory.path}/cache_size.sqlite';
  final cacheSizeDb = PureDatabase.open(cacheSizePath);
  assert(cacheSizeDb.select('PRAGMA cache_size').single['cache_size'] == 2000);
  cacheSizeDb.execute('PRAGMA cache_size = -256');
  cacheSizeDb.execute('BEGIN');
  cacheSizeDb.execute('PRAGMA cache_size = 32');
  cacheSizeDb.execute('ROLLBACK');
  assert(cacheSizeDb.select('PRAGMA cache_size').single['cache_size'] == 32);
  final parallelCacheSizeDb = PureDatabase.open(cacheSizePath);
  assert(
    parallelCacheSizeDb.select('PRAGMA cache_size').single['cache_size'] ==
        2000,
  );
  parallelCacheSizeDb.close();
  cacheSizeDb.close();
  final reopenedCacheSizeDb = PureDatabase.open(cacheSizePath);
  assert(
    reopenedCacheSizeDb.select('PRAGMA cache_size').single['cache_size'] ==
        2000,
  );
  reopenedCacheSizeDb.close();

  final defaultCacheSizePath = '${directory.path}/default_cache_size.sqlite';
  final defaultCacheSizeDb = PureDatabase.open(defaultCacheSizePath);
  assert(
    defaultCacheSizeDb
            .select('PRAGMA default_cache_size')
            .single['default_cache_size'] ==
        -2000,
  );
  defaultCacheSizeDb.execute('PRAGMA default_cache_size = -256');
  assert(
    defaultCacheSizeDb
            .select('PRAGMA default_cache_size')
            .single['default_cache_size'] ==
        256,
  );
  defaultCacheSizeDb.close();
  final nativeDefaultCacheSize = Process.runSync('sqlite3', [
    defaultCacheSizePath,
    'PRAGMA default_cache_size;',
  ]);
  assert(nativeDefaultCacheSize.exitCode == 0, nativeDefaultCacheSize.stderr);
  assert(nativeDefaultCacheSize.stdout.trim() == '256');
  final reopenedDefaultCacheSizeDb = PureDatabase.open(defaultCacheSizePath);
  assert(
    reopenedDefaultCacheSizeDb
            .select('PRAGMA default_cache_size')
            .single['default_cache_size'] ==
        256,
  );
  assert(
    reopenedDefaultCacheSizeDb
            .select('PRAGMA cache_size')
            .single['cache_size'] ==
        256,
  );
  reopenedDefaultCacheSizeDb.execute('PRAGMA default_cache_size = 0');
  assert(
    reopenedDefaultCacheSizeDb
            .select('PRAGMA default_cache_size')
            .single['default_cache_size'] ==
        -2000,
  );
  assert(
    reopenedDefaultCacheSizeDb
            .select('PRAGMA cache_size')
            .single['cache_size'] ==
        0,
  );
  reopenedDefaultCacheSizeDb.close();

  final sqliteOffsetPath = '${directory.path}/sqlite_offset.sqlite';
  final sqliteOffsetDb = PureDatabase.open(sqliteOffsetPath);
  sqliteOffsetDb.execute(
    'CREATE TABLE offset_rows (id INTEGER PRIMARY KEY, payload TEXT)',
  );
  try {
    sqliteOffsetDb.execute(
      'CREATE INDEX offset_expression_idx ON offset_rows(sqlite_offset(payload))',
    );
    assert(false, 'sqlite_offset must not be accepted in an index');
  } on PureSqlException catch (error) {
    assert(error.message.contains('non-deterministic'));
  }
  sqliteOffsetDb.execute(
    "INSERT INTO offset_rows VALUES (1, 'first'), (2, 'a longer second row')",
  );
  final offsets = sqliteOffsetDb.select('''
    SELECT id,
           sqlite_offset(payload) AS payload_offset,
           sqlite_offset(o.payload) AS aliased_offset,
           sqlite_offset(payload || '') AS computed_offset
    FROM offset_rows AS o ORDER BY id
  ''');
  assert(offsets.length == 2);
  assert(offsets.every((row) => row['payload_offset'] is int));
  assert(offsets.every((row) => (row['payload_offset'] as int) > 0));
  assert(
    offsets.every((row) => row['payload_offset'] == row['aliased_offset']),
  );
  assert(offsets.every((row) => row['computed_offset'] == null));
  assert(offsets[0]['payload_offset'] != offsets[1]['payload_offset']);
  sqliteOffsetDb.execute(
    'CREATE TABLE offset_extra (id INTEGER PRIMARY KEY, detail TEXT)',
  );
  sqliteOffsetDb.execute("INSERT INTO offset_extra VALUES (1, 'extra')");
  final joinedOffset = sqliteOffsetDb.select('''
    SELECT sqlite_offset(a.payload) AS left_offset,
           sqlite_offset(b.detail) AS right_offset,
           sqlite_offset(id) AS using_offset
    FROM offset_rows AS a JOIN offset_extra AS b USING (id)
    WHERE a.id = 1
  ''').single;
  assert(joinedOffset['left_offset'] is int);
  assert(joinedOffset['right_offset'] is int);
  assert(joinedOffset['left_offset'] != joinedOffset['right_offset']);
  assert(joinedOffset['using_offset'] == joinedOffset['left_offset']);
  sqliteOffsetDb.execute('BEGIN');
  sqliteOffsetDb.execute("UPDATE offset_rows SET payload = 'rolled back'");
  sqliteOffsetDb.execute('ROLLBACK');
  assert(
    sqliteOffsetDb
        .select('SELECT sqlite_offset(payload) AS offset FROM offset_rows')
        .every((row) => row['offset'] is int),
  );
  assert(
    sqliteOffsetDb
        .select('''
              SELECT sqlite_offset(payload) AS offset
              FROM (SELECT payload FROM offset_rows) AS derived
            ''')
        .every((row) => row['offset'] == null),
  );
  sqliteOffsetDb.execute(
    "UPDATE offset_rows SET payload = 'updated payload with new size' WHERE id = 1",
  );
  final updatedOffset = sqliteOffsetDb.select('''
        SELECT sqlite_offset(payload) AS offset FROM offset_rows WHERE id = 1
      ''').single['offset'];
  assert(updatedOffset is int && updatedOffset > 0);
  sqliteOffsetDb.execute('VACUUM');
  final currentOffsets = sqliteOffsetDb.select('''
    SELECT payload, sqlite_offset(payload) AS offset
    FROM offset_rows ORDER BY id
  ''');
  sqliteOffsetDb.close();
  final offsetPager = SqlitePagerSync.open(sqliteOffsetPath);
  try {
    final schemaRows = SqliteTableBtree.readTree(
      offsetPager,
      1,
      pageStart: 100,
    );
    final rootPage =
        schemaRows
                .singleWhere(
                  (row) =>
                      row.values[0] == 'table' &&
                      row.values[1] == 'offset_rows',
                )
                .values[3]
            as int;
    final recordOffsets = {
      for (final row in SqliteTableBtree.readTree(offsetPager, rootPage))
        row.values[1] as String: row.recordOffset,
    };
    assert(
      currentOffsets.every(
        (row) => row['offset'] == recordOffsets[row['payload']],
      ),
    );
  } finally {
    offsetPager.close();
  }
  final reopenedOffsetDb = PureDatabase.open(sqliteOffsetPath);
  assert(
    reopenedOffsetDb.select('''
              SELECT sqlite_offset(payload) AS offset FROM offset_rows WHERE id = 1
            ''').single['offset']
        is int,
  );
  reopenedOffsetDb.close();

  for (final mode in const [
    'DELETE',
    'TRUNCATE',
    'PERSIST',
    'MEMORY',
    'OFF',
    'WAL',
  ]) {
    final savepointPath = '${directory.path}/savepoint-$mode.sqlite';
    final savepointDb = PureDatabase.open(savepointPath);
    savepointDb.execute('PRAGMA journal_mode = $mode');
    assert(
      savepointDb.select('PRAGMA journal_mode').single['journal_mode'] ==
          mode.toLowerCase(),
    );
    savepointDb.execute('CREATE TABLE savepoint_rows (id INTEGER)');
    savepointDb.execute('INSERT INTO savepoint_rows VALUES (1)');
    savepointDb.execute('SAVEPOINT outer');
    savepointDb.execute('INSERT INTO savepoint_rows VALUES (2)');
    savepointDb.execute('SAVEPOINT inner');
    savepointDb.execute('INSERT INTO savepoint_rows VALUES (3)');
    savepointDb.execute('ROLLBACK TO inner');
    savepointDb.execute('INSERT INTO savepoint_rows VALUES (4)');
    savepointDb.execute('RELEASE outer');
    savepointDb.execute('SAVEPOINT discard');
    savepointDb.execute('INSERT INTO savepoint_rows VALUES (5)');
    savepointDb.execute('ROLLBACK TO discard');
    savepointDb.execute('RELEASE discard');
    assert(
      savepointDb
              .select('SELECT id FROM savepoint_rows ORDER BY id')
              .map((row) => row['id'])
              .join(',') ==
          '1,2,4',
    );
    savepointDb
      ..execute('BEGIN')
      ..execute('INSERT INTO savepoint_rows VALUES (5)')
      ..execute('ROLLBACK');
    assert(
      savepointDb
              .select('SELECT id FROM savepoint_rows ORDER BY id')
              .map((row) => row['id'])
              .join(',') ==
          '1,2,4',
    );
    savepointDb.close();
    final journalFile = File('$savepointPath-journal');
    if (mode == 'DELETE' || mode == 'MEMORY' || mode == 'OFF') {
      assert(!journalFile.existsSync());
    } else if (mode == 'TRUNCATE') {
      assert(journalFile.existsSync() && journalFile.lengthSync() == 0);
    } else if (mode == 'PERSIST') {
      final journal = journalFile.readAsBytesSync();
      assert(
        journal.length > 512 && journal.take(8).every((byte) => byte == 0),
      );
    }
    final reopenedSavepointDb = PureDatabase.open(savepointPath);
    assert(
      reopenedSavepointDb
              .select('PRAGMA journal_mode')
              .single['journal_mode'] ==
          (mode == 'WAL' ? 'wal' : 'delete'),
    );
    assert(
      reopenedSavepointDb
              .select('SELECT id FROM savepoint_rows ORDER BY id')
              .map((row) => row['id'])
              .join(',') ==
          '1,2,4',
    );
    reopenedSavepointDb.close();
  }

  final journalModeTransitionPath =
      '${directory.path}/journal-mode-transition.sqlite';
  final journalModeTransitionDb = PureDatabase.open(journalModeTransitionPath);
  final transitionJournal = File('$journalModeTransitionPath-journal');
  journalModeTransitionDb
    ..execute('PRAGMA journal_mode = PERSIST')
    ..execute('CREATE TABLE journal_mode_rows (value INTEGER)')
    ..execute('INSERT INTO journal_mode_rows VALUES (1)');
  assert(transitionJournal.existsSync());
  journalModeTransitionDb.execute('PRAGMA journal_mode = OFF');
  assert(!transitionJournal.existsSync());
  journalModeTransitionDb
    ..execute('PRAGMA journal_mode = PERSIST')
    ..execute('INSERT INTO journal_mode_rows VALUES (2)');
  assert(transitionJournal.existsSync());
  journalModeTransitionDb.execute('PRAGMA journal_mode = MEMORY');
  assert(!transitionJournal.existsSync());
  journalModeTransitionDb
    ..execute('PRAGMA journal_mode = PERSIST')
    ..execute('INSERT INTO journal_mode_rows VALUES (3)');
  assert(transitionJournal.existsSync());
  journalModeTransitionDb.execute('PRAGMA journal_mode = DELETE');
  assert(!transitionJournal.existsSync());
  journalModeTransitionDb.close();

  final journalLimitPath = '${directory.path}/rollback-journal-limit.sqlite';
  final journalLimitDb = PureDatabase.open(journalLimitPath);
  final limitedJournal = File('$journalLimitPath-journal');
  journalLimitDb
    ..execute('PRAGMA journal_mode = PERSIST')
    ..execute('PRAGMA journal_size_limit = 64')
    ..execute('CREATE TABLE journal_limit_rows (payload TEXT)')
    ..execute('INSERT INTO journal_limit_rows VALUES (?)', ['x' * 8192]);
  assert(limitedJournal.existsSync() && limitedJournal.lengthSync() <= 64);
  assert(limitedJournal.readAsBytesSync().take(8).every((byte) => byte == 0));
  journalLimitDb
    ..execute('PRAGMA journal_size_limit = 0')
    ..execute('INSERT INTO journal_limit_rows VALUES (\'zero\')');
  assert(limitedJournal.lengthSync() == 0);
  journalLimitDb
    ..execute('PRAGMA journal_size_limit = -1')
    ..execute('INSERT INTO journal_limit_rows VALUES (\'unlimited\')');
  assert(limitedJournal.lengthSync() > 64);
  journalLimitDb.close();

  for (final journalMode in ['DELETE', 'WAL']) {
    for (final (synchronous, expected) in const [
      ('OFF', 0),
      ('NORMAL', 1),
      ('FULL', 2),
      ('EXTRA', 3),
    ]) {
      final synchronousPath =
          '${directory.path}/synchronous-${journalMode.toLowerCase()}-${synchronous.toLowerCase()}.sqlite';
      final synchronousDb = PureDatabase.open(synchronousPath);
      synchronousDb.execute('PRAGMA journal_mode = $journalMode');
      synchronousDb.execute('CREATE TABLE synchronous_rows (value TEXT)');
      synchronousDb.execute('PRAGMA synchronous = $synchronous');
      assert(
        synchronousDb.select('PRAGMA synchronous').single['synchronous'] ==
            expected,
      );
      synchronousDb.execute('BEGIN');
      try {
        synchronousDb.execute('PRAGMA synchronous = OFF');
        assert(false, 'synchronous cannot change inside a transaction');
      } on PureSqlException {
        // SQLite rejects changes to synchronous while a transaction is active.
      }
      synchronousDb
        ..execute('ROLLBACK')
        ..execute('BEGIN')
        ..execute('INSERT INTO synchronous_rows VALUES (?)', [synchronous])
        ..execute('COMMIT')
        ..execute('BEGIN')
        ..execute("INSERT INTO synchronous_rows VALUES ('rolled back')")
        ..execute('ROLLBACK');
      assert(
        synchronousDb
                .select('SELECT value FROM synchronous_rows')
                .single['value'] ==
            synchronous,
      );
      assert(
        synchronousDb
                .select('PRAGMA integrity_check')
                .single['integrity_check'] ==
            'ok',
      );
      synchronousDb.close();

      final reopenedSynchronousDb = PureDatabase.open(synchronousPath);
      assert(
        reopenedSynchronousDb
                .select('SELECT value FROM synchronous_rows')
                .single['value'] ==
            synchronous,
      );
      reopenedSynchronousDb.close();
    }
  }

  final expressionIndexPath = '${directory.path}/expression-index.sqlite';
  var expressionIndexDb = PureDatabase.open(expressionIndexPath);
  expressionIndexDb.execute(
    'CREATE TABLE expression_index_rows (id INTEGER PRIMARY KEY, email TEXT, value TEXT)',
  );
  expressionIndexDb.execute(
    'CREATE UNIQUE INDEX expression_index_email ON expression_index_rows (lower(email) DESC)',
  );
  expressionIndexDb.execute(
    "INSERT INTO expression_index_rows VALUES (1, 'Ada@Example.test', 'old')",
  );
  expressionIndexDb.close();
  expressionIndexDb = PureDatabase.open(expressionIndexPath);
  expressionIndexDb.execute('''
    INSERT INTO expression_index_rows VALUES (2, 'ADA@EXAMPLE.TEST', 'new')
    ON CONFLICT(lower(email)) DO UPDATE SET value = excluded.value
  ''');
  assert(
    expressionIndexDb
            .select('SELECT COUNT(*) AS n FROM expression_index_rows')
            .single['n'] ==
        1,
  );
  assert(
    expressionIndexDb
            .select('SELECT id, value FROM expression_index_rows')
            .single['value'] ==
        'new',
  );
  assert(
    expressionIndexDb
            .select('PRAGMA index_info(expression_index_email)')
            .single['cid'] ==
        -2,
  );
  assert(
    expressionIndexDb
            .select('PRAGMA integrity_check')
            .single['integrity_check'] ==
        'ok',
  );
  expressionIndexDb.close();
  final renameIndexedPath = '${directory.path}/rename-indexed.sqlite';
  var renameIndexedDb = PureDatabase.open(renameIndexedPath);
  renameIndexedDb
    ..execute('''
      CREATE TABLE rename_indexed (
        id INTEGER,
        email TEXT,
        active INTEGER CHECK (active >= 0),
        CHECK (active < 2)
      )
    ''')
    ..execute('''
      CREATE UNIQUE INDEX rename_indexed_idx
      ON rename_indexed (lower(email)) WHERE active = 1
    ''')
    ..execute("INSERT INTO rename_indexed VALUES (1, 'ada', 1)")
    ..execute('ALTER TABLE rename_indexed RENAME COLUMN email TO address')
    ..execute('ALTER TABLE rename_indexed RENAME COLUMN active TO enabled');
  renameIndexedDb.close();
  renameIndexedDb = PureDatabase.open(renameIndexedPath);
  assert(
    renameIndexedDb
            .select('SELECT address FROM rename_indexed')
            .single['address'] ==
        'ada',
  );
  try {
    renameIndexedDb.execute("INSERT INTO rename_indexed VALUES (2, 'ADA', 1)");
    assert(false, 'renamed persistent partial index remains enforced');
  } on PureSqlException {
    // The persisted index expression and predicate use the new column names.
  }
  try {
    renameIndexedDb.execute("INSERT INTO rename_indexed VALUES (4, 'ok', 2)");
    assert(false, 'renamed persistent CHECK expressions remain enforced');
  } on PureSqlException {
    // Both persisted CHECK expressions use the new column name.
  }
  renameIndexedDb
    ..execute("INSERT INTO rename_indexed VALUES (3, 'ADA', 0)")
    ..close();
  final sqliteRenamedIndexCheck = Process.runSync('sqlite3', [
    renameIndexedPath,
    'PRAGMA integrity_check; SELECT COUNT(*) FROM rename_indexed;',
  ]);
  assert(sqliteRenamedIndexCheck.exitCode == 0);
  assert(sqliteRenamedIndexCheck.stdout.toString().trim() == 'ok\n2');
  final renameConstraintPath = '${directory.path}/rename-constraints.sqlite';
  var renameConstraintDb = PureDatabase.open(renameConstraintPath);
  renameConstraintDb
    ..execute('CREATE TABLE rename_parent (id INTEGER PRIMARY KEY)')
    ..execute('INSERT INTO rename_parent VALUES (1), (2)')
    ..execute('''
      CREATE TABLE rename_child (
        account_id INTEGER,
        parent_id INTEGER,
        label TEXT,
        PRIMARY KEY (account_id, label),
        UNIQUE (parent_id),
        FOREIGN KEY (parent_id) REFERENCES rename_parent (id)
      )
    ''')
    ..execute("INSERT INTO rename_child VALUES (1, 1, 'one')")
    ..execute('CREATE TABLE rename_child_join_other (parent_id TEXT)')
    ..execute("INSERT INTO rename_child_join_other VALUES ('other')")
    ..execute('''
      CREATE VIEW rename_child_view AS
      SELECT parent_id FROM rename_child WHERE parent_id > 0
    ''')
    ..execute('''
      CREATE VIEW rename_child_join_view AS
      SELECT rename_child.parent_id AS child_parent,
             rename_child_join_other.parent_id AS other_parent
      FROM rename_child JOIN rename_child_join_other ON 1 = 1
    ''')
    ..execute('''
      CREATE VIEW rename_child_unique_join_view AS
      SELECT parent_id, id FROM rename_child JOIN rename_parent
      ON parent_id = id
    ''')
    ..execute('ALTER TABLE rename_child RENAME COLUMN parent_id TO parent_ref')
    ..execute('ALTER TABLE rename_child RENAME COLUMN account_id TO tenant_id')
    ..execute('ALTER TABLE rename_child RENAME COLUMN label TO display')
    ..execute('ALTER TABLE rename_parent RENAME COLUMN id TO parent_key');
  renameConstraintDb.close();
  renameConstraintDb = PureDatabase.open(renameConstraintPath);
  assert(
    renameConstraintDb
            .select('PRAGMA foreign_key_list(rename_child)')
            .single['from'] ==
        'parent_ref',
  );
  assert(
    renameConstraintDb
            .select('PRAGMA foreign_key_list(rename_child)')
            .single['to'] ==
        'parent_key',
  );
  renameConstraintDb.execute('PRAGMA foreign_keys = ON');
  assert(renameConstraintDb.select('PRAGMA foreign_key_check').isEmpty);
  final renamedJoinRow = renameConstraintDb.select('''
    SELECT child_parent, other_parent FROM rename_child_join_view
  ''').single;
  assert(renamedJoinRow['child_parent'] == 1);
  assert(renamedJoinRow['other_parent'] == 'other');
  final renamedUniqueJoinRow = renameConstraintDb.select('''
    SELECT parent_ref, parent_key FROM rename_child_unique_join_view
  ''').single;
  assert(renamedUniqueJoinRow['parent_ref'] == 1);
  assert(renamedUniqueJoinRow['parent_key'] == 1);
  try {
    renameConstraintDb.execute(
      "INSERT INTO rename_child VALUES (2, 99, 'two')",
    );
    assert(false, 'renamed persistent incoming foreign key remains enforced');
  } on PureSqlException {
    // The reopened child schema references the renamed parent column.
  }
  renameConstraintDb.execute('BEGIN');
  renameConstraintDb.execute(
    'ALTER TABLE rename_parent RENAME COLUMN parent_key TO rolled_back_key',
  );
  renameConstraintDb.execute('ROLLBACK');
  assert(
    renameConstraintDb
            .select('PRAGMA foreign_key_list(rename_child)')
            .single['to'] ==
        'parent_key',
  );
  assert(renameConstraintDb.select('PRAGMA foreign_key_check').isEmpty);
  assert(
    renameConstraintDb
            .select('SELECT parent_ref FROM rename_child_view')
            .single['parent_ref'] ==
        1,
  );
  try {
    renameConstraintDb.execute("INSERT INTO rename_child VALUES (2, 1, 'two')");
    assert(false, 'renamed persistent UNIQUE constraint remains enforced');
  } on PureSqlException {
    // The reopened schema restored its renamed UNIQUE index.
  }
  try {
    renameConstraintDb.execute("INSERT INTO rename_child VALUES (1, 2, 'one')");
    assert(false, 'renamed persistent composite primary key remains enforced');
  } on PureSqlException {
    // The reopened schema restored its composite primary-key index.
  }
  renameConstraintDb.close();
  final sqliteRenamedConstraintCheck = Process.runSync('sqlite3', [
    renameConstraintPath,
    'PRAGMA integrity_check; PRAGMA foreign_key_check; SELECT COUNT(*) FROM rename_child; SELECT parent_ref FROM rename_child_view; SELECT child_parent || \'|\' || other_parent FROM rename_child_join_view; SELECT parent_ref || \'|\' || parent_key FROM rename_child_unique_join_view;',
  ]);
  assert(sqliteRenamedConstraintCheck.exitCode == 0);
  assert(
    sqliteRenamedConstraintCheck.stdout.toString().trim() ==
        'ok\n1\n1\n1|other\n1|1',
  );
  final sqliteExpressionIndexCheck = Process.runSync('sqlite3', [
    expressionIndexPath,
    'PRAGMA integrity_check; SELECT COUNT(*) FROM expression_index_rows;',
  ]);
  assert(
    sqliteExpressionIndexCheck.exitCode == 0,
    sqliteExpressionIndexCheck.stderr,
  );
  assert(
    sqliteExpressionIndexCheck.stdout.trim() == 'ok\n1',
    sqliteExpressionIndexCheck.stdout,
  );

  final vacuumPath = '${directory.path}/vacuum.sqlite';
  final vacuumDb = PureDatabase.open(vacuumPath);
  vacuumDb.execute('PRAGMA application_id = 2718');
  vacuumDb.execute('PRAGMA user_version = 42');
  vacuumDb.execute('PRAGMA default_cache_size = 512');
  vacuumDb.execute(
    'CREATE TABLE vacuum_rows (id INTEGER PRIMARY KEY, tag TEXT, payload TEXT)',
  );
  vacuumDb.execute('CREATE INDEX vacuum_tag ON vacuum_rows (tag)');
  final vacuumPlaceholders = List.filled(80, '(?, ?, ?)').join(', ');
  vacuumDb.execute('INSERT INTO vacuum_rows VALUES $vacuumPlaceholders', [
    for (var id = 1; id <= 80; id++) ...[
      id,
      'tag-${id.toString().padLeft(4, '0')}',
      'x' * 1500,
    ],
  ]);
  vacuumDb.execute('DELETE FROM vacuum_rows WHERE id > 4');
  final vacuumPageCount =
      vacuumDb.select('PRAGMA page_count').single['page_count'] as int;
  assert(
    (vacuumDb.select('PRAGMA freelist_count').single['freelist_count'] as int) >
        0,
  );
  final vacuumSchemaVersion = vacuumDb
      .select('PRAGMA schema_version')
      .single['schema_version'];
  final vacuumIntoPath = '${directory.path}/vacuum-into.sqlite';
  File(vacuumIntoPath).createSync();
  vacuumDb.execute('BEGIN');
  try {
    vacuumDb.execute('VACUUM INTO ?', [vacuumIntoPath]);
    assert(false, 'VACUUM INTO must fail inside a transaction');
  } on PureSqlException catch (error) {
    assert(error.message == 'cannot VACUUM from within a transaction');
  }
  vacuumDb.execute('ROLLBACK');
  vacuumDb.execute('VACUUM INTO ?', [vacuumIntoPath]);
  assert(
    vacuumDb.select('PRAGMA page_count').single['page_count'] ==
        vacuumPageCount,
  );
  assert(
    (vacuumDb.select('PRAGMA freelist_count').single['freelist_count'] as int) >
        0,
  );
  final vacuumIntoDb = PureDatabase.open(vacuumIntoPath);
  assert(
    (vacuumIntoDb.select('PRAGMA page_count').single['page_count'] as int) <
        vacuumPageCount,
  );
  assert(
    vacuumIntoDb.select('PRAGMA freelist_count').single['freelist_count'] == 0,
  );
  assert(
    vacuumIntoDb.select('PRAGMA integrity_check').single['integrity_check'] ==
        'ok',
  );
  assert(
    vacuumIntoDb.select('PRAGMA application_id').single['application_id'] ==
        2718,
  );
  assert(
    vacuumIntoDb.select('PRAGMA user_version').single['user_version'] == 42,
  );
  assert(
    vacuumIntoDb
            .select('PRAGMA default_cache_size')
            .single['default_cache_size'] ==
        512,
  );
  assert(
    vacuumIntoDb.select('PRAGMA schema_version').single['schema_version'] ==
        vacuumSchemaVersion,
  );
  assert(
    vacuumIntoDb
            .select('SELECT COUNT(*) AS count FROM vacuum_rows')
            .single['count'] ==
        4,
  );
  assert(
    vacuumIntoDb.select('PRAGMA index_list(vacuum_rows)').single['name'] ==
        'vacuum_tag',
  );
  vacuumIntoDb.close();
  final sqliteVacuumIntoCheck = Process.runSync('sqlite3', [
    vacuumIntoPath,
    'PRAGMA integrity_check; SELECT COUNT(*) FROM vacuum_rows; PRAGMA freelist_count;',
  ]);
  assert(sqliteVacuumIntoCheck.exitCode == 0, sqliteVacuumIntoCheck.stderr);
  assert(
    sqliteVacuumIntoCheck.stdout.trim() == 'ok\n4\n0',
    sqliteVacuumIntoCheck.stdout,
  );
  final existingVacuumTarget = File('${directory.path}/not-empty.sqlite')
    ..writeAsStringSync('preserve this file');
  try {
    vacuumDb.execute('VACUUM INTO ?', [existingVacuumTarget.path]);
    assert(false, 'VACUUM INTO must reject a non-empty destination');
  } on PureSqlException catch (error) {
    assert(error.message == 'output file already exists');
  }
  assert(existingVacuumTarget.readAsStringSync() == 'preserve this file');

  final memoryVacuumDb = PureDatabase.memory();
  memoryVacuumDb.execute('PRAGMA application_id = 2719');
  memoryVacuumDb.execute('PRAGMA user_version = 43');
  memoryVacuumDb.execute(
    'CREATE TABLE memory_vacuum_rows (id INTEGER PRIMARY KEY AUTOINCREMENT, tag TEXT UNIQUE, payload TEXT)',
  );
  memoryVacuumDb.execute(
    'CREATE INDEX memory_vacuum_payload ON memory_vacuum_rows (payload)',
  );
  memoryVacuumDb.execute('CREATE TABLE memory_vacuum_log (tag TEXT)');
  memoryVacuumDb.execute(
    'CREATE VIEW memory_vacuum_view AS SELECT tag FROM memory_vacuum_rows',
  );
  memoryVacuumDb.execute(
    'CREATE TRIGGER memory_vacuum_ai AFTER INSERT ON memory_vacuum_rows BEGIN INSERT INTO memory_vacuum_log VALUES (NEW.tag); END',
  );
  memoryVacuumDb.execute(
    "INSERT INTO memory_vacuum_rows (tag, payload) VALUES ('a', 'one'), ('b', 'two'), ('c', 'three')",
  );
  memoryVacuumDb.execute("DELETE FROM memory_vacuum_rows WHERE tag = 'c'");
  final memoryVacuumIntoPath = '${directory.path}/memory-vacuum-into.sqlite';
  memoryVacuumDb.execute('VACUUM INTO ?', [memoryVacuumIntoPath]);
  final memoryVacuumIntoDb = PureDatabase.open(memoryVacuumIntoPath);
  assert(
    memoryVacuumIntoDb
            .select('PRAGMA integrity_check')
            .single['integrity_check'] ==
        'ok',
  );
  assert(
    memoryVacuumIntoDb
            .select('PRAGMA application_id')
            .single['application_id'] ==
        2719,
  );
  assert(
    memoryVacuumIntoDb.select('PRAGMA user_version').single['user_version'] ==
        43,
  );
  assert(
    memoryVacuumIntoDb
            .select('SELECT COUNT(*) AS count FROM memory_vacuum_view')
            .single['count'] ==
        2,
  );
  assert(
    memoryVacuumIntoDb.select('PRAGMA index_list(memory_vacuum_rows)').length ==
        2,
  );
  memoryVacuumIntoDb.execute(
    "INSERT INTO memory_vacuum_rows (tag, payload) VALUES ('d', 'four')",
  );
  assert(
    memoryVacuumIntoDb
            .select('SELECT MAX(id) AS id FROM memory_vacuum_rows')
            .single['id'] ==
        4,
  );
  assert(
    memoryVacuumIntoDb
            .select('SELECT COUNT(*) AS count FROM memory_vacuum_log')
            .single['count'] ==
        4,
  );
  memoryVacuumIntoDb.close();
  final sqliteMemoryVacuumCheck = Process.runSync('sqlite3', [
    memoryVacuumIntoPath,
    'PRAGMA integrity_check; SELECT COUNT(*) FROM memory_vacuum_view; SELECT COUNT(*) FROM memory_vacuum_log;',
  ]);
  assert(sqliteMemoryVacuumCheck.exitCode == 0, sqliteMemoryVacuumCheck.stderr);
  assert(
    sqliteMemoryVacuumCheck.stdout.trim() == 'ok\n3\n4',
    sqliteMemoryVacuumCheck.stdout,
  );
  memoryVacuumDb.close();

  vacuumDb.execute('VACUUM main');
  assert(
    (vacuumDb.select('PRAGMA page_count').single['page_count'] as int) <
        vacuumPageCount,
  );
  assert(
    vacuumDb.select('PRAGMA freelist_count').single['freelist_count'] == 0,
  );
  assert(
    vacuumDb.select('PRAGMA integrity_check').single['integrity_check'] == 'ok',
  );
  assert(
    vacuumDb.select('PRAGMA application_id').single['application_id'] == 2718,
  );
  assert(vacuumDb.select('PRAGMA user_version').single['user_version'] == 42);
  assert(
    vacuumDb.select('PRAGMA default_cache_size').single['default_cache_size'] ==
        512,
  );
  assert(
    vacuumDb.select('PRAGMA schema_version').single['schema_version'] ==
        vacuumSchemaVersion,
  );
  assert(
    vacuumDb
            .select('SELECT COUNT(*) AS count FROM vacuum_rows')
            .single['count'] ==
        4,
  );
  vacuumDb.close();
  final sqliteVacuumCheck = Process.runSync('sqlite3', [
    vacuumPath,
    'PRAGMA integrity_check; SELECT COUNT(*) FROM vacuum_rows; PRAGMA freelist_count;',
  ]);
  assert(sqliteVacuumCheck.exitCode == 0, sqliteVacuumCheck.stderr);
  assert(
    sqliteVacuumCheck.stdout.trim() == 'ok\n4\n0',
    sqliteVacuumCheck.stdout,
  );

  final analyzePath = '${directory.path}/analyze.sqlite';
  final analyzeDb = PureDatabase.open(analyzePath);
  analyzeDb.execute('CREATE TABLE analyze_rows (a, b)');
  analyzeDb.execute('CREATE INDEX analyze_rows_ab ON analyze_rows (a, b)');
  analyzeDb.execute('INSERT INTO analyze_rows VALUES (1, 2), (1, 3), (2, 4)');
  analyzeDb.execute('ANALYZE main');
  assert(
    analyzeDb.select('SELECT stat FROM sqlite_stat1').single['stat'] == '3 2 1',
  );
  analyzeDb.close();
  final reopenedAnalyzeDb = PureDatabase.open(analyzePath);
  assert(
    reopenedAnalyzeDb.select('SELECT stat FROM sqlite_stat1').single['stat'] ==
        '3 2 1',
  );
  reopenedAnalyzeDb.close();
  final sqliteAnalyzeStats = Process.runSync('sqlite3', [
    analyzePath,
    'SELECT tbl, idx, stat FROM sqlite_stat1;',
  ]);
  assert(sqliteAnalyzeStats.exitCode == 0, sqliteAnalyzeStats.stderr);
  assert(
    sqliteAnalyzeStats.stdout.trim() == 'analyze_rows|analyze_rows_ab|3 2 1',
    sqliteAnalyzeStats.stdout,
  );

  final pageSizePath = '${directory.path}/page_size.sqlite';
  final pageSizeDb = PureDatabase.open(pageSizePath);
  pageSizeDb.execute('PRAGMA page_size = 8192');
  assert(pageSizeDb.select('PRAGMA page_size').single['page_size'] == 8192);
  assert(File(pageSizePath).lengthSync() == 8192);
  pageSizeDb.execute('PRAGMA page_size = 1000');
  assert(pageSizeDb.select('PRAGMA page_size').single['page_size'] == 8192);
  pageSizeDb.execute('BEGIN');
  pageSizeDb.execute('PRAGMA page_size = 4096');
  assert(pageSizeDb.select('PRAGMA page_size').single['page_size'] == 4096);
  pageSizeDb.execute('ROLLBACK');
  assert(pageSizeDb.select('PRAGMA page_size').single['page_size'] == 8192);
  pageSizeDb.execute('CREATE TABLE page_size_rows (value TEXT)');
  pageSizeDb.execute('PRAGMA page_size = 4096');
  assert(pageSizeDb.select('PRAGMA page_size').single['page_size'] == 8192);
  pageSizeDb.execute('PRAGMA query_only = ON');
  var pageSizeWriteBlocked = false;
  try {
    pageSizeDb.execute('PRAGMA page_size = 16384');
  } on PureSqlException {
    pageSizeWriteBlocked = true;
  }
  assert(pageSizeWriteBlocked);
  pageSizeDb.execute('PRAGMA query_only = OFF');
  pageSizeDb.close();
  final reopenedPageSizeDb = PureDatabase.open(pageSizePath);
  assert(
    reopenedPageSizeDb.select('PRAGMA page_size').single['page_size'] == 8192,
  );
  reopenedPageSizeDb.close();
  final sqlitePageSize = Process.runSync('sqlite3', [
    pageSizePath,
    'PRAGMA page_size; PRAGMA integrity_check; SELECT COUNT(*) FROM page_size_rows;',
  ]);
  assert(sqlitePageSize.exitCode == 0, sqlitePageSize.stderr);
  assert(sqlitePageSize.stdout.trim() == '8192\nok\n0', sqlitePageSize.stdout);
  final existingEmptyPath = '${directory.path}/existing_empty.sqlite';
  final initializeExistingEmpty = Process.runSync('sqlite3', [
    existingEmptyPath,
    'PRAGMA user_version = 1;',
  ]);
  assert(initializeExistingEmpty.exitCode == 0, initializeExistingEmpty.stderr);
  final existingEmptyDb = PureDatabase.open(existingEmptyPath);
  existingEmptyDb.execute('PRAGMA page_size = 8192');
  assert(
    existingEmptyDb.select('PRAGMA page_size').single['page_size'] == 4096,
  );
  existingEmptyDb.close();

  final pageLimitPath = '${directory.path}/page_limit.sqlite';
  final pageLimitDb = PureDatabase.open(pageLimitPath);
  pageLimitDb.execute('CREATE TABLE page_limit_rows (payload BLOB)');
  pageLimitDb.execute('PRAGMA max_page_count = 4294967295');
  assert(
    pageLimitDb.select('PRAGMA max_page_count').single['max_page_count'] ==
        SqlitePagerSync.defaultMaxPageCount,
    'max_page_count must be capped at SQLite’s file-format limit',
  );
  assert(
    pageLimitDb
        .select('PRAGMA pragma_list')
        .any((row) => row['name'] == 'max_page_count'),
  );
  final pageCount =
      pageLimitDb.select('PRAGMA page_count').single['page_count'] as int;
  pageLimitDb.execute('PRAGMA max_page_count = 1');
  assert(
    pageLimitDb.select('PRAGMA max_page_count').single['max_page_count'] ==
        pageCount,
    'max_page_count cannot be reduced below the current file size',
  );
  pageLimitDb.execute('PRAGMA max_page_count = $pageCount');
  var databaseFull = false;
  try {
    pageLimitDb.execute('INSERT INTO page_limit_rows VALUES (?)', [
      Uint8List(8192),
    ]);
  } on PureSqlException catch (error) {
    databaseFull = error.message == 'database or disk is full';
  }
  assert(databaseFull, 'page growth beyond max_page_count must fail as FULL');
  assert(
    pageLimitDb.select('SELECT * FROM page_limit_rows').isEmpty,
    'the failed insert must be rolled back',
  );
  assert(
    pageLimitDb.select('PRAGMA page_count').single['page_count'] == pageCount,
  );
  pageLimitDb.execute('PRAGMA max_page_count = ${pageCount + 8}');
  pageLimitDb.execute('INSERT INTO page_limit_rows VALUES (?)', [
    Uint8List(8192),
  ]);
  assert(
    (pageLimitDb.select('PRAGMA page_count').single['page_count'] as int) >
        pageCount,
  );
  pageLimitDb.close();
  final reopenedPageLimitDb = PureDatabase.open(pageLimitPath);
  assert(
    reopenedPageLimitDb
            .select('PRAGMA max_page_count')
            .single['max_page_count'] ==
        SqlitePagerSync.defaultMaxPageCount,
    'max_page_count is connection-local and resets on reopen',
  );
  reopenedPageLimitDb.close();

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
  database.execute('PRAGMA query_only = ON');
  assert(database.select('PRAGMA query_only').single['query_only'] == 1);
  assert(database.select('SELECT id FROM folders').single['id'] == 'folder');
  try {
    database.execute('PRAGMA user_version = 8');
    assert(false, 'query_only should reject persistent header writes');
  } on PureSqlException {
    // Expected; a connection-local read-only switch protects this handle.
  }
  try {
    database.execute("INSERT INTO folders VALUES ('blocked')");
    assert(false, 'query_only should reject persistent row writes');
  } on PureSqlException {
    // Expected.
  }
  database.execute('PRAGMA query_only = OFF');
  database.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
  database.execute('CREATE TABLE ctas_source (id INTEGER, label TEXT)');
  database.execute("INSERT INTO ctas_source VALUES (1, 'copied')");
  database.execute('''
    CREATE TABLE ctas_copy AS
    SELECT id, label AS copied_label FROM ctas_source
  ''');
  assert(
    database
            .select('PRAGMA table_info(ctas_copy)')
            .map((row) => row['type'])
            .join(',') ==
        'INT,TEXT',
  );
  database.execute('CREATE TABLE session_shadow_rows (value TEXT)');
  database.execute("INSERT INTO session_shadow_rows VALUES ('main')");
  final schemaVersionBeforeTemp = database
      .select('PRAGMA schema_version')
      .single['schema_version'];
  database.execute('CREATE TEMP TABLE session_shadow_rows (value TEXT)');
  database.execute('PRAGMA temp.user_version = 41');
  database.execute(
    "ALTER TABLE session_shadow_rows ADD COLUMN scratch TEXT DEFAULT 'session'",
  );
  database.execute(
    'ALTER TABLE session_shadow_rows RENAME COLUMN scratch TO marker',
  );
  database.execute('ALTER TABLE session_shadow_rows DROP COLUMN marker');
  database.execute(
    'CREATE TEMP UNIQUE INDEX session_shadow_value_idx ON session_shadow_rows(value)',
  );
  database.execute(
    'CREATE TEMP VIEW session_temp_view AS SELECT label FROM ctas_source',
  );
  final tempSchemaVersionBeforeRollback = database
      .select('PRAGMA temp.schema_version')
      .single['schema_version'];
  database.execute('BEGIN');
  database
    ..execute('PRAGMA temp.user_version = 42')
    ..execute('PRAGMA temp.cache_size = 17')
    ..execute('CREATE TEMP TABLE session_rollback_header (value TEXT)')
    ..execute('ROLLBACK');
  assert(
    database.select('PRAGMA temp.user_version').single['user_version'] == 41,
  );
  assert(database.select('PRAGMA temp.cache_size').single['cache_size'] == 17);
  assert(
    database.select('PRAGMA temp.schema_version').single['schema_version'] ==
        tempSchemaVersionBeforeRollback,
  );
  assert(
    database
        .select('PRAGMA temp.table_list')
        .every((row) => row['name'] != 'session_rollback_header'),
  );
  database.execute("INSERT INTO session_shadow_rows VALUES ('temp')");
  assert(
    database.select('SELECT value FROM session_shadow_rows').single['value'] ==
        'temp',
  );
  assert(
    database.select('PRAGMA schema_version').single['schema_version'] ==
        schemaVersionBeforeTemp,
  );
  assert(
    database.select('SELECT label FROM session_temp_view').single['label'] ==
        'copied',
  );
  assert(
    database
        .select('PRAGMA table_list')
        .any(
          (row) =>
              row['schema'] == 'temp' && row['name'] == 'session_shadow_rows',
        ),
  );
  try {
    database.transaction((database) {
      database.execute("INSERT INTO session_shadow_rows VALUES ('rollback')");
      database.execute('CREATE TEMP TABLE session_rollback_rows (value TEXT)');
      database.execute(
        'CREATE TEMP VIEW session_rollback_view AS SELECT value FROM session_shadow_rows',
      );
      throw StateError('rollback temporary schema and rows');
    });
  } on StateError {
    // Expected.
  }
  assert(database.select('SELECT * FROM session_shadow_rows').length == 1);
  assert(
    database
        .select('PRAGMA table_list')
        .where(
          (row) =>
              row['name'] == 'session_rollback_rows' ||
              row['name'] == 'session_rollback_view',
        )
        .isEmpty,
  );
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
  final legacyRenamePath = '${directory.path}/legacy-rename.sqlite';
  final legacyRenameDb = PureDatabase.open(legacyRenamePath);
  legacyRenameDb.execute('CREATE TABLE legacy_parent (id INTEGER PRIMARY KEY)');
  legacyRenameDb.execute(
    'CREATE TABLE legacy_child (parent_id REFERENCES legacy_parent(id))',
  );
  legacyRenameDb.execute('CREATE TABLE legacy_audit (count INTEGER)');
  legacyRenameDb.execute('''
    CREATE VIEW legacy_parent_view AS SELECT id FROM legacy_parent
  ''');
  legacyRenameDb.execute('''
    CREATE TRIGGER legacy_parent_ai AFTER INSERT ON legacy_parent BEGIN
      INSERT INTO legacy_audit SELECT COUNT(*) FROM legacy_parent;
    END
  ''');
  legacyRenameDb.execute('PRAGMA legacy_alter_table = ON');
  legacyRenameDb.execute(
    'ALTER TABLE legacy_parent RENAME TO legacy_parent_new',
  );
  assert(
    legacyRenameDb
            .select('PRAGMA foreign_key_list(legacy_child)')
            .single['table'] ==
        'legacy_parent',
  );
  legacyRenameDb.close();
  final reopenedLegacyRenameDb = PureDatabase.open(legacyRenamePath);
  assert(
    reopenedLegacyRenameDb
            .select('PRAGMA legacy_alter_table')
            .single['legacy_alter_table'] ==
        0,
  );
  try {
    reopenedLegacyRenameDb.select('SELECT id FROM legacy_parent_view');
    assert(false, 'persistent legacy rename retains the old view reference');
  } on PureSqlException catch (error) {
    assert(error.message == 'no such table: legacy_parent');
  }
  try {
    reopenedLegacyRenameDb.execute('INSERT INTO legacy_parent_new VALUES (1)');
    assert(
      false,
      'persistent legacy rename retains the trigger body reference',
    );
  } on PureSqlException catch (error) {
    assert(error.message == 'no such table: legacy_parent');
  }
  reopenedLegacyRenameDb.close();
  final sqliteLegacyRenameCheck = Process.runSync('sqlite3', [
    legacyRenamePath,
    'PRAGMA integrity_check; PRAGMA foreign_key_list(legacy_child);',
  ]);
  assert(sqliteLegacyRenameCheck.exitCode == 0, sqliteLegacyRenameCheck.stderr);
  assert(
    sqliteLegacyRenameCheck.stdout.trim() ==
        'ok\n0|0|legacy_parent|parent_id|id|NO ACTION|NO ACTION|NONE',
    sqliteLegacyRenameCheck.stdout,
  );
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
    'CREATE TABLE persistent_rename_parent (id INTEGER PRIMARY KEY)',
  );
  database.execute('INSERT INTO persistent_rename_parent VALUES (1)');
  database.execute('''
    CREATE TABLE persistent_rename_unrelated (
      id INTEGER PRIMARY KEY,
      old_name TEXT,
      unique_value TEXT UNIQUE,
      CHECK (id > 0),
      FOREIGN KEY (id) REFERENCES persistent_rename_parent(id)
    )
  ''');
  database.execute(
    "INSERT INTO persistent_rename_unrelated VALUES (1, 'survives', 'unique')",
  );
  database.execute('''
    CREATE VIEW persistent_rename_unrelated_view AS
    SELECT id FROM persistent_rename_unrelated
  ''');
  database.execute('''
    ALTER TABLE persistent_rename_unrelated
    RENAME COLUMN old_name TO new_name
  ''');
  database.execute(
    'CREATE TABLE persistent_drop_column (id INTEGER PRIMARY KEY, remove_me TEXT, keep TEXT)',
  );
  database.execute(
    "INSERT INTO persistent_drop_column VALUES (1, 'gone', 'kept')",
  );
  database.execute('''
    CREATE VIEW persistent_drop_column_projection AS
    SELECT remove_me FROM persistent_drop_column
  ''');
  database.execute('''
    CREATE VIEW persistent_drop_column_wildcard AS
    SELECT * FROM persistent_drop_column
  ''');
  database.execute('ALTER TABLE persistent_drop_column DROP COLUMN remove_me');
  database.execute(
    'CREATE TABLE persistent_drop_parent (id INTEGER PRIMARY KEY)',
  );
  database.execute('INSERT INTO persistent_drop_parent VALUES (2)');
  database.execute('''
    CREATE TABLE persistent_drop_constraints (
      id INTEGER,
      keep INTEGER,
      remove_me TEXT,
      PRIMARY KEY (id, keep),
      UNIQUE (keep),
      CHECK (keep > 0),
      FOREIGN KEY (keep) REFERENCES persistent_drop_parent(id)
    )
  ''');
  database.execute(
    "INSERT INTO persistent_drop_constraints VALUES (1, 2, 'gone')",
  );
  database.execute(
    'ALTER TABLE persistent_drop_constraints DROP COLUMN remove_me',
  );
  database.execute('''
    CREATE TABLE persistent_drop_indexed (
      id INTEGER PRIMARY KEY,
      remove_me TEXT,
      indexed_value TEXT
    )
  ''');
  database.execute(
    'CREATE INDEX persistent_drop_indexed_idx ON persistent_drop_indexed(indexed_value)',
  );
  database.execute(
    "INSERT INTO persistent_drop_indexed VALUES (1, 'gone', 'kept')",
  );
  database.execute('ALTER TABLE persistent_drop_indexed DROP COLUMN remove_me');
  database.execute(
    'CREATE TABLE persistent_returning (id INTEGER PRIMARY KEY, value TEXT)',
  );
  final persistedReturning = database.select('''
    INSERT INTO persistent_returning VALUES (1, 'returned')
    RETURNING id, value
  ''');
  assert(persistedReturning.single['value'] == 'returned');
  database.execute('''
    CREATE TABLE persistent_auto_ids (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      value TEXT
    )
  ''');
  database.execute(
    "INSERT INTO persistent_auto_ids (value) VALUES ('one'), ('deleted')",
  );
  database.execute('DELETE FROM persistent_auto_ids WHERE id = 2');
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
    ALTER TABLE users ADD COLUMN status TEXT DEFAULT 'active'
    CHECK (status IN ('active', 'disabled'))
  ''');
  assert(
    database.select('SELECT status FROM users WHERE id = 1').single['status'] ==
        'active',
  );
  database.execute('''
    CREATE VIEW first_users(user_id, display_name) AS
      SELECT id, name FROM users WHERE id < 3
  ''');
  database.execute('CREATE TABLE persistent_trigger_source (value TEXT)');
  database.execute('CREATE TABLE persistent_trigger_audit (value TEXT)');
  database.execute('''
    CREATE TRIGGER persistent_trigger_ai AFTER INSERT ON persistent_trigger_source
    BEGIN
      INSERT INTO persistent_trigger_audit VALUES (NEW.value);
    END
  ''');
  database.execute('CREATE TABLE persistent_before_rows (value TEXT)');
  database.execute(
    'CREATE TABLE persistent_before_audit (id INTEGER PRIMARY KEY, value TEXT)',
  );
  database.execute('''
    CREATE TRIGGER persistent_before_bi BEFORE INSERT ON persistent_before_rows
    BEGIN INSERT INTO persistent_before_audit (value) VALUES (NEW.value); END
  ''');
  database.execute(
    'CREATE TABLE persistent_instead_base (id INTEGER PRIMARY KEY, value TEXT)',
  );
  database.execute('''
    CREATE VIEW persistent_instead_view(row_id, view_text) AS
    SELECT id, value FROM persistent_instead_base
  ''');
  database.execute('''
    CREATE TRIGGER persistent_instead_insert INSTEAD OF INSERT
    ON persistent_instead_view BEGIN
      INSERT INTO persistent_instead_base VALUES (NEW.row_id, NEW.view_text);
    END
  ''');
  database.execute(
    "INSERT INTO persistent_instead_view VALUES (1, 'before-close')",
  );
  database.execute('CREATE TABLE persistent_temp_rows (value INTEGER)');
  database.execute('CREATE TABLE persistent_temp_audit (value INTEGER)');
  database.execute('''
    CREATE TEMP TRIGGER persistent_temp_insert AFTER INSERT
    ON persistent_temp_rows BEGIN
      INSERT INTO persistent_temp_audit VALUES (NEW.value);
    END
  ''');
  database.execute('INSERT INTO persistent_temp_rows VALUES (1)');
  database.execute('BEGIN');
  database.execute('''
    CREATE TEMP TRIGGER rolled_back_persistent_temp_trigger AFTER INSERT
    ON persistent_temp_rows BEGIN
      INSERT INTO persistent_temp_audit VALUES (999);
    END
  ''');
  database.execute('ROLLBACK');
  database.execute('INSERT INTO persistent_temp_rows VALUES (2)');
  database.execute(
    "INSERT INTO persistent_before_rows VALUES ('before-close')",
  );
  database.execute(
    'CREATE TABLE persistent_column_trigger (id INTEGER PRIMARY KEY, label TEXT, spare TEXT)',
  );
  database.execute(
    'CREATE TABLE persistent_column_trigger_audit (old_label TEXT, new_label TEXT)',
  );
  database.execute('''
    CREATE TRIGGER persistent_column_trigger_au
    AFTER UPDATE OF label ON persistent_column_trigger
    WHEN OLD.label IS NOT NEW.label
    BEGIN
      INSERT INTO persistent_column_trigger_audit VALUES (OLD.label, NEW.label);
    END
  ''');
  database.execute(
    "INSERT INTO persistent_column_trigger VALUES (1, 'before', 'unused')",
  );
  database.execute(
    'ALTER TABLE persistent_column_trigger RENAME COLUMN label TO display_label',
  );
  database.execute('ALTER TABLE persistent_column_trigger DROP COLUMN spare');
  database.execute('CREATE TABLE persistent_raise_rows (value INTEGER)');
  database.execute('''
    CREATE TRIGGER persistent_raise_rows_ai AFTER INSERT ON persistent_raise_rows
    WHEN NEW.value = 2
    BEGIN SELECT RAISE(ABORT, 'persistent statement aborted'); END
  ''');
  database.execute(
    'CREATE TABLE persistent_raise_update_rows (id INTEGER PRIMARY KEY, value INTEGER)',
  );
  database.execute(
    'INSERT INTO persistent_raise_update_rows VALUES (1, 1), (2, 2), (3, 3)',
  );
  database.execute('''
    CREATE TRIGGER persistent_raise_update_au
    AFTER UPDATE ON persistent_raise_update_rows
    WHEN NEW.value = 12
    BEGIN SELECT RAISE(FAIL, 'persistent update failed'); END
  ''');
  database.execute(
    'CREATE TABLE persistent_raise_delete_rows (value INTEGER PRIMARY KEY)',
  );
  database.execute(
    'INSERT INTO persistent_raise_delete_rows VALUES (1), (2), (3)',
  );
  database.execute('''
    CREATE TRIGGER persistent_raise_delete_ad
    AFTER DELETE ON persistent_raise_delete_rows
    WHEN OLD.value = 2
    BEGIN SELECT RAISE(FAIL, 'persistent delete failed'); END
  ''');
  database.execute(
    'CREATE TABLE persistent_raise_rollback_rows (value INTEGER)',
  );
  database.execute('''
    CREATE TRIGGER persistent_raise_rollback_ai
    AFTER INSERT ON persistent_raise_rollback_rows
    WHEN NEW.value = 2
    BEGIN SELECT RAISE(ROLLBACK, 'persistent transaction rolled back'); END
  ''');
  database.execute(
    'ALTER TABLE persistent_trigger_source RENAME TO persistent_trigger_renamed',
  );
  final expectedSchemaVersion = database
      .select('PRAGMA schema_version')
      .single['schema_version'];
  database.close();

  final reopened = PureDatabase.open(path);
  assert(
    reopened
            .select('PRAGMA table_info(ctas_copy)')
            .map((row) => row['type'])
            .join(',') ==
        'INT,TEXT',
  );
  assert(reopened.select('PRAGMA query_only').single['query_only'] == 0);
  assert(
    reopened.select('SELECT status FROM users WHERE id = 1').single['status'] ==
        'active',
  );
  try {
    reopened.execute("UPDATE users SET status = 'invalid' WHERE id = 1");
    assert(false, 'persistent ADD COLUMN CHECK remains enforced');
  } on PureSqlException {
    // The added column constraint survived reopen.
  }
  final reopenedDropWildcard = reopened
      .select('SELECT * FROM persistent_drop_column_wildcard')
      .single;
  assert(reopenedDropWildcard.length == 2);
  assert(reopenedDropWildcard['keep'] == 'kept');
  var reopenedDropProjectionInvalid = false;
  try {
    reopened.select('SELECT * FROM persistent_drop_column_projection');
  } on PureSqlException catch (error) {
    reopenedDropProjectionInvalid = error.message.contains('no such column');
  }
  assert(reopenedDropProjectionInvalid);
  assert(
    reopened.select('SELECT value FROM session_shadow_rows').single['value'] ==
        'main',
  );
  assert(
    reopened
        .select('PRAGMA table_list')
        .where((row) => row['schema'] == 'temp')
        .isEmpty,
  );
  reopened.execute("INSERT INTO persistent_before_rows VALUES ('after-open')");
  assert(
    reopened
            .select('SELECT value FROM persistent_before_audit ORDER BY id')
            .map((row) => row['value'])
            .join(',') ==
        'before-close,after-open',
  );
  reopened.execute(
    "INSERT INTO persistent_instead_view VALUES (2, 'after-open')",
  );
  reopened.execute('INSERT INTO persistent_temp_rows VALUES (3)');
  assert(
    reopened
            .select('SELECT value FROM persistent_temp_audit')
            .map((row) => row['value'])
            .join(',') ==
        '1,2',
  );
  assert(
    reopened
            .select(
              'SELECT row_id, view_text FROM persistent_instead_view ORDER BY row_id',
            )
            .map((row) => '${row['row_id']}:${row['view_text']}')
            .join(',') ==
        '1:before-close,2:after-open',
  );
  assert(
    reopened
            .select('SELECT id, copied_label FROM ctas_copy')
            .single['copied_label'] ==
        'copied',
  );
  reopened.execute(
    "INSERT INTO persistent_trigger_renamed VALUES ('survived')",
  );
  assert(
    reopened
            .select('SELECT value FROM persistent_trigger_audit')
            .single['value'] ==
        'survived',
  );
  reopened.execute(
    "UPDATE persistent_column_trigger SET display_label = 'after' WHERE id = 1",
  );
  assert(
    reopened
            .select(
              'SELECT old_label, new_label FROM persistent_column_trigger_audit',
            )
            .single['new_label'] ==
        'after',
  );
  reopened.execute('BEGIN');
  reopened.execute('INSERT INTO persistent_raise_rows VALUES (1)');
  try {
    reopened.execute('INSERT INTO persistent_raise_rows VALUES (2), (3)');
    assert(false, 'RAISE(ABORT) should roll back only this statement');
  } on SqliteException catch (error) {
    assert(error.message == 'persistent statement aborted');
  }
  assert(
    reopened
            .select('SELECT value FROM persistent_raise_rows ORDER BY value')
            .map((row) => row['value'])
            .join(',') ==
        '1',
  );
  reopened.execute('COMMIT');
  try {
    reopened.execute(
      'UPDATE persistent_raise_update_rows SET value = value + 10',
    );
    assert(false, 'RAISE(FAIL) should preserve persistent update changes');
  } on SqliteException catch (error) {
    assert(error.message == 'persistent update failed');
  }
  assert(
    reopened
            .select(
              'SELECT value FROM persistent_raise_update_rows ORDER BY value',
            )
            .map((row) => row['value'])
            .join(',') ==
        '3,11,12',
  );
  try {
    reopened.execute('DELETE FROM persistent_raise_delete_rows');
    assert(false, 'RAISE(FAIL) should preserve persistent delete changes');
  } on SqliteException catch (error) {
    assert(error.message == 'persistent delete failed');
  }
  assert(
    reopened
            .select(
              'SELECT value FROM persistent_raise_delete_rows ORDER BY value',
            )
            .map((row) => row['value'])
            .join(',') ==
        '1',
  );
  reopened.execute('BEGIN');
  reopened.execute('INSERT INTO persistent_raise_rollback_rows VALUES (1)');
  try {
    reopened.execute('INSERT INTO persistent_raise_rollback_rows VALUES (2)');
    assert(false, 'RAISE(ROLLBACK) should roll back the whole transaction');
  } on SqliteException catch (error) {
    assert(error.message == 'persistent transaction rolled back');
  }
  assert(
    reopened.select('SELECT * FROM persistent_raise_rollback_rows').isEmpty,
  );
  reopened.execute('INSERT INTO persistent_raise_rollback_rows VALUES (3)');
  reopened.execute(
    "INSERT INTO persistent_auto_ids (value) VALUES ('after reopen')",
  );
  assert(
    reopened
            .select(
              "SELECT id FROM persistent_auto_ids WHERE value = 'after reopen'",
            )
            .single['id'] ==
        3,
  );
  reopened.execute('BEGIN');
  reopened.execute(
    "INSERT INTO persistent_auto_ids (value) VALUES ('rolled back')",
  );
  reopened.execute('ROLLBACK');
  reopened.execute(
    "INSERT INTO persistent_auto_ids (value) VALUES ('after rollback')",
  );
  assert(
    reopened
            .select(
              "SELECT id FROM persistent_auto_ids WHERE value = 'after rollback'",
            )
            .single['id'] ==
        4,
  );
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
    reopened
            .select('SELECT new_name FROM persistent_rename_unrelated')
            .single['new_name'] ==
        'survives',
  );
  assert(
    reopened
            .select('SELECT id FROM persistent_rename_unrelated_view')
            .single['id'] ==
        1,
  );
  assert(
    reopened
            .select('PRAGMA index_list(persistent_rename_unrelated)')
            .single['unique'] ==
        1,
  );
  assert(
    reopened.select('SELECT keep FROM persistent_drop_column').single['keep'] ==
        'kept',
  );
  assert(
    reopened
            .select('SELECT id, keep FROM persistent_drop_constraints')
            .single['keep'] ==
        2,
  );
  assert(
    reopened
            .select('PRAGMA table_info(persistent_drop_constraints)')
            .map((row) => row['pk'])
            .join(',') ==
        '1,2',
  );
  assert(
    reopened
            .select('PRAGMA foreign_key_list(persistent_drop_constraints)')
            .single['from'] ==
        'keep',
  );
  for (final invalidInsert in [
    'INSERT INTO persistent_drop_constraints VALUES (2, 2)',
    'INSERT INTO persistent_drop_constraints VALUES (2, -1)',
  ]) {
    try {
      reopened.execute(invalidInsert);
      assert(false, 'persistent constraints should survive DROP and reopen');
    } on PureSqlException {
      // The retained UNIQUE and CHECK constraints remain active.
    }
  }
  assert(
    reopened
            .select('SELECT indexed_value FROM persistent_drop_indexed')
            .single['indexed_value'] ==
        'kept',
  );
  assert(
    reopened
            .select('PRAGMA index_info(persistent_drop_indexed_idx)')
            .single['name'] ==
        'indexed_value',
  );
  assert(
    reopened.select('SELECT value FROM persistent_returning').single['value'] ==
        'returned',
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
  assert(
    recovered
            .select('SELECT value FROM persistent_raise_rows')
            .single['value'] ==
        1,
  );
  assert(
    recovered
            .select(
              'SELECT value FROM persistent_raise_update_rows ORDER BY value',
            )
            .map((row) => row['value'])
            .join(',') ==
        '3,11,12',
  );
  assert(
    recovered
            .select(
              'SELECT value FROM persistent_raise_delete_rows ORDER BY value',
            )
            .single['value'] ==
        1,
  );
  assert(
    recovered
            .select('SELECT value FROM persistent_raise_rollback_rows')
            .single['value'] ==
        3,
  );
  recovered.close();
  final droppedSchemaCheck = Process.runSync('sqlite3', [
    path,
    'PRAGMA integrity_check;',
  ]);
  assert(droppedSchemaCheck.exitCode == 0, droppedSchemaCheck.stderr);
  assert(droppedSchemaCheck.stdout.trim() == 'ok', droppedSchemaCheck.stdout);

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
