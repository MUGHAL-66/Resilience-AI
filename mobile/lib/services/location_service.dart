import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class Coordinates {
  const Coordinates(this.latitude, this.longitude, {this.accuracyMeters});

  final double latitude;
  final double longitude;
  final double? accuracyMeters;
}

abstract interface class LocationService {
  Future<Coordinates?> currentCoordinates();
}

/// Narrow adapter around Geolocator so capture outcomes can be tested without
/// platform channels, permission dialogs, or GPS hardware.
abstract interface class GeolocatorGateway {
  Future<bool> isLocationServiceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<Position> getCurrentPosition(LocationSettings settings);
}

class PlatformGeolocatorGateway implements GeolocatorGateway {
  const PlatformGeolocatorGateway();

  @override
  Future<bool> isLocationServiceEnabled() =>
      Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Future<Position> getCurrentPosition(LocationSettings settings) =>
      Geolocator.getCurrentPosition(locationSettings: settings);
}

typedef LocationDiagnosticLogger = void Function(String message);

class GeolocatorLocationService implements LocationService {
  const GeolocatorLocationService({
    GeolocatorGateway gateway = const PlatformGeolocatorGateway(),
    this.requestTimeout = const Duration(seconds: 20),
    LocationDiagnosticLogger? logger,
  })  : _gateway = gateway,
        _logger = logger ?? _debugLog;

  final GeolocatorGateway _gateway;
  final Duration requestTimeout;
  final LocationDiagnosticLogger _logger;

  static void _debugLog(String message) => debugPrint(message);

  void _log(String result) => _logger('GPS capture: $result');

  @override
  Future<Coordinates?> currentCoordinates() async {
    try {
      if (!await _gateway.isLocationServiceEnabled()) {
        _log('location_services_disabled');
        return null;
      }

      var permission = await _gateway.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.unableToDetermine) {
        permission = await _gateway.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        _log('permission_denied_permanently');
        return null;
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.unableToDetermine) {
        _log('permission_denied');
        return null;
      }

      final position = await _gateway
          .getCurrentPosition(LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: requestTimeout,
          ))
          .timeout(requestTimeout + const Duration(seconds: 2));
      _log('position_acquired');
      return Coordinates(position.latitude, position.longitude,
          accuracyMeters: position.accuracy);
    } on TimeoutException {
      _log('position_timeout_after_${requestTimeout.inSeconds}s');
      return null;
    } on LocationServiceDisabledException {
      // Location can be switched off after the initial service check.
      _log('location_services_disabled');
      return null;
    } on PermissionDeniedException {
      _log('permission_denied');
      return null;
    } catch (error) {
      // Do not log exception messages, which could contain device or user data.
      _log('unexpected_error_${error.runtimeType}');
      return null;
    }
  }
}
