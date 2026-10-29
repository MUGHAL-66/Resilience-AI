import 'dart:developer' as developer;

import 'package:sqflite/sqflite.dart';
import '../database/app_database.dart';
import '../models/emergency_case.dart';
import '../models/queued_message.dart';
import '../services/ble_message_protocol.dart';

abstract interface class EmergencyStore {
  Future<void> save(EmergencyCase emergency);
  Future<EmergencyCase?> findById(String localId);
  Future<List<EmergencyCase>> listAll();
}

abstract interface class MessageQueueStore {
  /// Returns false when this message ID has already been processed.
  Future<bool> enqueue(QueuedMessage message);
}

class EmergencyRepository implements EmergencyStore, MessageQueueStore {
  EmergencyRepository(this.database);
  final AppDatabase database;

  @override
  Future<void> save(EmergencyCase emergency) async {
    final db = await database.database;
    await db.insert('emergency_cases', emergency.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    final deviceId = await database.getOrCreateDeviceId();
    try {
      final message = BleEmergencyEnvelope.fromEmergency(
        emergency,
        messageId: 'sos_${emergency.localId}',
        originDeviceId: deviceId,
        senderDeviceId: deviceId,
      ).toQueuedMessage(emergencyLocalId: emergency.localId);
      final inserted = await enqueue(message);
      developer.log(
          'message.queue.inserted id=${message.messageId} inserted=$inserted',
          name: 'resilience.ble');
    } on BleProtocolException {
      // An already expired historical record stays locally saved but is not
      // placed on the radio forwarding queue.
    }
  }

  @override
  Future<EmergencyCase?> findById(String localId) async {
    final rows = await (await database.database).query('emergency_cases',
        where: 'local_id = ?', whereArgs: [localId], limit: 1);
    return rows.isEmpty ? null : EmergencyCase.fromMap(rows.first);
  }

  @override
  Future<List<EmergencyCase>> listAll() async =>
      (await (await database.database)
              .query('emergency_cases', orderBy: 'created_at DESC'))
          .map(EmergencyCase.fromMap)
          .toList();

  Future<int> update(EmergencyCase value) async =>
      (await database.database).update('emergency_cases', value.toMap(),
          where: 'local_id = ?', whereArgs: [value.localId]);
  Future<void> markSynced(String localId, int serverId) async {
    await (await database.database).update(
        'emergency_cases',
        {
          'server_id': serverId,
          'sync_status': 'synced',
          'updated_at': DateTime.now().toUtc().toIso8601String()
        },
        where: 'local_id = ?',
        whereArgs: [localId]);
  }

  @override
  Future<bool> enqueue(QueuedMessage message) async {
    final db = await database.database;
    try {
      await db.insert('message_queue', message.toMap(),
          conflictAlgorithm: ConflictAlgorithm.abort);
      return true;
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) return false;
      rethrow;
    }
  }

  Future<List<QueuedMessage>> listForwardableMessages() async {
    final rows = await (await database.database).query(
      'message_queue',
      where: "delivery_status IN ('queued', 'failed', 'sending')",
      orderBy: 'created_at ASC',
    );
    return rows.map(QueuedMessage.fromMap).toList();
  }

  Future<void> recoverInterruptedMessages() async {
    await (await database.database).update(
      'message_queue',
      {'delivery_status': 'failed'},
      where: "delivery_status = 'sending'",
    );
  }

