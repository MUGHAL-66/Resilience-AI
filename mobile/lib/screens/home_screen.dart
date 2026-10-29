import 'dart:async';
import 'package:flutter/material.dart';
import '../models/emergency_case.dart';
import '../repositories/emergency_repository.dart';
import 'sos_form_screen.dart';
import '../services/ble_transport.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository});
  final EmergencyRepository repository;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<EmergencyCase> cases = [];
  final Map<String, String?> _deliveryStates = {};
  final Map<String, bool> _localRecords = {};
  final Set<String> _sending = {};
  late final AndroidBleTransport _ble;
  BleStatus _bleStatus = BleStatus.stopped;
  String? _bleMessage;
  List<BlePeer> _peers = const [];
  StreamSubscription<BleStatusUpdate>? _statusSub;
  StreamSubscription<List<BlePeer>>? _peersSub;
  StreamSubscription<dynamic>? _receivedSub;
  Timer? _deliveryRefreshTimer;
  bool _resumeBleWhenActive = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ble = AndroidBleTransport(widget.repository);
    _statusSub = _ble.statusChanges.listen((update) {
      if (mounted) {
        setState(() {
          _bleStatus = update.status;
          _bleMessage = update.message;
        });
        if (update.status == BleStatus.running) {
          _deliveryRefreshTimer ??=
              Timer.periodic(const Duration(seconds: 2), (_) => _load());
        } else if (update.status == BleStatus.stopped) {
          _deliveryRefreshTimer?.cancel();
          _deliveryRefreshTimer = null;
        }
      }
    });
    _peersSub = _ble.nearbyPeers.listen((value) {
      if (mounted) setState(() => _peers = value);
    });
    _receivedSub = _ble.receivedMessages.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSub?.cancel();
    _peersSub?.cancel();
    _receivedSub?.cancel();
    _deliveryRefreshTimer?.cancel();
    _ble.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _resumeBleWhenActive =
          _resumeBleWhenActive || _bleStatus == BleStatus.running;
      _ble.stopScanning();
    } else if (state == AppLifecycleState.resumed && _resumeBleWhenActive) {
      _resumeBleWhenActive = false;
      unawaited(_ble.startScanning().catchError((Object error) {
        // The transport publishes the actionable Bluetooth status and logs
        // the original exception; handle the future at the lifecycle boundary.
      }));
    }
  }

  Future<void> _load() async {
    final values = await widget.repository.listAll();
    final states = <String, String?>{};
    final local = <String, bool>{};
    for (final item in values) {
      states[item.localId] =
          await widget.repository.deliveryStatusForEmergency(item.localId);
      local[item.localId] =
          await widget.repository.isLocallyCreated(item.localId);
    }
    if (mounted) {
      setState(() {
        cases = values;
        _deliveryStates
          ..clear()
          ..addAll(states);
        _localRecords
          ..clear()
          ..addAll(local);
      });
    }
  }

  String _deliveryLabel(EmergencyCase item) {
    if (_localRecords[item.localId] != true) {
      return switch (_deliveryStates[item.localId]) {
        'relayed' => 'Received - saved here and accepted by a nearby relay',
        'sending' => 'Received - saved here; forwarding in progress',
        'failed' => 'Received - saved here; relay retry pending',
        'hop_limit' => 'Received - saved here; relay hop limit reached',
        _ => 'Received - saved on this phone',
      };
    }
    if (_sending.contains(item.localId)) {
      return 'Sending · waiting for receiver confirmation';
    }
    return switch (_deliveryStates[item.localId]) {
      'sent' => 'Peer confirmed SOS save',
      'relayed' => 'Relay peer confirmed SOS save',
      'sending' => 'Sending · waiting for receiver confirmation',
      'failed' => 'Failed · Retry available',
      'expired' => 'Expired · cannot send',
      'hop_limit' => 'Forwarding limit reached',
      _ => 'Pending · saved on this phone',
    };
  }

  String _emergencyTypeLabel(String value) => switch (value) {
        'flood' => 'Flood / Flash Flood',
        'earthquake' => 'Earthquake / Building Collapse',
        'medical' => 'Medical Emergency / Injury',
        _ => 'Trapped / Other',
      };

  Future<void> _send(EmergencyCase item) async {
    if (_sending.contains(item.localId)) return;
    setState(() => _sending.add(item.localId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content:
              Text('Attempting BLE send; waiting for receiver confirmation…')),
    );
    final result = await _ble.sendEmergency(item.localId);
    await _load();
    if (mounted) {
      setState(() => _sending.remove(item.localId));
      final message = switch (result) {
        SosSendResult.delivered =>
          'A nearby phone saved the SOS and acknowledged it.',
        SosSendResult.failed => 'Send failed. Check Bluetooth and retry.',
        SosSendResult.bluetoothUnavailable =>
          'Bluetooth or required permissions are unavailable. SOS remains pending.',
        SosSendResult.noNearbyPeer =>
          'No nearby peer completed the transfer. SOS remains pending; retry when both phones are nearby.',
        SosSendResult.unavailable =>
          'This SOS is already delivered or is not a locally created record.',
      };
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _delete(EmergencyCase item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete local SOS record?'),
        content: const Text(
            'This removes the record and its queue entry from this phone only. It does not cancel or remove copies already sent to other phones.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete local record')),
        ],
      ),
    );
    if (confirmed != true) return;
    final deleted = await widget.repository.deleteLocalEmergency(item.localId);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(deleted
          ? 'Local SOS record deleted.'
          : 'Received SOS records cannot be deleted from this test-record action.'),
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Resilience AI'), actions: [
          IconButton(
            tooltip: 'Refresh emergency list',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
              tooltip: 'Local connection and sync status',
              onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                          title: const Text('Connection status'),
                          content: Text(
                              'SOS records save on this device. Server sync is not configured. ${_bleMessage ?? 'Bluetooth: ${_bleStatus.name}.'}'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'))
                          ])),
              icon: const Icon(Icons.sync))
        ]),
        body: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: const Padding(
                      padding: EdgeInsets.all(20),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Emergency support',
                                style: TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.bold)),
                            SizedBox(height: 8),
                            Text(
                                'Create an SOS on this phone, even when there is no internet connection.')
                          ]))),
              const SizedBox(height: 16),
              FilledButton.icon(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final saved = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute<bool>(
                            builder: (_) =>
                                SosFormScreen(repository: widget.repository)));
                    if (saved != true) return;
                    await _load();
                    if (!mounted) return;
                    messenger.showSnackBar(const SnackBar(
                      content: Text(
                          'Saved locally. Delivery is pending until another phone confirms receipt.'),
                    ));
                    await _ble.retryQueuedMessagesToNearbyPeers();
                  },
                  icon: const Icon(Icons.sos),
                  label: const Text('Create SOS')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _bleStatus == BleStatus.running
                    ? () => _ble.stopScanning()
                    : () async {
                        try {
                          await _ble.startScanning();
                        } catch (_) {
                          /* A status message is shown by the transport. */
                        }
                      },
                icon: Icon(_bleStatus == BleStatus.running
                    ? Icons.bluetooth_disabled
                    : Icons.bluetooth_searching),
                label: Text(_bleStatus == BleStatus.running
                    ? 'Stop nearby SOS'
                    : 'Find nearby SOS devices'),
              ),
              Card(
                child: ListTile(
                  leading: Icon(_bleStatus == BleStatus.running
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth),
                  title: Text(_bleMessage ?? 'Bluetooth ${_bleStatus.name}'),
                  subtitle: Text(_peers.isEmpty
                      ? 'No nearby Resilience AI devices'
                      : '${_peers.length} nearby device(s) · queued SOS messages forward automatically'),
                ),
              ),
              const SizedBox(height: 24),
              Text('Emergency history (${cases.length})',
                  style: Theme.of(context).textTheme.titleLarge),
              if (cases.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No saved emergencies yet.')),
              ...cases.map((item) => Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [
                        ListTile(
                          leading: const Icon(Icons.warning_amber),
                          title: Text(_emergencyTypeLabel(item.emergencyType)),
                          subtitle: Text(
                              '${item.injuryDetail.replaceAll('_', ' ')} · ${item.createdAt.toLocal()} | ${item.latitude == null || item.longitude == null ? 'Location unavailable' : '${item.latitude}, ${item.longitude}'}\n${_deliveryLabel(item)}'),
                          isThreeLine: true,
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                  builder: (_) =>
                                      EmergencyDetailScreen(value: item))),
                        ),
                        if (_localRecords[item.localId] == true)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Row(children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _sending.contains(item.localId) ||
                                          _deliveryStates[item.localId] ==
                                              'sent'
                                      ? null
                                      : () => _send(item),
                                  icon: Icon(
                                      _deliveryStates[item.localId] == 'failed'
                                          ? Icons.replay
                                          : Icons.send),
                                  label: Text(
                                      _deliveryStates[item.localId] == 'failed'
                                          ? 'Retry send'
                                          : 'Send SOS'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Delete local test SOS',
                                onPressed: () => _delete(item),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ]),
                          ),
                      ]),
                    ),
                  )),
            ])),
      );
}

class EmergencyDetailScreen extends StatelessWidget {
  const EmergencyDetailScreen({super.key, required this.value});
  final EmergencyCase value;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Emergency details')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text('Status: ${value.status}'),
        Text('Sync: ${value.syncStatus}'),
        Text('Emergency type: ${value.emergencyType.replaceAll('_', ' ')}'),
        Text('Injury type: ${value.injuryDetail.replaceAll('_', ' ')}'),
        Text('Injury severity: ${value.injuryType}'),
        Text('Bleeding: ${value.bleedingStatus}'),
        Text('Consciousness: ${value.consciousnessStatus}'),
        Text('Trapped: ${value.trappedStatus}'),
        if (value.peopleAffected != null)
          Text('People affected: ${value.peopleAffected}'),
        Text(
            'Description: ${value.description.isEmpty ? 'None provided' : value.description}'),
        Text(
            'Location: ${value.latitude == null || value.longitude == null ? 'Location unavailable' : '${value.latitude}, ${value.longitude}'}'),
        Text('Created: ${value.createdAt.toLocal()}')
      ]));
}
