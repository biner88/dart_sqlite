import 'dart:io';
import 'dart:typed_data';

import 'package:dart_sqlite/dart_sqlite.dart';

Future<void> main() async {
  for (final value in [0, 1, 127, 128, 16383, 16384, 0x00ffffffffffffff]) {
    final encoded = SqliteVarint.encode(value);
    assert(SqliteVarint.read(encoded).$1 == value);
  }

  final record = SqliteRecordCodec.encode([
    null,
    0,
    1,
    -123456,
    3.5,
    '你好',
    Uint8List.fromList([1, 2, 3]),
  ]);
  final decoded = SqliteRecordCodec.decode(record);
  assert(decoded[0] == null);
  assert(decoded[1] == 0);
  assert(decoded[2] == 1);
  assert(decoded[3] == -123456);
  assert(decoded[4] == 3.5);
  assert(decoded[5] == '你好');
  assert((decoded[6] as Uint8List).join(',') == '1,2,3');

  final directory = await Directory.systemTemp.createTemp('dart_sqlite_');
  final path = '${directory.path}/empty.sqlite';
  final pager = await SqlitePager.open(path);
  assert(pager.pageCount == 1);
  assert((await pager.readPage(1))[100] == 0x0d);
  await pager.close();

  final reopened = await SqlitePager.open(path);
  assert(reopened.header.pageSize == 4096);
  assert(reopened.pageCount == 1);
  await reopened.close();
  if (Platform.environment['KEEP_SQLITE_FILE'] == '1') {
    print(path);
  } else {
    await directory.delete(recursive: true);
  }
}
