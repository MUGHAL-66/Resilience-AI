import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter_ble_central/flutter_ble_central.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart'
    hide GattCharacteristic;

import '../models/emergency_case.dart';
import '../models/queued_message.dart';
import '../repositories/emergency_repository.dart';
import 'ble_message_protocol.dart';
import 'ble_receive_processor.dart';

const sosServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const sosTxUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const sosRxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

enum BleStatus {
  stopped,
  starting,
  running,
  permissionDenied,
  bluetoothOff,
  error
}

enum SosSendResult {
  delivered,
  failed,
  noNearbyPeer,
  bluetoothUnavailable,
  unavailable
}

class BleStatusUpdate {
  const BleStatusUpdate(this.status, [this.message]);
  final BleStatus status;
  final String? message;
}

class BlePeer {
  const BlePeer(this.address, {this.name, this.rssi});
  final String address;
  final String? name;
  final int? rssi;
}

/// Bounded exponential retry schedule with injected jitter for deterministic tests.
class BleRetryBackoff {
  static const maximumAttempts = 5;

  static Duration delay(int attempt, {required int jitterMilliseconds}) {
    if (attempt < 1 || attempt > maximumAttempts) {
      throw RangeError.range(attempt, 1, maximumAttempts, 'attempt');
    }
    if (jitterMilliseconds < 0 || jitterMilliseconds >= 1000) {
      throw RangeError.range(jitterMilliseconds, 0, 999, 'jitterMilliseconds');
    }
    return Duration(
      milliseconds: min(60, 1 << (attempt - 1)) * 1000 + jitterMilliseconds,
    );
  }
}

class BleGattLayout {
  const BleGattLayout({required this.receive, required this.acknowledgement});
  final GattCharacteristic receive;
  final GattCharacteristic acknowledgement;

  static BleGattLayout select(List<GattService> services) {
    final service = services
        .where((value) =>
            AndroidBleTransport._sameUuid(value.uuid, sosServiceUuid))
        .firstOrNull;
    if (service == null) {
      throw StateError('Peer did not expose the SOS GATT service.');
    }
    final characteristics =
        service.characteristics ?? const <GattCharacteristic>[];
    final receive = characteristics
        .where((value) => AndroidBleTransport._sameUuid(value.uuid, sosRxUuid))
        .firstOrNull;
    final acknowledgement = characteristics
        .where((value) => AndroidBleTransport._sameUuid(value.uuid, sosTxUuid))
        .firstOrNull;
    if (receive == null ||
        (!receive.properties.write &&
            !receive.properties.writeWithoutResponse)) {
      throw StateError(
          'Peer SOS receive characteristic is missing or not writable.');
    }
    if (acknowledgement == null ||
        (!acknowledgement.properties.notify &&
            !acknowledgement.properties.indicate)) {
      throw StateError(
          'Peer SOS acknowledgement characteristic is missing or cannot notify.');
    }
    return BleGattLayout(receive: receive, acknowledgement: acknowledgement);
  }

  bool get writeWithoutResponse =>
      !receive.properties.write && receive.properties.writeWithoutResponse;
}

/// Android dual-role BLE transport: each phone advertises a GATT server and
/// scans/connects as a central. Every transfer is framed and acknowledged
/// only after the receiver commits it to SQLite.
class AndroidBleTransport {
  AndroidBleTransport(this.repository,
      {FlutterBleCentral? central, FlutterBlePeripheral? peripheral})
      : _central = central ?? FlutterBleCentral(),
        _peripheral = peripheral ?? FlutterBlePeripheral();

  final EmergencyRepository repository;
  final FlutterBleCentral _central;
  final FlutterBlePeripheral _peripheral;
  final _received = StreamController<QueuedMessage>.broadcast();
  final _status = StreamController<BleStatusUpdate>.broadcast();
  final _peers = StreamController<List<BlePeer>>.broadcast();
  final Map<String, ScanResult> _nearby = {};
  final Map<String, String> _peerTokens = {};
  final BleFrameAssembler _assembler = BleFrameAssembler();
  final Set<String> _activeTransfers = {};
  final Set<String> _initializedPeers = {};
  final Map<(String, String), Completer<void>> _ackWaiters = {};
  final Map<String, Completer<void>> _peerDoneWaiters = {};
  final Map<String, Completer<void>> _capabilityWaiters = {};
  final Map<String, Completer<void>> _peripheralAckWaiters = {};
  final Map<String, Completer<void>> _peripheralFrameAckWaiters = {};
  final Map<String, Completer<void>> _connectionWaiters = {};
  late final BleReceiveProcessor _receiveProcessor =
      BleReceiveProcessor(repository, assembler: _assembler);
  StreamSubscription<ScanResult>? _scanSub;
  StreamSubscription<GattWrite>? _writeSub;
  StreamSubscription<CharacteristicValue>? _notifySub;
  StreamSubscription<ConnectionStateChange>? _connectionSub;
  StreamSubscription<GattSubscription>? _subscriptionSub;
  bool _peripheralSendActive = false;
  bool _peripheralRetryRequested = false;
  final Set<String> _retryRequestedPeers = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, int> _retryAttempts = {};
  final Random _retryRandom = Random();
  static const _maximumPeerRetries = BleRetryBackoff.maximumAttempts;
  bool _running = false;
  bool _disposed = false;
  String? _deviceId;

