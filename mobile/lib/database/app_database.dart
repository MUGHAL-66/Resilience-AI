import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'dart:math';

class AppDatabase {
  AppDatabase({this.testDatabase});
  final Database? testDatabase;
  static final instance = AppDatabase();
  static const schemaVersion = 4;
  Database? _database;

  Future<Database> get database async {
    if (testDatabase case final db?) return db;
    if (_database case final db?) return db;
    final root = await getDatabasesPath();
    _database = await openDatabase(p.join(root, 'resilience_ai.db'),
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 1) await _createSchema(db);
          if (oldVersion < 2) await _createMetadataSchema(db);
          if (oldVersion >= 1 && oldVersion < 3) await _upgradeToV3(db);
          if (oldVersion < 4) await _upgradeToV4(db);
        });
    return _database!;
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute(
        '''CREATE TABLE emergency_cases (local_id TEXT PRIMARY KEY, server_id INTEGER NULL, emergency_type TEXT NOT NULL DEFAULT 'other', injury_type TEXT NOT NULL, injury_detail TEXT NOT NULL DEFAULT 'unknown', bleeding_status TEXT NOT NULL, consciousness_status TEXT NOT NULL, trapped INTEGER NOT NULL CHECK (trapped IN (0,1)), trapped_status TEXT NOT NULL DEFAULT 'unknown', people_affected INTEGER NULL CHECK (people_affected IS NULL OR people_affected >= 1), description TEXT NOT NULL, latitude REAL NULL, longitude REAL NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, priority TEXT NULL, status TEXT NOT NULL, sync_status TEXT NOT NULL CHECK (sync_status IN ('pending','synced','failed')))''');
    await db.execute(
        'CREATE INDEX emergency_sync_status_idx ON emergency_cases(sync_status)');
    await db.execute(
        '''CREATE TABLE message_queue (message_id TEXT PRIMARY KEY, emergency_local_id TEXT NOT NULL REFERENCES emergency_cases(local_id) ON DELETE CASCADE, origin_device_id TEXT NULL, sender_device_id TEXT NULL, message_type TEXT NOT NULL, payload_json TEXT NOT NULL, created_at TEXT NOT NULL, expires_at TEXT NULL, hop_count INTEGER NOT NULL DEFAULT 0, delivery_status TEXT NOT NULL, last_attempt_at TEXT NULL, attempt_count INTEGER NOT NULL DEFAULT 0, last_peer_token TEXT NULL)''');
    await db.execute(
        'CREATE INDEX message_queue_delivery_idx ON message_queue(delivery_status, created_at)');
    await _createMetadataSchema(db);
  }

  Future<void> _createMetadataSchema(DatabaseExecutor db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS app_metadata (metadata_key TEXT PRIMARY KEY, metadata_value TEXT NOT NULL)');
  }

  Future<void> _upgradeToV3(DatabaseExecutor db) async {
    await db.execute(
        "ALTER TABLE emergency_cases ADD COLUMN emergency_type TEXT NOT NULL DEFAULT 'other'");
    await db.execute(
        "ALTER TABLE emergency_cases ADD COLUMN trapped_status TEXT NOT NULL DEFAULT 'unknown'");
    await db.execute(
        'ALTER TABLE emergency_cases ADD COLUMN people_affected INTEGER NULL');
    await db.execute(
        "ALTER TABLE emergency_cases ADD COLUMN injury_detail TEXT NOT NULL DEFAULT 'unknown'");
    await db.execute(
        "UPDATE emergency_cases SET trapped_status = CASE WHEN trapped = 1 THEN 'yes' ELSE 'no' END");
  }

  Future<void> _upgradeToV4(DatabaseExecutor db) async {
    await db.execute(
        'ALTER TABLE message_queue ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0');
    await db.execute(
        'ALTER TABLE message_queue ADD COLUMN last_peer_token TEXT NULL');
  }

  Future<String> getOrCreateDeviceId() async {
    final db = await database;
    return db.transaction((txn) async {
      await _createMetadataSchema(txn);
      final rows = await txn.query('app_metadata',
          columns: ['metadata_value'],
          where: 'metadata_key = ?',
          whereArgs: ['device_id'],
          limit: 1);
      if (rows.isNotEmpty) return rows.single['metadata_value']! as String;
      final random = Random.secure();
      final value = List<int>.generate(32, (_) => random.nextInt(16))
          .map((digit) => digit.toRadixString(16))
          .join();
      final deviceId = 'device_$value';
      await txn.insert('app_metadata', {
        'metadata_key': 'device_id',
        'metadata_value': deviceId,
      });
      return deviceId;
    });
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
