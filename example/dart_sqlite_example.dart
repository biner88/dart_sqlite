import 'package:dart_sqlite/dart_sqlite.dart';

void main() {
  final database = PureDatabase.memory();
  try {
    database.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)');
    database.execute('INSERT INTO notes (body) VALUES (?)', ['Hello, SQLite']);

    final notes = database.select('SELECT id, body FROM notes');
    print('${notes.single['id']}: ${notes.single['body']}');
  } finally {
    database.close();
  }
}
