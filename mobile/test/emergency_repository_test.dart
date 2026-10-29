import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:resilience_ai/database/app_database.dart';
import 'package:resilience_ai/models/emergency_case.dart';
import 'package:resilience_ai/models/queued_message.dart';
import 'package:resilience_ai/repositories/emergency_repository.dart';
import 'package:resilience_ai/services/ble_message_protocol.dart';
import 'package:resilience_ai/services/ble_receive_processor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late EmergencyRepository repository;
  setUp(() async {
    sqfliteFfiInit();
    database = AppDatabase(
        testDatabase:
            await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
                options: OpenDatabaseOptions(
                    version: 1,
                    onCreate: (db, _) async {
                      await db.execute(
                          "CREATE TABLE emergency_cases (local_id TEXT PRIMARY KEY, server_id INTEGER NULL, emergency_type TEXT NOT NULL DEFAULT 'other', injury_type TEXT NOT NULL, injury_detail TEXT NOT NULL DEFAULT 'unknown', bleeding_status TEXT NOT NULL, consciousness_status TEXT NOT NULL, trapped INTEGER NOT NULL, trapped_status TEXT NOT NULL DEFAULT 'unknown', people_affected INTEGER NULL, description TEXT NOT NULL, latitude REAL NULL, longitude REAL NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, priority TEXT NULL, status TEXT NOT NULL, sync_status TEXT NOT NULL)");
                      await db.execute(
                          "CREATE TABLE message_queue (message_id TEXT PRIMARY KEY, emergency_local_id TEXT NOT NULL, origin_device_id TEXT NULL, sender_device_id TEXT NULL, message_type TEXT NOT NULL, payload_json TEXT NOT NULL, created_at TEXT NOT NULL, expires_at TEXT NULL, hop_count INTEGER NOT NULL, delivery_status TEXT NOT NULL, last_attempt_at TEXT NULL, attempt_count INTEGER NOT NULL DEFAULT 0, last_peer_token TEXT NULL)");
                    })));
    repository = EmergencyRepository(database);
  });
  tearDown(() async => database.testDatabase!.close());

  test('serializes and persists offline emergency records', () async {
    final now = DateTime.utc(2026);
    final value = EmergencyCase(
        localId: 'case-1',
        emergencyType: 'flood',
        injuryType: 'major',
        injuryDetail: 'fracture',
        bleedingStatus: 'unknown',
        consciousnessStatus: 'conscious',
        trapped: true,
        trappedStatus: 'unknown',
        peopleAffected: 3,
        description: 'Water rising',
        createdAt: now,
        updatedAt: now);
    expect(EmergencyCase.fromMap(value.toMap()).localId, value.localId);
    await repository.save(value);
    expect((await repository.findById('case-1'))!.description, 'Water rising');
    expect((await repository.listAll()).single.trapped, isTrue);
    final restored = (await repository.findById('case-1'))!;
    expect(restored.emergencyType, 'flood');
    expect(restored.injuryDetail, 'fracture');
    expect(restored.trappedStatus, 'unknown');
    expect(restored.peopleAffected, 3);
  });

  test('uses unique message ID to reject duplicates', () async {
    final now = DateTime.utc(2026);
    await repository.save(EmergencyCase(
        localId: 'case-2',
        injuryType: 'unknown',
        bleedingStatus: 'unknown',
        consciousnessStatus: 'unknown',
        trapped: false,
        description: '',
        createdAt: now,
        updatedAt: now));
    final message = QueuedMessage(
        messageId: 'msg-1',
        emergencyLocalId: 'case-2',
        messageType: 'emergency.v1',
        payloadJson: '{}',
        createdAt: now);
    expect(await repository.enqueue(message), isTrue);
    expect(await repository.enqueue(message), isFalse);
  });

  test(
      'local SOS save creates an outbound queue entry and retries retain state',
      () async {
    final now = DateTime.now().toUtc();
    final emergency = EmergencyCase(
        localId: 'case-queued',
        injuryType: 'minor',
        bleedingStatus: 'none',
        consciousnessStatus: 'conscious',
        trapped: false,
        description: 'Help',
        createdAt: now,
        updatedAt: now,
        latitude: 24.86,
        longitude: 67.01);
    await repository.save(emergency);
    final queue = await repository.listForwardableMessages();
    expect(queue.single.emergencyLocalId, emergency.localId);
    expect(queue.single.payloadJson, contains('24.86'));
    await repository.updateMessageStatus(queue.single.messageId, 'sending',
        attemptedAt: now, peerToken: 'peer-token');
    final attempted = (await repository.listForwardableMessages()).single;
    expect(attempted.attemptCount, 1);
    expect(attempted.lastPeerToken, 'peer-token');
    await repository.recoverInterruptedMessages();
    expect((await repository.listForwardableMessages()).single.deliveryStatus,
        'failed');
  });

  test(
      'local delivery state follows persisted ACK status and local record deletes safely',
      () async {
    final now = DateTime.now().toUtc();
    final emergency = EmergencyCase(
        localId: 'delete-local',
        injuryType: 'minor',
        bleedingStatus: 'none',
        consciousnessStatus: 'conscious',
        trapped: false,
        description: 'Test',
        createdAt: now,
        updatedAt: now);
    await repository.save(emergency);
    final message = (await repository.listForwardableMessages()).single;
    expect(await repository.deliveryStatusForEmergency(emergency.localId),
        'queued');
    expect(await repository.isLocallyCreated(emergency.localId), isTrue);
    await repository.updateMessageStatus(message.messageId, 'sent',
        attemptedAt: now);
    expect(
        await repository.deliveryStatusForEmergency(emergency.localId), 'sent');
    expect(await repository.deleteLocalEmergency(emergency.localId), isTrue);
    expect(await repository.findById(emergency.localId), isNull);
    expect(
        await repository.deliveryStatusForEmergency(emergency.localId), isNull);
  });

  test('received SOS records cannot be deleted as local test records',
      () async {
    final now = DateTime.now().toUtc();
    final emergency = EmergencyCase(
        localId: 'received-remote-delete',
        injuryType: 'major',
        bleedingStatus: 'severe',
        consciousnessStatus: 'conscious',
        trapped: false,
        description: 'Remote SOS',
        createdAt: now,
        updatedAt: now);
    final message = QueuedMessage(
        messageId: 'remote-delete-message',
        emergencyLocalId: emergency.localId,
        originDeviceId: 'another-device',
        senderDeviceId: 'another-device',
        messageType: 'resilience.sos.v1',
        payloadJson: '{}',
        createdAt: now);
    expect(await repository.saveReceivedMessage(emergency, message), isTrue);
    expect(await repository.isLocallyCreated(emergency.localId), isFalse);
    expect(await repository.deleteLocalEmergency(emergency.localId), isFalse);
    expect(await repository.findById(emergency.localId), isNotNull);
  });

  test(
      'received emergency and forwarding queue entry commit once by message ID',
      () async {
    final now = DateTime.now().toUtc();
    final emergency = EmergencyCase(
        localId: 'received-msg-2',
        injuryType: 'major',
        bleedingStatus: 'severe',
        consciousnessStatus: 'unconscious',
        trapped: false,
        description: 'Need help',
        createdAt: now,
        updatedAt: now,
        latitude: 24.86,
        longitude: 67.01);
    final queued = QueuedMessage(
        messageId: 'msg-2',
        emergencyLocalId: emergency.localId,
        messageType: 'resilience.sos.v1',
        payloadJson: '{}',
        createdAt: now);
    expect(await repository.saveReceivedMessage(emergency, queued), isTrue);
    expect(await repository.saveReceivedMessage(emergency, queued), isFalse);
    expect(
        (await repository.listAll())
            .where((entry) => entry.localId == emergency.localId),
        hasLength(1));
  });

  test('framed SOS transfer persists once and recognizes duplicate delivery',
      () async {
    final now = DateTime.now().toUtc();
    final envelope = BleEmergencyEnvelope(
      messageId: 'radio-message-1',
      emergencyId: 'origin-1',
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
      hopCount: 1,
      maxHops: 8,
      emergency: const {
        'injuryType': 'major',
        'bleedingStatus': 'severe',
        'consciousnessStatus': 'conscious',
        'trapped': false,
        'description': 'Radio receive test',
        'latitude': 24.86,
        'longitude': 67.01,
        'status': 'open',
      },
    );
    final encoded = utf8.encode(envelope.encode());
    final frames = BleFrameCodec.encode(envelope.messageId, encoded, 23);
    expect(
      frames.first
          .sublist(3, 11)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      BleFrameCodec.transferToken(envelope.messageId),
    );
    final processor = BleReceiveProcessor(repository);
    ReceivedSos? received;
    for (final frame in frames) {
      received = await processor.addFrame(frame, now: now);
    }
    expect(received?.duplicate, isFalse);
    expect((await repository.findById('received_radio-message-1'))?.latitude,
        24.86);
    expect((await repository.listForwardableMessages()).single.messageId,
        envelope.messageId);
    for (final frame in frames) {
      received = await processor.addFrame(frame, now: now);
    }
    expect(received?.duplicate, isTrue);
    expect(
        (await repository.listAll())
            .where((value) => value.localId == 'received_radio-message-1'),
        hasLength(1));
  });

  test('failed send retry retains its payload and hop count', () async {
    final now = DateTime.now().toUtc();
    final envelope = BleEmergencyEnvelope(
      messageId: 'retry-message',
      emergencyId: 'origin-retry',
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
      hopCount: 0,
      maxHops: 8,
      emergency: const {
        'injuryType': 'minor',
        'bleedingStatus': 'none',
        'consciousnessStatus': 'conscious',
        'trapped': false,
        'description': '',
      },
    );
    final local = EmergencyCase(
      localId: 'retry-local',
      injuryType: 'minor',
      bleedingStatus: 'none',
      consciousnessStatus: 'conscious',
      trapped: false,
      description: '',
      createdAt: now,
      updatedAt: now,
    );
    await repository.save(local);
    final queued = envelope.toQueuedMessage(emergencyLocalId: local.localId);
    await repository.enqueue(queued);
    await repository.updateMessageStatus(queued.messageId, 'failed',
        attemptedAt: now);
    final retry = (await repository.listForwardableMessages())
        .singleWhere((item) => item.messageId == queued.messageId);
    expect(retry.payloadJson, queued.payloadJson);
    expect(BleEmergencyEnvelope.decode(retry.payloadJson).hopCount, 0);
  });

  test('failed transfers stay retryable until an ACK marks them delivered',
      () async {
    final now = DateTime.now().toUtc();
    final emergency = EmergencyCase(
      localId: 'ack-state-local',
      injuryType: 'unknown',
      bleedingStatus: 'unknown',
      consciousnessStatus: 'unknown',
      trapped: false,
      description: '',
      createdAt: now,
      updatedAt: now,
    );
    await repository.save(emergency);
    final message = (await repository.listForwardableMessages()).single;

    await repository.updateMessageStatus(message.messageId, 'sending',
        attemptedAt: now);
    await repository.updateMessageStatus(message.messageId, 'failed',
        attemptedAt: now);
    expect(await repository.deliveryStatusForEmergency(emergency.localId),
        'failed');
    expect((await repository.listForwardableMessages()).single.messageId,
        message.messageId);

    await repository.updateMessageStatus(message.messageId, 'queued');
    expect(await repository.deliveryStatusForEmergency(emergency.localId),
        'queued');
    await repository.updateMessageStatus(message.messageId, 'sending');
    expect(await repository.deliveryStatusForEmergency(emergency.localId),
        'sending');
    await repository.updateMessageStatus(message.messageId, 'sent',
        attemptedAt: now);
    expect(
        await repository.deliveryStatusForEmergency(emergency.localId), 'sent');
    expect(await repository.listForwardableMessages(), isEmpty);
  });

  test('reopens origin messages exhausted by the old retry hop bug', () async {
    final now = DateTime.now().toUtc();
    final deviceId = await database.getOrCreateDeviceId();
    final emergency = EmergencyCase(
      localId: 'legacy-origin',
      injuryType: 'minor',
      bleedingStatus: 'none',
      consciousnessStatus: 'conscious',
      trapped: false,
      description: '',
      createdAt: now,
      updatedAt: now,
    );
    await repository.save(emergency);
    var envelope = BleEmergencyEnvelope.decode(
        (await repository.listForwardableMessages()).single.payloadJson);
    for (var i = 0; i < envelope.maxHops; i++) {
      envelope = envelope.forward(senderDeviceId: deviceId);
    }
    final exhausted = envelope.toQueuedMessage(
        emergencyLocalId: emergency.localId, deliveryStatus: 'hop_limit');
    await repository.updateForwardingEnvelope(exhausted);
    await repository.updateMessageStatus(exhausted.messageId, 'hop_limit');

    expect(await repository.recoverLocalOutgoingRetries(deviceId), 1);
    final recovered = (await repository.listForwardableMessages()).single;
    expect(recovered.messageId, exhausted.messageId);
    expect(recovered.deliveryStatus, 'queued');
    expect(BleEmergencyEnvelope.decode(recovered.payloadJson).hopCount, 0);
  });

  test('incoming frame token must belong to the decoded SOS ID', () async {
    final now = DateTime.now().toUtc();
    final envelope = BleEmergencyEnvelope(
      messageId: 'actual-message',
      emergencyId: 'actual-emergency',
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
      hopCount: 1,
      maxHops: 8,
      emergency: const {
        'injuryType': 'unknown',
        'bleedingStatus': 'unknown',
        'consciousnessStatus': 'unknown',
        'trapped': false,
        'description': '',
      },
    );
    final frames = BleFrameCodec.encode(
        'different-frame-id', utf8.encode(envelope.encode()), 247);
    final processor = BleReceiveProcessor(repository);
    await expectLater(() async {
      for (final frame in frames) {
        await processor.addFrame(frame, now: now);
      }
    }, throwsA(isA<BleProtocolException>()));
    expect(await repository.findById('received_actual-message'), isNull);
  });
}
