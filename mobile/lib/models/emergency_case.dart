class EmergencyCase {
  const EmergencyCase({
    required this.localId,
    this.serverId,
    this.emergencyType = 'other',
    required this.injuryType,
    this.injuryDetail = 'unknown',
    required this.bleedingStatus,
    required this.consciousnessStatus,
    required this.trapped,
    String? trappedStatus,
    this.peopleAffected,
    required this.description,
    this.latitude,
    this.longitude,
    required this.createdAt,
    required this.updatedAt,
    this.priority,
    this.status = 'open',
    this.syncStatus = 'pending',
  }) : trappedStatus = trappedStatus ?? (trapped ? 'yes' : 'no');

  final String localId;
  final int? serverId;
  final String emergencyType;
  final String injuryType;
  final String injuryDetail;
  final String bleedingStatus;
  final String consciousnessStatus;
  final bool trapped;
  final String trappedStatus;
  final int? peopleAffected;
  final String description;
  final double? latitude;
  final double? longitude;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? priority;
  final String status;
  final String syncStatus;

  Map<String, Object?> toMap() => {
        'local_id': localId,
        'server_id': serverId,
        'emergency_type': emergencyType,
        'injury_type': injuryType,
        'injury_detail': injuryDetail,
        'bleeding_status': bleedingStatus,
        'consciousness_status': consciousnessStatus,
        'trapped': trapped ? 1 : 0,
        'trapped_status': trappedStatus,
        'people_affected': peopleAffected,
        'description': description,
        'latitude': latitude,
        'longitude': longitude,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'priority': priority,
        'status': status,
        'sync_status': syncStatus,
      };

  factory EmergencyCase.fromMap(Map<String, Object?> map) {
    final trapped = (map['trapped']! as int) == 1;
    return EmergencyCase(
      localId: map['local_id']! as String,
      serverId: map['server_id'] as int?,
      emergencyType: map['emergency_type'] as String? ?? 'other',
      injuryType: map['injury_type']! as String,
      injuryDetail: map['injury_detail'] as String? ?? 'unknown',
      bleedingStatus: map['bleeding_status']! as String,
      consciousnessStatus: map['consciousness_status']! as String,
      trapped: trapped,
      trappedStatus:
          map['trapped_status'] as String? ?? (trapped ? 'yes' : 'no'),
      peopleAffected: map['people_affected'] as int?,
      description: map['description']! as String,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
      priority: map['priority'] as String?,
      status: map['status']! as String,
      syncStatus: map['sync_status']! as String,
    );
  }
}
