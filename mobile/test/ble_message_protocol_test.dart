import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ble_central/flutter_ble_central.dart';
import 'package:resilience_ai/models/emergency_case.dart';
import 'package:resilience_ai/services/ble_message_protocol.dart';
import 'package:resilience_ai/services/ble_transport.dart';

void main() {
  final now = DateTime.now().toUtc();
  BleEmergencyEnvelope sample({int hop = 0, DateTime? expiry}) =>
      BleEmergencyEnvelope(
        messageId: 'msg-1',
        emergencyId: 'case-1',
        originDeviceId: 'device-a',
        senderDeviceId: 'device-b',
        createdAt: now,
        expiresAt: expiry ?? now.add(const Duration(hours: 2)),
        hopCount: hop,
        maxHops: 3,
        emergency: const {
          'emergencyType': 'flood',
          'injuryType': 'major',
          'injuryDetail': 'fracture',
          'bleedingStatus': 'severe',
          'consciousnessStatus': 'conscious',
          'trapped': false,
          'trappedStatus': 'unknown',
          'peopleAffected': 2,
          'description': 'Needs help',
          'latitude': 24.86,
          'longitude': 67.01,
          'priority': 'high',
          'status': 'open',
        },
      );

  test('round trips a versioned SOS including GPS', () {
    final envelope = sample();
    final decoded = BleEmergencyEnvelope.decode(envelope.encode(), now: now);
    expect(decoded.messageId, 'msg-1');
    expect(decoded.emergency['latitude'], 24.86);
    expect(decoded.emergency['emergencyType'], 'flood');
    expect(decoded.emergency['injuryDetail'], 'fracture');
    expect(decoded.emergency['peopleAffected'], 2);
    expect(decoded.version, BleEmergencyEnvelope.currentVersion);
  });

  test('rejects oversized, malformed, unsupported and invalid envelopes', () {
    expect(() => BleEmergencyEnvelope.decode('x' * 9000),
        throwsA(isA<BleProtocolException>()));
    expect(() => BleEmergencyEnvelope.decode('{'),
        throwsA(isA<BleProtocolException>()));
    final unsupported = jsonDecode(sample().encode()) as Map<String, dynamic>;
    unsupported['version'] = 99;
    expect(() => BleEmergencyEnvelope.decode(jsonEncode(unsupported), now: now),
        throwsA(isA<BleProtocolException>()));
    final invalid = sample().toJson()
      ..['emergency'] = {'latitude': 120, 'longitude': 20};
    expect(() => BleEmergencyEnvelope.decode(jsonEncode(invalid), now: now),
        throwsA(isA<BleProtocolException>()));
    final future = sample().toJson()
      ..['createdAt'] = now.add(const Duration(hours: 1)).toIso8601String();
    expect(() => BleEmergencyEnvelope.decode(jsonEncode(future), now: now),
        throwsA(isA<BleProtocolException>()));
  });

  test('rejects expired envelopes and enforces the hop limit', () {
    expect(
        () => BleEmergencyEnvelope.decode(
            jsonEncode(sample(expiry: now).toJson()),
            now: now),
        throwsA(isA<BleProtocolException>()));
    expect(() => sample(hop: 3).forward(senderDeviceId: 'device-c'),
        throwsA(isA<BleProtocolException>()));
    expect(sample(hop: 1).forward(senderDeviceId: 'device-c').hopCount, 2);
  });

  test('converts received payload into a local emergency with GPS', () {
    final emergency = sample().toEmergencyCase('received_msg-1', now);
    expect(emergency.localId, 'received_msg-1');
    expect(emergency.latitude, 24.86);
    expect(emergency.syncStatus, 'pending');
    expect(emergency.emergencyType, 'flood');
    expect(emergency.injuryDetail, 'fracture');
    expect(emergency.trappedStatus, 'unknown');
    expect(emergency.peopleAffected, 2);
  });

  test('creates envelope from a local emergency', () {
    final emergency = EmergencyCase(
      localId: 'local-1',
      injuryType: 'minor',
      bleedingStatus: 'none',
      consciousnessStatus: 'conscious',
      trapped: false,
      description: '',
      latitude: 1,
      longitude: 2,
      createdAt: now,
      updatedAt: now,
    );
    expect(
        BleEmergencyEnvelope.fromEmergency(emergency, messageId: 'message-1')
            .emergency['latitude'],
        1);
  });

  test('selects a writable RX and notifying TX GATT characteristic', () {
    final layout = BleGattLayout.select([
      GattService(
        uuid: sosServiceUuid,
        isPrimary: true,
        characteristics: [
          GattCharacteristic(
            uuid: sosRxUuid,
            serviceUuid: sosServiceUuid,
            properties: GattCharacteristicProperties(write: true),
          ),
          GattCharacteristic(
            uuid: sosTxUuid,
            serviceUuid: sosServiceUuid,
            properties: GattCharacteristicProperties(notify: true),
          ),
        ],
      ),
    ]);
    expect(layout.writeWithoutResponse, isFalse);
  });

  test('uses write without response only when that is the peer RX capability',
      () {
    final layout = BleGattLayout.select([
      GattService(
        uuid: sosServiceUuid,
        isPrimary: true,
        characteristics: [
          GattCharacteristic(
            uuid: sosRxUuid,
            serviceUuid: sosServiceUuid,
            properties:
                GattCharacteristicProperties(writeWithoutResponse: true),
          ),
          GattCharacteristic(
            uuid: sosTxUuid,
            serviceUuid: sosServiceUuid,
            properties: GattCharacteristicProperties(notify: true),
          ),
        ],
      ),
    ]);
    expect(layout.writeWithoutResponse, isTrue);
  });

  test('rejects a GATT layout that cannot receive writes', () {
    expect(
      () => BleGattLayout.select([
        GattService(
          uuid: sosServiceUuid,
          isPrimary: true,
          characteristics: [
            GattCharacteristic(
              uuid: sosRxUuid,
              serviceUuid: sosServiceUuid,
              properties: GattCharacteristicProperties(read: true),
            ),
          ],
        ),
      ]),
      throwsA(isA<StateError>()),
    );
  });

  test('peer identity elects exactly one central in both views', () {
    final first = BlePeerIdentity.tokenFor('device-alpha');
    final second = BlePeerIdentity.tokenFor('device-beta');
    expect(
        BlePeerIdentity.tokenFrom({
          BlePeerIdentity.manufacturerId:
              BlePeerIdentity.advertisementData('device-alpha'),
        }),
        first);
    expect(
      BlePeerIdentity.shouldInitiate(localToken: first, peerToken: second),
      isNot(
          BlePeerIdentity.shouldInitiate(localToken: second, peerToken: first)),
    );
  });

  test('reassembles out-of-order frames and rejects corrupt frames', () {
    final bytes = List<int>.generate(31, (index) => index);
    final frames = BleFrameCodec.encode('frame-order', bytes, 23);
    final assembler = BleFrameAssembler();
    expect(assembler.add(frames.last), isNull);
    for (final frame in frames.reversed.skip(1)) {
      final assembled = assembler.add(frame);
      if (assembled != null) expect(assembled, bytes);
    }
    expect(
      () => assembler.add([0, 0, 0]),
      throwsA(isA<BleProtocolException>()),
    );
  });

  test('rejects payload corruption even when damaged bytes still look valid',
      () {
    final frames =
        BleFrameCodec.encode('crc-message', List<int>.filled(40, 7), 247);
    final damaged = List<int>.from(frames.single)
      ..[BleFrameCodec.headerSize] ^= 1;
    expect(() => BleFrameAssembler().add(damaged),
        throwsA(isA<BleProtocolException>()));
  });

  test('negotiates protocol version before transferring payloads', () {
    expect(BleFrameCodec.isCapabilityRequest(BleFrameCodec.capabilityRequest()),
        isTrue);
    expect(
        BleFrameCodec.isCapabilityResponse(BleFrameCodec.capabilityResponse()),
        isTrue);
    expect(
        BleFrameCodec.isCapabilityResponse(BleFrameCodec.capabilityRequest()),
        isFalse);
  });

  test('peripheral notification receipt matches its exact frame', () {
    final frames = BleFrameCodec.encode(
        'receipt-message', List<int>.generate(20, (index) => index), 23);
    final frame = frames.first;
    final receipt = BleFrameCodec.notificationReceipt(frame);
    expect(BleFrameCodec.isNotificationReceipt(receipt), isTrue);
    expect(BleFrameCodec.notificationReceiptKey(receipt),
        BleFrameCodec.dataFrameReceiptKey(frame));
    expect(BleFrameCodec.dataFrameReceiptKey(frame),
        '${BleFrameCodec.transferToken('receipt-message')}:0');
    expect(BleFrameCodec.notificationReceiptKey(receipt),
        isNot(BleFrameCodec.dataFrameReceiptKey(frames[1])));
    expect(BleFrameCodec.isNotificationReceipt(frame), isFalse);
  });

  test('bounds retry backoff and adds caller-supplied jitter', () {
    expect(BleRetryBackoff.delay(1, jitterMilliseconds: 125),
        const Duration(milliseconds: 1125));
    expect(BleRetryBackoff.delay(5, jitterMilliseconds: 999),
        const Duration(milliseconds: 16999));
    expect(() => BleRetryBackoff.delay(6, jitterMilliseconds: 0),
        throwsRangeError);
  });

  test('transfer completion is distinct from acknowledgement and data frames',
      () {
    final done = BleFrameCodec.transferComplete();
    final queueRequest = BleFrameCodec.requestPeerQueue();
    expect(BleFrameCodec.isTransferComplete(done), isTrue);
    expect(BleFrameCodec.isPeerQueueRequest(queueRequest), isTrue);
    expect(BleFrameCodec.isAcknowledgementFrame(done), isFalse);
    expect(BleFrameCodec.isTransferComplete(queueRequest), isFalse);
    expect(
        BleFrameCodec.isAcknowledgementFrame(
            BleFrameCodec.acknowledgement('msg-1')),
        isTrue);
  });

  test('ACK only matches the message ID whose transfer is awaiting receipt',
      () {
    final acknowledgement = BleFrameCodec.acknowledgement('msg-1');
    expect(BleFrameCodec.isAcknowledgementFrame(acknowledgement), isTrue);
    expect(BleFrameCodec.isAcknowledgement(acknowledgement, 'msg-1'), isTrue);
    expect(BleFrameCodec.isAcknowledgement(acknowledgement, 'msg-2'), isFalse);
    expect(
        BleFrameCodec.isAcknowledgement(
            BleFrameCodec.acknowledgement('msg-2'), 'msg-1'),
        isFalse);
  });
}
