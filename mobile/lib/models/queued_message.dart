class QueuedMessage {
  const QueuedMessage({
    required this.messageId,
    required this.emergencyLocalId,
    this.originDeviceId,
    this.senderDeviceId,
    required this.messageType,
    required this.payloadJson,
    required this.createdAt,
    this.expiresAt,
    this.hopCount = 0,
    this.deliveryStatus = 'queued',
    this.lastAttemptAt,
    this.attemptCount = 0,
    this.lastPeerToken,
  });
  final String messageId;
  final String emergencyLocalId;
  final String? originDeviceId;
  final String? senderDeviceId;
  final String messageType;
  final String payloadJson;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final int hopCount;
  final String deliveryStatus;
  final DateTime? lastAttemptAt;
  final int attemptCount;
  final String? lastPeerToken;

  Map<String, Object?> toMap() => {
        'message_id': messageId,
        'emergency_local_id': emergencyLocalId,
        'origin_device_id': originDeviceId,
        'sender_device_id': senderDeviceId,
        'message_type': messageType,
        'payload_json': payloadJson,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt?.toUtc().toIso8601String(),
        'hop_count': hopCount,
        'delivery_status': deliveryStatus,
        'last_attempt_at': lastAttemptAt?.toUtc().toIso8601String(),
        'attempt_count': attemptCount,
        'last_peer_token': lastPeerToken,
      };

  factory QueuedMessage.fromMap(Map<String, Object?> map) => QueuedMessage(
        messageId: map['message_id']! as String,
        emergencyLocalId: map['emergency_local_id']! as String,
        originDeviceId: map['origin_device_id'] as String?,
        senderDeviceId: map['sender_device_id'] as String?,
        messageType: map['message_type']! as String,
        payloadJson: map['payload_json']! as String,
        createdAt: DateTime.parse(map['created_at']! as String),
        expiresAt: map['expires_at'] == null
            ? null
            : DateTime.parse(map['expires_at']! as String),
        hopCount: map['hop_count'] as int? ?? 0,
        deliveryStatus: map['delivery_status']! as String,
        lastAttemptAt: map['last_attempt_at'] == null
            ? null
            : DateTime.parse(map['last_attempt_at']! as String),
        attemptCount: map['attempt_count'] as int? ?? 0,
        lastPeerToken: map['last_peer_token'] as String?,
      );
}