  Stream<QueuedMessage> get receivedMessages => _received.stream;
  Stream<BleStatusUpdate> get statusChanges => _status.stream;
  Stream<List<BlePeer>> get nearbyPeers => _peers.stream;

  Future<void> startScanning() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
          'Offline SOS BLE is currently available on Android only.');
    }
    if (_disposed) throw StateError('BLE transport has been disposed.');
    _status.add(const BleStatusUpdate(BleStatus.starting));
    try {
      final centralPermission = await _central.requestPermission();
      final peripheralPermission = await _peripheral.requestPermission();
      if (centralPermission.name == 'turnedOff' ||
          peripheralPermission.name == 'turnedOff') {
        _status.add(const BleStatusUpdate(BleStatus.bluetoothOff,
            'Turn on Bluetooth to discover nearby phones.'));
        return;
      }
      if (centralPermission.name != 'ready' &&
              centralPermission.name != 'granted' ||
          peripheralPermission.name != 'ready' &&
              peripheralPermission.name != 'granted') {
        _status.add(const BleStatusUpdate(BleStatus.permissionDenied,
            'Bluetooth permission was denied. Local SOS saving is still available.'));
        return;
      }
      if (!await _central.isBluetoothOn || !await _peripheral.isBluetoothOn) {
        _status.add(const BleStatusUpdate(BleStatus.bluetoothOff,
            'Turn on Bluetooth to discover nearby phones.'));
        return;
      }
      _deviceId = await repository.database.getOrCreateDeviceId();
      developer.log(
          'ble.start localDeviceId=$_deviceId service=$sosServiceUuid',
          name: 'resilience.ble');
      await repository.recoverInterruptedMessages();
      await repository.recoverLocalOutgoingRetries(_deviceId!);
      _writeSub ??= _peripheral.onGattWrite
          .listen(_dispatchGattWrite, onError: _reportError);
      _notifySub ??= _central.onCharacteristicValueChanged
          .listen(_dispatchNotification, onError: _reportError);
      _connectionSub ??= _central.onConnectionStateChanged.listen((event) {
        developer.log(
            'gatt.connection peer=${event.address} state=${event.state.name}',
            name: 'resilience.ble');
        if (event.state == GattConnectionState.disconnected) {
          _initializedPeers.remove(event.address);
          final waiter = _connectionWaiters[event.address];
          if (waiter != null && !waiter.isCompleted) {
            waiter.completeError(StateError(
                'Peer disconnected before the GATT link became ready.'));
          }
        } else if (event.state == GattConnectionState.connected) {
          final waiter = _connectionWaiters[event.address];
          if (waiter != null && !waiter.isCompleted) waiter.complete();
        }
      }, onError: _reportError);
      _subscriptionSub ??= _peripheral.onCharacteristicSubscriptionChanged
          .listen(_handleSubscriptionChanged, onError: _reportError);
      // Subscribe before starting the scan: some Android stacks report the
      // first result immediately after start() returns.
      _scanSub ??= _central.onScanResult
          .listen(_handleScanResult, onError: _reportError);
      _running = true;
      _retryAttempts.clear();
      // Flags (3) + 128-bit service UUID (18) + manufacturer field (9) =
      // 30 bytes, within the 31-byte legacy advertising payload limit.
      await _peripheral.start(
        advertiseData: AdvertiseDataCore(
          serviceUuid: sosServiceUuid,
          manufacturerId: BlePeerIdentity.manufacturerId,
          manufacturerData: BlePeerIdentity.advertisementData(_deviceId!),
        ),
        gattServer: const GattServerSettings(serviceUuid: sosServiceUuid),
      );
      await _central.start(serviceUuids: const [sosServiceUuid]);
      _status.add(const BleStatusUpdate(BleStatus.running,
          'Advertising and searching for nearby SOS devices.'));
    } catch (error) {
      _running = false;
      developer.log('ble.start.failed error=$error',
          name: 'resilience.ble', error: error);
      _status.add(BleStatusUpdate(BleStatus.error, _friendlyError(error)));
      rethrow;
    }
  }

  void _handleScanResult(ScanResult result) {
    final device = result.device;
    if (device == null || device.address.isEmpty) return;
    final uuids = result.scanRecord?.serviceUuids ?? const <String>[];
    if (!uuids.any((uuid) =>
        uuid?.toLowerCase().replaceAll('-', '') ==
        sosServiceUuid.replaceAll('-', ''))) {
      return;
    }
    final peerToken =
        BlePeerIdentity.tokenFrom(result.scanRecord?.manufacturerSpecificData);
    if (peerToken == null) {
      developer.log(
          'peer.identity.missing address=${device.address}; both phones need the same protocol build.',
          name: 'resilience.ble');
      return;
    }
    _nearby[device.address] = result;
    _peerTokens[device.address] = peerToken;
    developer.log(
        'peer.discovered address=${device.address} rssi=${result.rssi}',
        name: 'resilience.ble');
    _peers.add(_nearby.values
        .map((r) =>
            BlePeer(r.device!.address, name: r.device!.name, rssi: r.rssi))
        .toList());
    if (_shouldInitiateTo(device.address) &&
        !_retryTimers.containsKey(device.address) &&
        (_retryAttempts[device.address] ?? 0) < _maximumPeerRetries) {
      unawaited(_sendQueuedTo(device.address));
    }
  }

  bool _shouldInitiateTo(String address) {
    final localToken = BlePeerIdentity.tokenFor(_deviceId ?? '');
    final peerToken = _peerTokens[address];
    final initiate = peerToken != null &&
        BlePeerIdentity.shouldInitiate(
            localToken: localToken, peerToken: peerToken);
    developer.log(
        'peer.election address=$address local=$localToken peer=$peerToken role=${initiate ? 'central' : 'peripheral'}',
        name: 'resilience.ble');
    return initiate;
  }

  Future<void> _sendQueuedTo(String address) async {
    if (!_running || !_shouldInitiateTo(address)) return;
    if (!_activeTransfers.add(address)) return;
    var keepConnection = false;
    try {
      if (!_running) return;
      final connectionState = await _central.getConnectionState(address);
      final alreadyReady = _initializedPeers.contains(address) &&
          connectionState == GattConnectionState.connected;
      final messages = await repository.listForwardableMessages();
      if (alreadyReady && messages.isEmpty) {
        keepConnection = true;
        return;
      }
      final peerDone = Completer<void>();
      _peerDoneWaiters[address] = peerDone;
      BleGattLayout? discoveredLayout;
      Object? lastGattError;
      // flutter_ble_central.connect() only starts connectGatt and returns; it
      // does not await Android's onConnectionStateChange callback. Wait for
      // the actual connected event before starting service discovery.
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          await _connectAndWait(address, attempt: attempt);
          developer.log('gatt.connect.success peer=$address attempt=$attempt',
              name: 'resilience.ble');
          final services = await _central.discoverServices(address);
          developer.log(
              'gatt.services.discovered peer=$address attempt=$attempt count=${services.length}',
              name: 'resilience.ble');
          discoveredLayout = BleGattLayout.select(services);
          break;
        } catch (error, stackTrace) {
          lastGattError = error;
          developer.log(
              'gatt.connect_or_discovery.failed peer=$address attempt=$attempt error=$error',
              name: 'resilience.ble',
              error: error,
              stackTrace: stackTrace);
          if (attempt == 3) rethrow;
          try {
            await _central.disconnect(address);
            await _waitUntilDisconnected(address);
          } catch (disconnectError, disconnectStack) {
            developer.log(
                'gatt.retry.disconnect.failed peer=$address attempt=$attempt error=$disconnectError',
                name: 'resilience.ble',
                error: disconnectError,
                stackTrace: disconnectStack);
          }
          await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
      final layout = discoveredLayout ??
          (throw StateError('GATT discovery failed: $lastGattError'));
      developer.log(
          'gatt.layout peer=$address service=$sosServiceUuid rx=${layout.receive.uuid} write=${layout.receive.properties.write} writeWithoutResponse=${layout.receive.properties.writeWithoutResponse} tx=${layout.acknowledgement.uuid} notify=${layout.acknowledgement.properties.notify} indicate=${layout.acknowledgement.properties.indicate}',
          name: 'resilience.ble');
      var mtu = 23;
      try {
        mtu = await _central.requestMtu(address: address, mtu: 247).timeout(
              const Duration(seconds: 5),
              onTimeout: () => 23,
            );
      } catch (error, stackTrace) {
        developer.log('MTU request failed; using default MTU 23: $error',
            name: 'resilience.ble', stackTrace: stackTrace);
      }
      await _central.setCharacteristicNotification(
          address: address,
          serviceUuid: sosServiceUuid,
          characteristicUuid: sosTxUuid,
          enable: true);
      developer.log(
          'gatt.tx.cccd.enabled peer=$address characteristic=$sosTxUuid',
          name: 'resilience.ble');
      final capabilityWaiter = Completer<void>();
      _capabilityWaiters[address] = capabilityWaiter;
      try {
        await _central.writeCharacteristic(
          address: address,
          serviceUuid: sosServiceUuid,
          characteristicUuid: sosRxUuid,
          value: BleFrameCodec.capabilityRequest(),
        );
        developer.log(
            'protocol.capability.sent peer=$address version=${BleFrameCodec.currentProtocolVersion}',
            name: 'resilience.ble');
        try {
          await capabilityWaiter.future.timeout(const Duration(seconds: 8));
        } on TimeoutException catch (error, stackTrace) {
          developer.log(
              'protocol.capability.timeout peer=$address stage=await_response elapsed=8s',
              name: 'resilience.ble',
              error: error,
              stackTrace: stackTrace);
          rethrow;
        }
        developer.log('protocol.capability.confirmed peer=$address',
            name: 'resilience.ble');
      } finally {
        _capabilityWaiters.remove(address);
      }
      developer.log(
          'queue.ready role=central peer=$address count=${messages.length}',
          name: 'resilience.ble');
      await _central.writeCharacteristic(
        address: address,
        serviceUuid: sosServiceUuid,
        characteristicUuid: sosRxUuid,
        value: BleFrameCodec.requestPeerQueue(),
        withoutResponse: layout.writeWithoutResponse,
      );
      developer.log('transfer.peer_queue_requested peer=$address',
          name: 'resilience.ble');
      for (final queued in messages) {
        late final BleEmergencyEnvelope decoded;
        try {
          decoded = BleEmergencyEnvelope.decode(queued.payloadJson);
        } on BleProtocolException catch (error) {
          await repository.updateMessageStatus(queued.messageId, 'expired');
          developer.log('queue.expired id=${queued.messageId} reason=$error',
              name: 'resilience.ble');
          continue;
        }
        if (decoded.hopCount >= decoded.maxHops) {
          await repository.updateMessageStatus(queued.messageId, 'hop_limit');
          continue;
        }
        final previousSenderToken = decoded.senderDeviceId == null
            ? null
            : BlePeerIdentity.tokenFor(decoded.senderDeviceId!);
        if (previousSenderToken != null &&
            previousSenderToken == _peerTokens[address]) {
          developer.log(
              'queue.skip_previous_sender peer=$address message=${queued.messageId}',
              name: 'resilience.ble');
          continue;
        }
        try {
          // Increment only in the transmitted copy. Persist it after ACK; a
          // disconnected retry must reuse the same hop, not consume another.
          final forwarded = decoded.forward(senderDeviceId: _deviceId);
          final forwardEntry = forwarded.toQueuedMessage(
            emergencyLocalId: queued.emergencyLocalId,
          );
          final raw = utf8.encode(forwardEntry.payloadJson);
          final frames = BleFrameCodec.encode(queued.messageId, raw, mtu);
          developer.log(
              'gatt.ready peer=$address mtu=$mtu frames=${frames.length} writeWithoutResponse=${layout.writeWithoutResponse}',
              name: 'resilience.ble');
          await repository.updateMessageStatus(queued.messageId, 'sending',
              attemptedAt: DateTime.now().toUtc(),
              peerToken: _peerTokens[address]);
          final ackWaiter = Completer<void>();
          _ackWaiters[(address, queued.messageId)] = ackWaiter;
          for (var index = 0; index < frames.length; index++) {
            developer.log(
                'gatt.write peer=$address message=${queued.messageId} chunk=${index + 1}/${frames.length} bytes=${frames[index].length}',
                name: 'resilience.ble');
            await _central.writeCharacteristic(
              address: address,
              serviceUuid: sosServiceUuid,
              characteristicUuid: sosRxUuid,
              value: frames[index],
              withoutResponse: layout.writeWithoutResponse,
            );
          }
          await ackWaiter.future.timeout(const Duration(seconds: 20));
          await repository.updateForwardingEnvelope(forwardEntry);
          final isOrigin = decoded.originDeviceId == _deviceId;
          final deliveredState = isOrigin ? 'sent' : 'relayed';
          await repository.updateMessageStatus(queued.messageId, deliveredState,
              attemptedAt: DateTime.now().toUtc());
          developer.log(
              'transfer.acknowledged role=central peer=$address message=${queued.messageId} savedByPeer=true state=$deliveredState',
              name: 'resilience.ble');
        } catch (error, stackTrace) {
          await repository.updateMessageStatus(queued.messageId, 'failed',
              attemptedAt: DateTime.now().toUtc());
          developer.log(
              'transfer.failed role=central peer=$address message=${queued.messageId} error=$error',
              name: 'resilience.ble',
              stackTrace: stackTrace);
          _status.add(BleStatusUpdate(BleStatus.error, _friendlyError(error)));
          rethrow;
        } finally {
          _ackWaiters.remove((address, queued.messageId));
        }
      }
      await _central.writeCharacteristic(
        address: address,
        serviceUuid: sosServiceUuid,
        characteristicUuid: sosRxUuid,
        value: BleFrameCodec.transferComplete(),
        withoutResponse: layout.writeWithoutResponse,
      );
      developer.log('transfer.local_complete role=central peer=$address',
          name: 'resilience.ble');
      await peerDone.future.timeout(const Duration(seconds: 45));
      developer.log('transfer.peer_complete role=central peer=$address',
          name: 'resilience.ble');
      keepConnection = true;
      _initializedPeers.add(address);
      _retryAttempts.remove(address);
    } catch (error, stackTrace) {
      developer.log('gatt.session.failed peer=$address error=$error',
          name: 'resilience.ble', stackTrace: stackTrace);
      _status.add(BleStatusUpdate(BleStatus.error, _friendlyError(error)));
      _schedulePeerRetry(address, error);
    } finally {
      _peerDoneWaiters.remove(address);
      if (!keepConnection) {
        _initializedPeers.remove(address);
        try {
          await _central.disconnect(address);
        } catch (error, stackTrace) {
          developer.log('gatt.disconnect.failed peer=$address error=$error',
              name: 'resilience.ble', stackTrace: stackTrace);
        }
      }
      _activeTransfers.remove(address);
      if (_retryRequestedPeers.remove(address) && _running) {
        unawaited(_sendQueuedTo(address));
      }
    }
  }

  void _schedulePeerRetry(String address, Object reason) {
    if (!_running || _retryTimers.containsKey(address)) return;
    final attempt = (_retryAttempts[address] ?? 0) + 1;
    if (attempt > _maximumPeerRetries) {
      developer.log(
          'retry.exhausted peer=$address attempts=${attempt - 1} reason=$reason; user action or a new scan session is required',
          name: 'resilience.ble');
      return;
    }
    _retryAttempts[address] = attempt;
    final delay = BleRetryBackoff.delay(attempt,
        jitterMilliseconds: _retryRandom.nextInt(1000));
    developer.log(
        'retry.scheduled peer=$address attempt=$attempt delayMs=${delay.inMilliseconds} reason=$reason',
        name: 'resilience.ble');
    _retryTimers[address] = Timer(delay, () {
      _retryTimers.remove(address);
      if (_running && _nearby.containsKey(address)) {
        unawaited(_sendQueuedTo(address));
      }
    });
  }

  Future<void> _connectAndWait(String address, {required int attempt}) async {
    final state = await _central.getConnectionState(address);
    developer.log(
        'gatt.connect.request peer=$address attempt=$attempt state=${state.name}',
        name: 'resilience.ble');
    if (state == GattConnectionState.connected) return;

    final waiter = Completer<void>();
    _connectionWaiters[address] = waiter;
    try {
      // Plugin connect() resolves after calling connectGatt, before the radio
      // link is established. The stream waiter is the authoritative readiness
      // signal for the next GATT operation.
      await _central.connect(address: address, timeout: 12);
      developer.log('gatt.connect.pending peer=$address attempt=$attempt',
          name: 'resilience.ble');
      await waiter.future.timeout(const Duration(seconds: 14));
      if (!_running) throw StateError('BLE scan stopped during connect.');
    } finally {
      if (identical(_connectionWaiters[address], waiter)) {
        _connectionWaiters.remove(address);
      }
    }
  }

  Future<void> _waitUntilDisconnected(String address) async {
    for (var poll = 0; poll < 20; poll++) {
      if (await _central.getConnectionState(address) ==
          GattConnectionState.disconnected) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw TimeoutException('GATT disconnect did not complete for $address.');
  }

  Future<void> _handleNotification(CharacteristicValue event) async {
    if (!_sameUuid(event.characteristicUuid, sosTxUuid)) return;
    if (BleFrameCodec.isCapabilityResponse(event.value)) {
      developer.log(
          'protocol.capability.received peer=${event.address} version=${BleFrameCodec.currentProtocolVersion}',
          name: 'resilience.ble');
      final waiter = _capabilityWaiters[event.address];
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      return;
    }
    for (final entry in _ackWaiters.entries) {
      if (entry.key.$1 == event.address &&
          !entry.value.isCompleted &&
          BleFrameCodec.isAcknowledgement(event.value, entry.key.$2)) {
        developer.log(
            'ack.received peer=${event.address} message=${entry.key.$2}',
            name: 'resilience.ble');
        entry.value.complete();
        return;
      }
    }
    if (BleFrameCodec.isAcknowledgementFrame(event.value)) {
      developer.log('ack.unmatched role=central peer=${event.address}',
          name: 'resilience.ble');
      return;
    }
    if (BleFrameCodec.isTransferComplete(event.value)) {
      developer.log('transfer.remote_complete peer=${event.address}',
          name: 'resilience.ble');
      final waiter = _peerDoneWaiters[event.address];
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      return;
    }
    if (BleFrameCodec.isPeerQueueRequest(event.value)) return;
    final received = await _processInboundFrame(event.value);
    if (BleFrameCodec.isDataFrame(event.value)) {
      final receipt = BleFrameCodec.notificationReceipt(event.value);
      await _central.writeCharacteristic(
        address: event.address,
        serviceUuid: sosServiceUuid,
        characteristicUuid: sosRxUuid,
        value: receipt,
      );
      developer.log(
          'gatt.frame.receipt.sent peer=${event.address} key=${BleFrameCodec.dataFrameReceiptKey(event.value)}',
          name: 'resilience.ble');
    }
    if (received != null) {
      await _central.writeCharacteristic(
        address: event.address,
        serviceUuid: sosServiceUuid,
        characteristicUuid: sosRxUuid,
        value: BleFrameCodec.acknowledgement(received.message.messageId),
      );
      developer.log(
          'ack.sent role=central message=${received.message.messageId}',
          name: 'resilience.ble');
    }
  }

  void _dispatchNotification(CharacteristicValue event) {
    unawaited(_handleNotification(event).catchError(
      (Object error, StackTrace stackTrace) {
        developer.log(
            'gatt.notification.handler.failed peer=${event.address} characteristic=${event.characteristicUuid} bytes=${event.value.length} error=$error',
            name: 'resilience.ble',
            error: error,
            stackTrace: stackTrace);
        _status.add(BleStatusUpdate(BleStatus.error, _friendlyError(error)));
      },
    ));
  }

  void _dispatchGattWrite(GattWrite event) {
    unawaited(_handleGattWrite(event).catchError(
      (Object error, StackTrace stackTrace) {
        developer.log(
            'gatt.write.handler.failed characteristic=${event.characteristicUuid} bytes=${event.data.length} error=$error',
            name: 'resilience.ble',
            error: error,
            stackTrace: stackTrace);
        _status.add(BleStatusUpdate(BleStatus.error, _friendlyError(error)));
      },
    ));
  }

  Future<void> _handleGattWrite(GattWrite event) async {
    developer.log(
        'gatt.write.received characteristic=${event.characteristicUuid} bytes=${event.data.length}',
        name: 'resilience.ble');
    if (event.characteristicUuid.toLowerCase() != sosRxUuid) return;
    if (BleFrameCodec.isNotificationReceipt(event.data)) {
      final key = BleFrameCodec.notificationReceiptKey(event.data);
      final waiter = _peripheralFrameAckWaiters[key];
      developer.log(
          'gatt.frame.receipt.received key=$key matched=${waiter != null}',
          name: 'resilience.ble');
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      return;
    }
    if (BleFrameCodec.isCapabilityRequest(event.data)) {
      developer.log(
          'protocol.capability.request receivedVersion=${event.data.last} localVersion=${BleFrameCodec.currentProtocolVersion}',
          name: 'resilience.ble');
      await _peripheral.sendData(BleFrameCodec.capabilityResponse(),
          characteristicUuid: sosTxUuid);
      developer.log('protocol.capability.response.sent',
          name: 'resilience.ble');
      return;
    }
    if (BleFrameCodec.isAcknowledgementFrame(event.data)) {
      for (final entry in _peripheralAckWaiters.entries) {
        if (!entry.value.isCompleted &&
            BleFrameCodec.isAcknowledgement(event.data, entry.key)) {
          developer.log('ack.received role=peripheral message=${entry.key}',
              name: 'resilience.ble');
          entry.value.complete();
          return;
        }
      }
      developer.log('ack.unmatched role=peripheral', name: 'resilience.ble');
      return;
    }
    if (BleFrameCodec.isTransferComplete(event.data)) return;
    if (BleFrameCodec.isPeerQueueRequest(event.data)) {
      developer.log('transfer.peer_queue_requested', name: 'resilience.ble');
      unawaited(_trySendFromPeripheral());
      return;
    }
    final received = await _processInboundFrame(event.data);
    if (received != null) {
      await _peripheral.sendData(
          BleFrameCodec.acknowledgement(received.message.messageId),
          characteristicUuid: sosTxUuid);
      developer.log(
          'ack.sent role=peripheral message=${received.message.messageId}',
          name: 'resilience.ble');
    }
  }

  Future<ReceivedSos?> _processInboundFrame(List<int> data) async {
    try {
      developer.log('receive.frame.start bytes=${data.length}',
          name: 'resilience.ble');
      final received = await _receiveProcessor.addFrame(data);
      if (received == null) return null;
      developer.log(
          'receive.database.commit.complete id=${received.message.messageId} duplicate=${received.duplicate}',
          name: 'resilience.ble');
      if (!received.duplicate) _received.add(received.message);
      return received;
    } catch (error) {
      developer.log('message.rejected bytes=${data.length} error=$error',
          name: 'resilience.ble', error: error);
      _status.add(BleStatusUpdate(BleStatus.error, _friendlyError(error)));
      return null;
    }
  }

  void _handleSubscriptionChanged(GattSubscription event) {
    if (_sameUuid(event.characteristicUuid, sosTxUuid) && event.subscribed) {
      developer.log('gatt.tx.subscribed', name: 'resilience.ble');
    }
  }

  Future<void> _trySendFromPeripheral() async {
    if (!_running || !await _peripheral.isSubscribedTo(sosTxUuid)) return;
    if (_peripheralSendActive) {
      _peripheralRetryRequested = true;
      return;
    }
    _peripheralSendActive = true;
    _peripheralRetryRequested = false;
    try {
      do {
        _peripheralRetryRequested = false;
        final messages = await repository.listForwardableMessages();
        developer.log('queue.ready role=peripheral count=${messages.length}',
            name: 'resilience.ble');
        for (final queued in messages) {
          late final BleEmergencyEnvelope envelope;
          try {
            envelope = BleEmergencyEnvelope.decode(queued.payloadJson);
          } on BleProtocolException catch (error) {
            await repository.updateMessageStatus(queued.messageId, 'expired');
            developer.log(
                'queue.expired role=peripheral id=${queued.messageId} reason=$error',
                name: 'resilience.ble');
            continue;
          }
          if (envelope.hopCount >= envelope.maxHops) {
            await repository.updateMessageStatus(queued.messageId, 'hop_limit');
            continue;
          }
          final ackWaiter = Completer<void>();
          _peripheralAckWaiters[queued.messageId] = ackWaiter;
          try {
            final forwardEntry = envelope
                .forward(senderDeviceId: _deviceId)
                .toQueuedMessage(emergencyLocalId: queued.emergencyLocalId);
            const mtu =
                23; // Server MTU events are not peer-specific in this plugin API.
            final frames = BleFrameCodec.encode(
                queued.messageId, utf8.encode(forwardEntry.payloadJson), mtu);
            await repository.updateMessageStatus(queued.messageId, 'sending',
                attemptedAt: DateTime.now().toUtc());
            developer.log(
                'transfer.send.start role=peripheral message=${queued.messageId} chunks=${frames.length} mtu=$mtu',
                name: 'resilience.ble');
            for (var index = 0; index < frames.length; index++) {
              final frame = frames[index];
              final receiptKey = BleFrameCodec.dataFrameReceiptKey(frame);
              final frameReceipt = Completer<void>();
              _peripheralFrameAckWaiters[receiptKey] = frameReceipt;
              developer.log(
                  'gatt.notify message=${queued.messageId} chunk=${index + 1}/${frames.length} receipt=$receiptKey',
                  name: 'resilience.ble');
              try {
                await _peripheral.sendData(frame,
                    characteristicUuid: sosTxUuid);
                await frameReceipt.future.timeout(const Duration(seconds: 5));
                if (!_running) {
                  throw StateError('BLE session stopped during notification.');
                }
              } on TimeoutException catch (error, stackTrace) {
                developer.log(
                    'gatt.notify.receipt.timeout message=${queued.messageId} chunk=${index + 1}/${frames.length} receipt=$receiptKey elapsed=5s',
                    name: 'resilience.ble',
                    error: error,
                    stackTrace: stackTrace);
                rethrow;
              } finally {
                _peripheralFrameAckWaiters.remove(receiptKey);
              }
            }
            await ackWaiter.future.timeout(const Duration(seconds: 20));
            await repository.updateForwardingEnvelope(forwardEntry);
            final deliveredState =
                envelope.originDeviceId == _deviceId ? 'sent' : 'relayed';
            await repository.updateMessageStatus(
                queued.messageId, deliveredState,
                attemptedAt: DateTime.now().toUtc());
            developer.log(
                'transfer.acknowledged role=peripheral message=${queued.messageId} savedByPeer=true state=$deliveredState',
                name: 'resilience.ble');
          } catch (error, stackTrace) {
            await repository.updateMessageStatus(queued.messageId, 'failed',
                attemptedAt: DateTime.now().toUtc());
            developer.log(
                'transfer.failed role=peripheral message=${queued.messageId} error=$error',
                name: 'resilience.ble',
                stackTrace: stackTrace);
            _status
                .add(BleStatusUpdate(BleStatus.error, _friendlyError(error)));
            return;
          } finally {
            _peripheralAckWaiters.remove(queued.messageId);
          }
        }
      } while (_peripheralRetryRequested && _running);
      await _peripheral.sendData(BleFrameCodec.transferComplete(),
          characteristicUuid: sosTxUuid);
      developer.log('transfer.local_complete role=peripheral',
          name: 'resilience.ble');
    } finally {
      _peripheralSendActive = false;
      _peripheralRetryRequested = false;
    }
  }

  String _friendlyError(Object error) {
    final detail = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    final value = detail.toLowerCase();
    if (value.contains('permission') || value.contains('denied')) {
      return 'Bluetooth permission was denied. Allow Nearby devices in Android settings.';
    }
    if (value.contains('disabled') || value.contains('off')) {
      return 'Bluetooth is off. Turn it on to use nearby SOS forwarding.';
    }
    return 'Bluetooth transfer failed: ${detail.length > 180 ? '${detail.substring(0, 180)}…' : detail}';
  }

  void _reportError(Object error) {
    developer.log('ble.stream.error error=$error',
        name: 'resilience.ble', error: error);
    _status.add(BleStatusUpdate(BleStatus.error, _friendlyError(error)));
  }

  Future<void> stopScanning() async {
    _running = false;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    for (final waiter in _connectionWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _connectionWaiters.clear();
    for (final waiter in _peripheralFrameAckWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await _central.stop();
    } catch (error, stackTrace) {
      developer.log('gatt.scan.stop.failed error=$error',
          name: 'resilience.ble', stackTrace: stackTrace);
    }
    try {
      await _peripheral.stop();
    } catch (error, stackTrace) {
      developer.log('gatt.server.stop.failed error=$error',
          name: 'resilience.ble', stackTrace: stackTrace);
    }
    for (final address in _activeTransfers.toList()) {
      try {
        await _central.disconnect(address);
      } catch (error, stackTrace) {
        developer.log('gatt.disconnect.failed peer=$address error=$error',
            name: 'resilience.ble', stackTrace: stackTrace);
      }
    }
    for (final address in _initializedPeers.toList()) {
      try {
        await _central.disconnect(address);
      } catch (error, stackTrace) {
        developer.log('gatt.disconnect.failed peer=$address error=$error',
            name: 'resilience.ble', stackTrace: stackTrace);
      }
    }
    _initializedPeers.clear();
    _nearby.clear();
    _peers.add(const []);
    if (!_disposed) _status.add(const BleStatusUpdate(BleStatus.stopped));
  }

  /// Retries queued messages to peers already visible on screen. This is also
  /// called after a new SOS is saved, since scan results are not guaranteed to
  /// repeat while the peer remains visible.
  Future<void> retryQueuedMessagesToNearbyPeers() async {
    for (final address in _nearby.keys.toList()) {
      _retryTimers.remove(address)?.cancel();
      _retryAttempts.remove(address);
      if (_activeTransfers.contains(address)) {
        _retryRequestedPeers.add(address);
      } else {
        unawaited(_sendQueuedTo(address));
      }
    }
    unawaited(_trySendFromPeripheral());
  }

  /// Starts a real queued transfer and waits for the receiver's post-persistence
  /// ACK to update the durable delivery state.
  Future<SosSendResult> sendEmergency(String emergencyLocalId) async {
    developer.log(
        'send.manual.start emergency=$emergencyLocalId running=$_running',
        name: 'resilience.ble');
    try {
      if (!_running) await startScanning();
      if (!_running) return SosSendResult.bluetoothUnavailable;
      final requeued = await repository.requeueLocalEmergency(emergencyLocalId);
      if (!requeued &&
          await repository.deliveryStatusForEmergency(emergencyLocalId) !=
              'queued') {
        return SosSendResult.unavailable;
      }
      // Allow Android scan results to arrive when the user presses Send before
      // a peer has appeared in the list.
      for (var i = 0; i < 12 && _nearby.isEmpty && _running; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (_nearby.isEmpty) {
        developer.log('send.manual.no_peer emergency=$emergencyLocalId',
            name: 'resilience.ble');
        return SosSendResult.noNearbyPeer;
      }
      await retryQueuedMessagesToNearbyPeers();
      for (var i = 0; i < 60; i++) {
        final status =
            await repository.deliveryStatusForEmergency(emergencyLocalId);
        if (status == 'sent') {
          developer.log('send.manual.delivered emergency=$emergencyLocalId',
              name: 'resilience.ble');
          return SosSendResult.delivered;
        }
        if (status == 'failed' ||
            status == 'expired' ||
            status == 'hop_limit') {
          developer.log(
              'send.manual.failed emergency=$emergencyLocalId state=$status',
              name: 'resilience.ble');
          return SosSendResult.failed;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final status =
          await repository.deliveryStatusForEmergency(emergencyLocalId);
      developer.log(
          'send.manual.timeout emergency=$emergencyLocalId state=$status',
          name: 'resilience.ble');
      return status == 'sent'
          ? SosSendResult.delivered
          : status == 'failed'
              ? SosSendResult.failed
              : SosSendResult.noNearbyPeer;
    } catch (error, stackTrace) {
      developer.log(
          'send.manual.failed emergency=$emergencyLocalId error=$error',
          name: 'resilience.ble',
          error: error,
          stackTrace: stackTrace);
      return SosSendResult.failed;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stopScanning();
    _disposed = true;
    await _writeSub?.cancel();
    await _notifySub?.cancel();
    await _connectionSub?.cancel();
    await _subscriptionSub?.cancel();
    await _received.close();
    await _status.close();
    await _peers.close();
  }

  /// Creates and persists the outgoing envelope for a locally saved SOS.
  Future<QueuedMessage> queueEmergency(EmergencyCase emergency) async {
    final messageId =
        'sos_${DateTime.now().microsecondsSinceEpoch}_${emergency.localId}';
    final envelope = BleEmergencyEnvelope.fromEmergency(
      emergency,
      messageId: messageId,
      originDeviceId:
          _deviceId ?? await repository.database.getOrCreateDeviceId(),
      senderDeviceId:
          _deviceId ?? await repository.database.getOrCreateDeviceId(),
    );
    final message =
        envelope.toQueuedMessage(emergencyLocalId: emergency.localId);
    await repository.enqueue(message);
    return message;
  }

  static bool _sameUuid(String first, String second) =>
      first.toLowerCase().replaceAll('-', '') ==
      second.toLowerCase().replaceAll('-', '');
}
