import 'dart:convert';
import 'dart:typed_data';

import '../models/emergency_case.dart';
import '../models/queued_message.dart';

class BleProtocolException implements Exception {
  const BleProtocolException(this.message);
  final String message;

  @override
  String toString() => 'BleProtocolException: $message';
}

/// Compact identity carried in Android manufacturer data so both peers elect
/// the same central instead of racing to connect to one another.
class BlePeerIdentity {
  static const manufacturerId = 0xffff;
  static const tokenBytes = 5;

  static String tokenFor(String deviceId) =>
      BleFrameCodec.transferToken(deviceId).substring(0, tokenBytes * 2);

  static Uint8List advertisementData(String deviceId) {
    final token = tokenFor(deviceId);
    return Uint8List.fromList(List<int>.generate(
      tokenBytes,
      (index) =>
          int.parse(token.substring(index * 2, index * 2 + 2), radix: 16),
    ));
  }

  static String? tokenFrom(Map<int, Uint8List>? manufacturerData) {
    final bytes = manufacturerData?[manufacturerId];
    if (bytes == null || bytes.length != tokenBytes) return null;
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool shouldInitiate(
          {required String localToken, required String peerToken}) =>
      localToken.compareTo(peerToken) < 0;
}

/// A versioned, bounded SOS envelope. Descriptions and triage fields are the
/// only user-authored payload; no device secrets or account data are included.
class BleEmergencyEnvelope {
  const BleEmergencyEnvelope({
    required this.messageId,
    required this.emergencyId,
    required this.createdAt,
    required this.expiresAt,
    required this.hopCount,
    required this.maxHops,
    required this.emergency,
    this.originDeviceId,
    this.senderDeviceId,
    this.version = currentVersion,
  });

  static const currentVersion = 2;
  static const minimumReadableVersion = 1;
  static const maxPayloadBytes = 8192;
  static const defaultMaxHops = 8;
  static const ttl = Duration(hours: 24);

  final int version;
  final String messageId;
  final String emergencyId;
  final String? originDeviceId;
  final String? senderDeviceId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int hopCount;
  final int maxHops;
  final Map<String, Object?> emergency;

  factory BleEmergencyEnvelope.fromEmergency(
    EmergencyCase value, {
    required String messageId,
    String? originDeviceId,
    String? senderDeviceId,
    DateTime? expiresAt,
  }) =>
      BleEmergencyEnvelope(
        messageId: messageId,
        emergencyId: value.localId,
        originDeviceId: originDeviceId,
        senderDeviceId: senderDeviceId,
        createdAt: value.createdAt.toUtc(),
        expiresAt: (expiresAt ?? value.createdAt.toUtc().add(ttl)).toUtc(),
        hopCount: 0,
        maxHops: defaultMaxHops,
        emergency: {
          'emergencyType': value.emergencyType,
          'injuryType': value.injuryType,
          'injuryDetail': value.injuryDetail,
          'bleedingStatus': value.bleedingStatus,
          'consciousnessStatus': value.consciousnessStatus,
          'trapped': value.trapped,
          'trappedStatus': value.trappedStatus,
          'peopleAffected': value.peopleAffected,
          'description': value.description,
          'latitude': value.latitude,
          'longitude': value.longitude,
          'priority': value.priority,
          'status': value.status,
        },
      );

  BleEmergencyEnvelope forward({required String? senderDeviceId}) {
    if (hopCount >= maxHops) {
      throw const BleProtocolException('Message reached its hop limit.');
    }
    if (!expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const BleProtocolException('Message has expired.');
    }
    return BleEmergencyEnvelope(
      version: currentVersion,
      messageId: messageId,
      emergencyId: emergencyId,
      originDeviceId: originDeviceId,
      senderDeviceId: senderDeviceId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hopCount: hopCount + 1,
      maxHops: maxHops,
      emergency: emergency,
    );
  }

  /// Rebuilds an unsent origin message after older retry code consumed hops
  /// before delivery was acknowledged. Stable IDs make receiver dedup safe.
  BleEmergencyEnvelope retryFromOrigin() {
    if (originDeviceId == null) {
      throw const BleProtocolException(
          'Cannot reset a forwarded message without its origin device.');
    }
    return BleEmergencyEnvelope(
      version: currentVersion,
      messageId: messageId,
      emergencyId: emergencyId,
      originDeviceId: originDeviceId,
      senderDeviceId: originDeviceId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hopCount: 0,
      maxHops: maxHops,
      emergency: emergency,
    );
  }

