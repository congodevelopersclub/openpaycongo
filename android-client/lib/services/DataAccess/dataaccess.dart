import 'dart:io';

import 'package:opencongopay/models/paymentdetail.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  DatabaseHelper._privateConstructor();
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    Directory directory = await getApplicationDocumentsDirectory();
    String path = join(directory.path, 'opencongopay.db');

    return await openDatabase(path, version: 1, onCreate: _onCreate);
  }

  Future _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE paymentdetail (
        id INTEGER AUTOINCREMENT PRIMARY KEY,
        name TEXT NOT NULL,
        sender TEXT NOT NULL,
        amount TEXT NOT NULL,
        currency TEXT NOT NULL,
        balance TEXT NOT NULL,
        reference TEXT NOT NULL
      )
    ''');
  }

  Future<PaymentDetail> insert(PaymentDetail payment) async {
    Database db = await instance.database;
    int id = await db.insert('paymentdetail', payment.toMap());

    return payment.copy(id: id);
  }
}
