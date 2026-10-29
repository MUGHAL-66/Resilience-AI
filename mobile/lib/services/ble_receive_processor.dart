import 'dart:convert';

import '../models/queued_message.dart';
import '../repositories/emergency_repository.dart';
import 'ble_message_protocol.dart';

class ReceivedSos {
  const ReceivedSos(this.message, {required this.duplicate});
  final QueuedMessage message;
  final bool duplicate;
}

/// Reassembles and validates writes before committing a received emergency.
/// Kept independent from platform channels so the receive path is testable.
class BleReceiveProcessor {
  BleReceiveProcessor(this.repository, {BleFrameAssembler? assembler})
      : _assembler = assembler ?? BleFrameAssembler();

  final EmergencyRepository repository;
  final BleFrameAssembler _assembler;

  Future<ReceivedSos?> addFrame(List<int> frame, {DateTime? now}) async {
    final bytes = _assembler.add(frame, now: now);
    if (bytes == null) return null;
    final envelope = BleEmergencyEnvelope.decode(
      utf8.decode(bytes, allowMalformed: false),
      now: now,
    );
    final token = BleFrameCodec.transferToken(envelope.messageId);
    final assembledToken = frame
        .sublist(3, 11)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    if (assembledToken != token) {
      throw const BleProtocolException(
          'Frame token does not match the SOS message ID.');
    }

    final receivedAt = (now ?? DateTime.now()).toUtc();
    final localId = 'received_${envelope.messageId}';
    final emergency = envelope.toEmergencyCase(localId, receivedAt);
    final message = envelope.toQueuedMessage(
      emergencyLocalId: localId,
      deliveryStatus:
          envelope.hopCount >= envelope.maxHops ? 'hop_limit' : 'queued',
    );
    final saved = await repository.saveReceivedMessage(emergency, message);
    return ReceivedSos(message, duplicate: !saved);
  }
}
