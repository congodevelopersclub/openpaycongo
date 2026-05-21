import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/parser_source.dart';

class ParserStore {
  Database? _db;

  Future<Database> _database() async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), 'parsers.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) {
        db.execute('''CREATE TABLE parsers(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            regex TEXT NOT NULL
          )''');
      },
    );
    return _db!;
  }

  Future<List<ParserSource>> all() async {
    final db = await _database();
    final res = await db.query('parsers');
    return res.map((e) => ParserSource.fromMap(e)).toList();
  }

  Future<int> insert(ParserSource src) async {
    final db = await _database();
    return db.insert('parsers', src.toMap());
  }
}
