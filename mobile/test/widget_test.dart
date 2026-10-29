import 'package:flutter_test/flutter_test.dart';
import 'package:resilience_ai/app.dart';
import 'package:resilience_ai/database/app_database.dart';
import 'package:resilience_ai/repositories/emergency_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database testDatabase;

  setUpAll(() async {
    sqfliteFfiInit();
    testDatabase = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE emergency_cases (
            local_id TEXT PRIMARY KEY, server_id INTEGER NULL,
            emergency_type TEXT NOT NULL DEFAULT 'other',
            injury_type TEXT NOT NULL, injury_detail TEXT NOT NULL DEFAULT 'unknown',
            bleeding_status TEXT NOT NULL,
            consciousness_status TEXT NOT NULL, trapped INTEGER NOT NULL,
            trapped_status TEXT NOT NULL DEFAULT 'unknown', people_affected INTEGER NULL,
            description TEXT NOT NULL, latitude REAL NULL, longitude REAL NULL,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            priority TEXT NULL, status TEXT NOT NULL, sync_status TEXT NOT NULL
          )''');
          await db.execute('''CREATE TABLE message_queue (
            message_id TEXT PRIMARY KEY, emergency_local_id TEXT NOT NULL,
            origin_device_id TEXT NULL, sender_device_id TEXT NULL,
            message_type TEXT NOT NULL, payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL, expires_at TEXT NULL,
            hop_count INTEGER NOT NULL DEFAULT 0, delivery_status TEXT NOT NULL,
            last_attempt_at TEXT NULL
            , attempt_count INTEGER NOT NULL DEFAULT 0
            , last_peer_token TEXT NULL
          )''');
        },
      ),
    );
  });

  tearDownAll(() => testDatabase.close());

  testWidgets('renders the Resilience AI emergency home screen',
      (tester) async {
    final repository =
        EmergencyRepository(AppDatabase(testDatabase: testDatabase));
    await tester.pumpWidget(ResilienceApp(repository: repository));
    await tester.pumpAndSettle();

    expect(find.text('Emergency support'), findsOneWidget);
    expect(find.text('Create SOS'), findsOneWidget);
    expect(find.text('Emergency history (0)'), findsOneWidget);
    expect(find.byTooltip('Refresh emergency list'), findsOneWidget);
  });
}
