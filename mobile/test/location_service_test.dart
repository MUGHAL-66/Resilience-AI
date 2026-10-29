import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:resilience_ai/services/location_service.dart';

class FakeGeolocatorGateway implements GeolocatorGateway {
  bool enabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission requestedPermission = LocationPermission.whileInUse;
  Object? positionError;
  Future<Position> Function()? positionResult;
  LocationSettings? receivedSettings;
  int requestCount = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => enabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requestCount++;
    return requestedPermission;
  }

  @override
  Future<Position> getCurrentPosition(LocationSettings settings) {
    receivedSettings = settings;
    if (positionError case final error?) return Future.error(error);
    return positionResult?.call() ?? Future.value(_position);
  }
}

final _position = Position(
  longitude: 67.01,
  latitude: 24.86,
  timestamp: DateTime.utc(2026),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 1,
  heading: 0,
  headingAccuracy: 1,
  speed: 0,
  speedAccuracy: 0,
  isMocked: false,
);

void main() {
  late FakeGeolocatorGateway gateway;
  late List<String> diagnostics;
  late GeolocatorLocationService service;

  setUp(() {
    gateway = FakeGeolocatorGateway();
    diagnostics = [];
    service = GeolocatorLocationService(
      gateway: gateway,
      logger: diagnostics.add,
    );
  });

  test('captures coordinates and requests a 20 second high accuracy fix',
      () async {
    final result = await service.currentCoordinates();

    expect(result?.latitude, 24.86);
    expect(result?.longitude, 67.01);
    expect(gateway.receivedSettings?.accuracy, LocationAccuracy.high);
    expect(gateway.receivedSettings?.timeLimit, const Duration(seconds: 20));
    expect(diagnostics, contains('GPS capture: position_acquired'));
  });

  test('logs disabled location services distinctly', () async {
    gateway.enabled = false;

    expect(await service.currentCoordinates(), isNull);
    expect(diagnostics, ['GPS capture: location_services_disabled']);
    expect(gateway.requestCount, 0);
  });

  test('requests permission and logs denial distinctly', () async {
    gateway.permission = LocationPermission.denied;
    gateway.requestedPermission = LocationPermission.denied;

    expect(await service.currentCoordinates(), isNull);
    expect(gateway.requestCount, 1);
    expect(diagnostics, ['GPS capture: permission_denied']);
  });

  test('does not request permission again after permanent denial', () async {
    gateway.permission = LocationPermission.deniedForever;

    expect(await service.currentCoordinates(), isNull);
    expect(gateway.requestCount, 0);
    expect(diagnostics, ['GPS capture: permission_denied_permanently']);
  });

  test('logs position timeout and returns null', () async {
    gateway.positionError = TimeoutException('test timeout');

    expect(await service.currentCoordinates(), isNull);
    expect(diagnostics, ['GPS capture: position_timeout_after_20s']);
  });

  test('logs other exception type without exception message', () async {
    gateway.positionError = StateError('sensitive detail');

    expect(await service.currentCoordinates(), isNull);
    expect(diagnostics, ['GPS capture: unexpected_error_StateError']);
    expect(diagnostics.join(), isNot(contains('sensitive detail')));
  });
}
