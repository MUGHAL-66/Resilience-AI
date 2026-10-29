import '../models/emergency_case.dart';

/// Contract for a future online API adapter. No network implementation exists yet.
abstract interface class EmergencySyncClient {
  /// Upload using [EmergencyCase.localId] as the idempotency key and return server ID.
  Future<int> upload(EmergencyCase emergency);
}