  /// Repairs origin messages exhausted by pre-ACK hop increments in older
  /// builds. Their stable IDs still deduplicate any copy already received.
  Future<int> recoverLocalOutgoingRetries(String deviceId) async {
    final db = await database.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'message_queue',
        where:
            "origin_device_id = ? AND delivery_status IN ('failed', 'sending', 'hop_limit')",
        whereArgs: [deviceId],
      );
      var recovered = 0;
      for (final row in rows) {
        final message = QueuedMessage.fromMap(row);
        try {
          final original = BleEmergencyEnvelope.decode(message.payloadJson)
              .retryFromOrigin();
          await txn.update(
            'message_queue',
            {
              'payload_json': original.encode(),
              'sender_device_id': original.senderDeviceId,
              'hop_count': 0,
              'delivery_status': 'queued',
            },
            where: 'message_id = ?',
            whereArgs: [message.messageId],
          );
          recovered++;
        } on BleProtocolException {
          await txn.update(
            'message_queue',
            {'delivery_status': 'expired'},
            where: 'message_id = ?',
            whereArgs: [message.messageId],
          );
        }
      }
      return recovered;
    });
  }

  Future<int> updateMessageStatus(String messageId, String status,
      {DateTime? attemptedAt, String? peerToken}) async {
    final db = await database.database;
    return db.rawUpdate(
      '''UPDATE message_queue
         SET delivery_status = ?,
             last_attempt_at = ?,
             attempt_count = attempt_count + CASE WHEN ? = 'sending' THEN 1 ELSE 0 END,
             last_peer_token = CASE WHEN ? IS NULL THEN last_peer_token ELSE ? END
         WHERE message_id = ?''',
      [
        status,
        attemptedAt?.toUtc().toIso8601String(),
        status,
        peerToken,
        peerToken,
        messageId,
      ],
    );
  }

  Future<int> updateForwardingEnvelope(QueuedMessage message) async =>
      (await database.database).update(
        'message_queue',
        {
          'payload_json': message.payloadJson,
          'hop_count': message.hopCount,
          'sender_device_id': message.senderDeviceId,
        },
        where: 'message_id = ?',
        whereArgs: [message.messageId],
      );

  /// Current radio delivery state for the queue entry attached to a local row.
  Future<String?> deliveryStatusForEmergency(String emergencyLocalId) async {
    final rows = await (await database.database).query(
      'message_queue',
      columns: ['delivery_status'],
      where: 'emergency_local_id = ?',
      whereArgs: [emergencyLocalId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['delivery_status'] as String;
  }

  Future<String?> messageIdForEmergency(String emergencyLocalId) async {
    final rows = await (await database.database).query(
      'message_queue',
      columns: ['message_id'],
      where: 'emergency_local_id = ?',
      whereArgs: [emergencyLocalId],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['message_id'] as String;
  }

  Future<bool> isLocallyCreated(String emergencyLocalId) async {
    final deviceId = await database.getOrCreateDeviceId();
    final rows = await (await database.database).query(
      'message_queue',
      columns: ['message_id'],
      where: 'emergency_local_id = ? AND origin_device_id = ?',
      whereArgs: [emergencyLocalId, deviceId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Requeues only a locally originated SOS. Received SOS records are immutable
  /// through the local test-record delete action.
  Future<bool> deleteLocalEmergency(String emergencyLocalId) async {
    final db = await database.database;
    final deviceId = await database.getOrCreateDeviceId();
    return db.transaction((txn) async {
      final rows = await txn.query(
        'message_queue',
        columns: ['origin_device_id'],
        where: 'emergency_local_id = ?',
        whereArgs: [emergencyLocalId],
        limit: 1,
      );
      if (rows.isEmpty || rows.single['origin_device_id'] != deviceId) {
        return false;
      }
      await txn.delete('message_queue',
          where: 'emergency_local_id = ?', whereArgs: [emergencyLocalId]);
      await txn.delete('emergency_cases',
          where: 'local_id = ?', whereArgs: [emergencyLocalId]);
      return true;
    });
  }

  Future<bool> requeueLocalEmergency(String emergencyLocalId) async {
    final db = await database.database;
    final deviceId = await database.getOrCreateDeviceId();
    final count = await db.rawUpdate(
      "UPDATE message_queue SET delivery_status = 'queued' "
      "WHERE emergency_local_id = ? AND origin_device_id = ? "
      "AND delivery_status <> 'sent'",
      [emergencyLocalId, deviceId],
    );
    return count > 0;
  }

  /// Saves a received SOS and its forwarding queue entry in one transaction.
  /// Returns false when this stable protocol message ID was already received.
  Future<bool> saveReceivedMessage(
      EmergencyCase emergency, QueuedMessage message) async {
    final db = await database.database;
    return db.transaction((txn) async {
      final duplicate = await txn.query(
        'message_queue',
        columns: ['message_id'],
        where: 'message_id = ?',
        whereArgs: [message.messageId],
        limit: 1,
      );
      if (duplicate.isNotEmpty) return false;

      await txn.insert('emergency_cases', emergency.toMap(),
          conflictAlgorithm: ConflictAlgorithm.abort);
      await txn.insert('message_queue', message.toMap(),
          conflictAlgorithm: ConflictAlgorithm.abort);
      developer.log('message.persisted id=${message.messageId} duplicate=false',
          name: 'resilience.ble');
      return true;
    });
  }
}