  Map<String, Object?> toJson() => {
        'version': version,
        'messageId': messageId,
        'emergencyId': emergencyId,
        'originDeviceId': originDeviceId,
        'senderDeviceId': senderDeviceId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'hopCount': hopCount,
        'maxHops': maxHops,
        'emergency': emergency,
      };

  String encode() {
    validate(DateTime.now().toUtc());
    final encoded = jsonEncode(toJson());
    if (utf8.encode(encoded).length > maxPayloadBytes) {
      throw const BleProtocolException('Message exceeds the size limit.');
    }
    return encoded;
  }

  factory BleEmergencyEnvelope.decode(
    String raw, {
    DateTime? now,
  }) {
    if (utf8.encode(raw).length > maxPayloadBytes) {
      throw const BleProtocolException('Message exceeds the size limit.');
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const BleProtocolException('Message must be a JSON object.');
      }
      final createdAt = DateTime.parse(decoded['createdAt'] as String).toUtc();
      final expiresAt = DateTime.parse(decoded['expiresAt'] as String).toUtc();
      final emergencyRaw = decoded['emergency'];
      if (emergencyRaw is! Map<String, dynamic>) {
        throw const BleProtocolException('Emergency payload is invalid.');
      }
      final emergency = Map<String, Object?>.from(emergencyRaw);
      final value = BleEmergencyEnvelope(
        version: decoded['version'] as int,
        messageId: decoded['messageId'] as String,
        emergencyId: decoded['emergencyId'] as String,
        originDeviceId: decoded['originDeviceId'] as String?,
        senderDeviceId: decoded['senderDeviceId'] as String?,
        createdAt: createdAt,
        expiresAt: expiresAt,
        hopCount: decoded['hopCount'] as int,
        maxHops: decoded['maxHops'] as int,
        emergency: emergency,
      );
      value.validate((now ?? DateTime.now()).toUtc());
      return value;
    } on BleProtocolException {
      rethrow;
    } catch (_) {
      throw const BleProtocolException('Message is malformed.');
    }
  }

  void validate(DateTime now) {
    if (version < minimumReadableVersion || version > currentVersion) {
      throw const BleProtocolException('Unsupported protocol version.');
    }
    if (!_validId(messageId) || !_validId(emergencyId)) {
      throw const BleProtocolException('Message identifiers are invalid.');
    }
    if ((originDeviceId != null && !_validId(originDeviceId!)) ||
        (senderDeviceId != null && !_validId(senderDeviceId!))) {
      throw const BleProtocolException('Device identifier is invalid.');
    }
    if (maxHops < 1 ||
        maxHops > defaultMaxHops ||
        hopCount < 0 ||
        hopCount > maxHops) {
      throw const BleProtocolException('Message exceeds the hop limit.');
    }
    if (!expiresAt.isAfter(createdAt) || !expiresAt.isAfter(now)) {
      throw const BleProtocolException(
          'Message has expired or has invalid dates.');
    }
    if (createdAt.isAfter(now.add(const Duration(minutes: 5)))) {
      throw const BleProtocolException(
          'Message creation time is in the future.');
    }
    final age = expiresAt.difference(createdAt);
    if (age > const Duration(days: 7)) {
      throw const BleProtocolException(
          'Message expiry is outside the allowed window.');
    }
    final fields = emergency;
    final emergencyType = fields['emergencyType'];
    final injury = fields['injuryType'];
    final bleeding = fields['bleedingStatus'];
    final consciousness = fields['consciousnessStatus'];
    final description = fields['description'];
    if ((emergencyType != null &&
            (emergencyType is! String ||
                !{'other', 'flood', 'earthquake', 'medical', 'trapped_other'}
                    .contains(emergencyType))) ||
        injury is! String ||
        !{
          'none',
          'minor',
          'major',
          'unknown',
        }.contains(injury) ||
        bleeding is! String ||
        !{'none', 'minor', 'severe', 'unknown'}.contains(bleeding) ||
        consciousness is! String ||
        !{'conscious', 'unconscious', 'unknown'}.contains(consciousness) ||
        fields['trapped'] is! bool ||
        description is! String ||
        description.length > 2000) {
      throw const BleProtocolException('Emergency fields are invalid.');
    }
    final injuryDetail = fields['injuryDetail'];
    if (injuryDetail != null &&
        (injuryDetail is! String ||
            !{
              'fracture',
              'wound',
              'breathing_difficulty',
              'other',
              'unknown',
            }.contains(injuryDetail))) {
      throw const BleProtocolException('Emergency injury detail is invalid.');
    }
    final trappedStatus = fields['trappedStatus'];
    final peopleAffected = fields['peopleAffected'];
    if ((trappedStatus != null &&
            (trappedStatus is! String ||
                !{'yes', 'no', 'unknown'}.contains(trappedStatus))) ||
        (peopleAffected != null &&
            (peopleAffected is! int ||
                peopleAffected < 1 ||
                peopleAffected > 999))) {
      throw const BleProtocolException(
          'Emergency response details are invalid.');
    }
    final latitude = fields['latitude'];
    final longitude = fields['longitude'];
    if ((latitude == null) != (longitude == null) ||
        (latitude != null &&
            (latitude is! num || latitude < -90 || latitude > 90)) ||
        (longitude != null &&
            (longitude is! num || longitude < -180 || longitude > 180))) {
      throw const BleProtocolException('Emergency coordinates are invalid.');
    }
    final priority = fields['priority'];
    if (priority != null && (priority is! String || priority.length > 32)) {
      throw const BleProtocolException('Emergency priority is invalid.');
    }
    final status = fields['status'];
    if (status != null && status != 'open') {
      throw const BleProtocolException('Emergency status is invalid.');
    }
  }

  EmergencyCase toEmergencyCase(String localId, DateTime receivedAt) =>
      EmergencyCase(
        localId: localId,
        emergencyType: emergency['emergencyType'] as String? ?? 'other',
        injuryType: emergency['injuryType']! as String,
        injuryDetail: emergency['injuryDetail'] as String? ?? 'unknown',
        bleedingStatus: emergency['bleedingStatus']! as String,
        consciousnessStatus: emergency['consciousnessStatus']! as String,
        trapped: emergency['trapped']! as bool,
        trappedStatus: emergency['trappedStatus'] as String? ??
            ((emergency['trapped']! as bool) ? 'yes' : 'no'),
        peopleAffected: emergency['peopleAffected'] as int?,
        description: emergency['description']! as String,
        latitude: (emergency['latitude'] as num?)?.toDouble(),
        longitude: (emergency['longitude'] as num?)?.toDouble(),
        createdAt: createdAt.toUtc(),
        updatedAt: receivedAt.toUtc(),
        priority: emergency['priority'] as String?,
        status: emergency['status'] as String? ?? 'open',
        syncStatus: 'pending',
      );

  QueuedMessage toQueuedMessage({
    required String emergencyLocalId,
    String deliveryStatus = 'queued',
  }) =>
      QueuedMessage(
        messageId: messageId,
        emergencyLocalId: emergencyLocalId,
        originDeviceId: originDeviceId,
        senderDeviceId: senderDeviceId,
        messageType: 'resilience.sos.v1',
        payloadJson: encode(),
        createdAt: createdAt,
        expiresAt: expiresAt,
        hopCount: hopCount,
        deliveryStatus: deliveryStatus,
      );

  static bool _validId(String value) =>
      value.isNotEmpty &&
      value.length <= 128 &&
      RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);
}

/// Splits JSON into bounded GATT writes and reassembles partial writes.
class BleFrameCodec {
  static const headerSize = 15;
  static const currentFrameVersion = 2;
  static const currentProtocolVersion = BleEmergencyEnvelope.currentVersion;
  static const maximumFrames = 2048;
  static final BigInt _mask64 = BigInt.parse('ffffffffffffffff', radix: 16);

  static String transferToken(String messageId) {
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    for (final byte in utf8.encode(messageId)) {
      hash = ((hash ^ BigInt.from(byte)) * prime) & _mask64;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static List<Uint8List> encode(String messageId, List<int> bytes, int mtu) {
    if (bytes.isEmpty || bytes.length > BleEmergencyEnvelope.maxPayloadBytes) {
      throw const BleProtocolException('Invalid transfer size.');
    }
    final payloadWithChecksum = <int>[
      ...bytes,
      ..._checksum32(bytes),
    ];
    final token = transferToken(messageId);
    final tokenBytes = List<int>.generate(
        8,
        (index) =>
            int.parse(token.substring(index * 2, index * 2 + 2), radix: 16));
    final chunkLength = (mtu - 3 - headerSize).clamp(1, 512 - headerSize);
    final total = (payloadWithChecksum.length / chunkLength).ceil();
    if (total > maximumFrames) {
      throw const BleProtocolException(
          'Transfer requires too many BLE frames.');
    }
    return List<Uint8List>.generate(total, (seq) {
      final start = seq * chunkLength;
      final end = (start + chunkLength).clamp(0, payloadWithChecksum.length);
      return Uint8List.fromList([
        0x52,
        0x41,
        currentFrameVersion,
        ...tokenBytes,
        (seq >> 8) & 0xff,
        seq & 0xff,
        (total >> 8) & 0xff,
        total & 0xff,
        ...payloadWithChecksum.sublist(start, end),
      ]);
    });
  }

  static Uint8List acknowledgement(String messageId) => Uint8List.fromList([
        0x41,
        0x43,
        1,
        ...List<int>.generate(8, (index) {
          final token = transferToken(messageId);
          return int.parse(token.substring(index * 2, index * 2 + 2),
              radix: 16);
        }),
      ]);

  static Uint8List transferComplete() => Uint8List.fromList([0x44, 0x4f, 1]);

  static Uint8List requestPeerQueue() => Uint8List.fromList([0x52, 0x51, 1]);

  static Uint8List capabilityRequest() =>
      Uint8List.fromList([0x48, 0x49, 2, currentProtocolVersion]);

  static Uint8List capabilityResponse() =>
      Uint8List.fromList([0x48, 0x41, 2, currentProtocolVersion]);

  /// A per-notification receipt keeps Android's peripheral notification queue
  /// bounded to one data frame while the receiver processes it.
  static Uint8List notificationReceipt(List<int> frame) {
    if (!isDataFrame(frame)) {
      throw const BleProtocolException(
          'Cannot acknowledge a malformed data frame.');
    }
    return Uint8List.fromList([
      0x46,
      0x52,
      1,
      ...frame.sublist(3, 11),
      frame[11],
      frame[12],
    ]);
  }

  static bool isDataFrame(List<int> frame) =>
      frame.length >= headerSize &&
      frame[0] == 0x52 &&
      frame[1] == 0x41 &&
      (frame[2] == 1 || frame[2] == currentFrameVersion);

  static bool isNotificationReceipt(List<int> bytes) =>
      bytes.length == 13 &&
      bytes[0] == 0x46 &&
      bytes[1] == 0x52 &&
      bytes[2] == 1;

  static String notificationReceiptKey(List<int> bytes) {
    if (!isNotificationReceipt(bytes)) {
      throw const BleProtocolException('Malformed notification receipt.');
    }
    final token = bytes
        .sublist(3, 11)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final sequence = (bytes[11] << 8) | bytes[12];
    return '$token:$sequence';
  }

  static String dataFrameReceiptKey(List<int> frame) {
    if (!isDataFrame(frame)) {
      throw const BleProtocolException('Malformed BLE data frame.');
    }
    final token = frame
        .sublist(3, 11)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final sequence = (frame[11] << 8) | frame[12];
    return '$token:$sequence';
  }

  static bool isCapabilityRequest(List<int> bytes) =>
      _same(bytes, capabilityRequest());

  static bool isCapabilityResponse(List<int> bytes) =>
      _same(bytes, capabilityResponse());

  static bool isTransferComplete(List<int> bytes) =>
      _same(bytes, transferComplete());

  static bool isPeerQueueRequest(List<int> bytes) =>
      _same(bytes, requestPeerQueue());

  static bool isAcknowledgementFrame(List<int> bytes) =>
      bytes.length == 11 &&
      bytes[0] == 0x41 &&
      bytes[1] == 0x43 &&
      bytes[2] == 1;

  static bool isAcknowledgement(List<int> bytes, String messageId) =>
      _same(bytes, acknowledgement(messageId));

  static bool _same(List<int> first, List<int> second) =>
      first.length == second.length &&
      List<int>.generate(first.length, (index) => index)
          .every((index) => first[index] == second[index]);

  /// CRC-32/ISO-HDLC, appended to each complete framed payload. This detects
  /// corruption that still happens to form valid JSON and valid SOS fields.
  static List<int> _checksum32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    crc = (crc ^ 0xffffffff) & 0xffffffff;
    return [
      (crc >> 24) & 0xff,
      (crc >> 16) & 0xff,
      (crc >> 8) & 0xff,
      crc & 0xff,
    ];
  }

  static bool _validChecksum32(List<int> bytes) {
    if (bytes.length < 4) return false;
    final payload = bytes.sublist(0, bytes.length - 4);
    return _same(bytes.sublist(bytes.length - 4), _checksum32(payload));
  }
}

class BleFrameAssembler {
  final Map<String, _FrameSet> _sets = {};

  Uint8List? add(List<int> frame, {DateTime? now}) {
    if (frame.length < BleFrameCodec.headerSize ||
        frame[0] != 0x52 ||
        frame[1] != 0x41 ||
        (frame[2] != 1 && frame[2] != BleFrameCodec.currentFrameVersion)) {
      throw const BleProtocolException('Malformed BLE frame.');
    }
    final token = frame
        .sublist(3, 11)
        .map((part) => part.toRadixString(16).padLeft(2, '0'))
        .join();
    final sequence = (frame[11] << 8) | frame[12];
    final total = (frame[13] << 8) | frame[14];
    if (total < 1 || total > BleFrameCodec.maximumFrames || sequence >= total) {
      throw const BleProtocolException('Invalid BLE frame sequence.');
    }
    final current = now ?? DateTime.now();
    _sets.removeWhere((_, set) =>
        current.difference(set.updatedAt) > const Duration(minutes: 2));
    var set = _sets[token];
    if (set == null) {
      if (_sets.length >= 4) _sets.remove(_sets.keys.first);
      set = _FrameSet(total, frame[2], current);
      _sets[token] = set;
    }
    if (set.total != total || set.version != frame[2]) {
      _sets.remove(token);
      throw const BleProtocolException('Inconsistent BLE frame count.');
    }
    set.updatedAt = current;
    final chunk = Uint8List.fromList(frame.sublist(BleFrameCodec.headerSize));
    final previous = set.chunks[sequence];
    if (previous != null && !BleFrameCodec._same(previous, chunk)) {
      _sets.remove(token);
      throw const BleProtocolException('Conflicting duplicate BLE frame.');
    }
    if (previous == null) {
      set.chunks[sequence] = chunk;
      set.size += chunk.length;
    }
    final maximumTransferBytes = BleEmergencyEnvelope.maxPayloadBytes +
        (set.version == BleFrameCodec.currentFrameVersion ? 4 : 0);
    if (set.size > maximumTransferBytes) {
      _sets.remove(token);
      throw const BleProtocolException('BLE transfer exceeds the size limit.');
    }
    if (set.chunks.length != total) return null;
    final output = BytesBuilder(copy: false);
    for (var index = 0; index < total; index++) {
      final part = set.chunks[index];
      if (part == null) return null;
      output.add(part);
    }
    _sets.remove(token);
    final complete = output.takeBytes();
    if (set.version == BleFrameCodec.currentFrameVersion &&
        !BleFrameCodec._validChecksum32(complete)) {
      throw const BleProtocolException('BLE payload checksum mismatch.');
    }
    return set.version == BleFrameCodec.currentFrameVersion
        ? Uint8List.fromList(complete.sublist(0, complete.length - 4))
        : complete;
  }
}

class _FrameSet {
  _FrameSet(this.total, this.version, this.updatedAt);
  final int total;
  final int version;
  DateTime updatedAt;
  int size = 0;
  final Map<int, Uint8List> chunks = {};
}
