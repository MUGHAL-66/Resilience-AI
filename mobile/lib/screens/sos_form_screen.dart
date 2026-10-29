import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/emergency_case.dart';
import '../repositories/emergency_repository.dart';
import '../services/location_service.dart';
import '../services/triage_service.dart';

class SosFormScreen extends StatefulWidget {
  const SosFormScreen({
    super.key,
    required this.repository,
    this.locationService = const GeolocatorLocationService(),
  });

  final EmergencyRepository repository;
  final LocationService locationService;

  @override
  State<SosFormScreen> createState() => _SosFormScreenState();
}

class _SosFormScreenState extends State<SosFormScreen> {
  static const _red = Color(0xFFB4232D);
  static const _ink = Color(0xFF20252B);
  static const _muted = Color(0xFF66717C);
  static const _line = Color(0xFFE3E7EB);
  static const _emergencyTypes = <(String, String, IconData)>[
    ('flood', 'Flood / Flash Flood', Icons.water),
    ('earthquake', 'Earthquake / Collapse', Icons.domain),
    ('medical', 'Medical / Injury', Icons.medical_services_outlined),
    ('trapped_other', 'Trapped / Other', Icons.crisis_alert),
  ];
  static const _injuryTypes = <(String, String)>[
    ('fracture', 'Fracture'),
    ('wound', 'Wound'),
    ('breathing_difficulty', 'Breathing difficulty'),
    ('other', 'Other'),
    ('unknown', 'Unknown'),
  ];
  static const _bleedingOptions = <(String, String)>[
    ('none', 'None'),
    ('minor', 'Minor'),
    ('severe', 'Severe'),
    ('unknown', 'Unknown'),
  ];
  static const _injurySeverityOptions = <(String, String)>[
    ('none', 'None'),
    ('minor', 'Minor'),
    ('major', 'Major'),
    ('unknown', 'Unknown'),
  ];
  static const _consciousnessOptions = <(String, String)>[
    ('conscious', 'Conscious'),
    ('unconscious', 'Unconscious'),
    ('unknown', 'Unknown'),
  ];
  static const _trappedOptions = <(String, String)>[
    ('yes', 'Yes'),
    ('no', 'No'),
    ('unknown', 'Unknown'),
  ];

  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  final _landmarkController = TextEditingController();
  final _detailsController = TextEditingController();
  final _peopleController = TextEditingController();

  String? _emergencyType;
  String _injuryType = 'unknown';
  String _injurySeverity = 'unknown';
  String _bleeding = 'unknown';
  String _consciousness = 'unknown';
  String _trappedStatus = 'unknown';
  Coordinates? _coordinates;
  bool _locationLoading = false;
  String? _locationError;
  bool _saving = false;
  String? _emergencyTypeError;

  @override
  void initState() {
    super.initState();
    unawaited(_captureLocation());
  }

  Future<void> _captureLocation() async {
    if (_locationLoading) return;
    setState(() {
      _locationLoading = true;
      _locationError = null;
    });
    try {
      final result = await widget.locationService.currentCoordinates();
      if (!mounted) return;
      setState(() {
        _coordinates = result;
        _locationError = result == null ? 'Location is unavailable.' : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _coordinates = null;
        _locationError = 'Location is unavailable. You can add a landmark.';
      });
    } finally {
      if (mounted) setState(() => _locationLoading = false);
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final valid = _formKey.currentState?.validate() ?? false;
    if (_emergencyType == null) {
      setState(() => _emergencyTypeError = 'Select the type of emergency.');
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      return;
    }
    if (!valid) {
      setState(() {});
      return;
    }

    setState(() => _saving = true);
    final now = DateTime.now().toUtc();
    final trapped = _trappedStatus == 'yes';
    final suggestion = TriageService().suggest(
      consciousness: _consciousness,
      bleeding: _bleeding,
      trapped: trapped,
    );
    final description = <String>[
      if (_landmarkController.text.trim().isNotEmpty)
        'Location / landmark: ${_landmarkController.text.trim()}',
      if (_detailsController.text.trim().isNotEmpty)
        'Additional details: ${_detailsController.text.trim()}',
    ].join('\n');
    final record = EmergencyCase(
      localId: '${now.microsecondsSinceEpoch}',
      emergencyType: _emergencyType!,
      injuryType: _injurySeverity,
      injuryDetail: _injuryType,
      bleedingStatus: _bleeding,
      consciousnessStatus: _consciousness,
      trapped: trapped,
      trappedStatus: _trappedStatus,
      peopleAffected: int.tryParse(_peopleController.text.trim()),
      description: description,
      latitude: _coordinates?.latitude,
      longitude: _coordinates?.longitude,
      createdAt: now,
      updatedAt: now,
      priority: suggestion.priority,
      syncStatus: 'pending',
    );
    try {
      // Repository.save commits SQLite first and adds the stable BLE queue row.
      await widget.repository.save(record);
      if (mounted) Navigator.pop(context, true);
    } catch (error, stackTrace) {
      debugPrint('SOS local save failed: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save SOS locally. Please try again.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _sectionTitle(String title, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: _ink, fontSize: 18, fontWeight: FontWeight.w700)),
            if (hint != null) ...[
              const SizedBox(height: 3),
              Text(hint, style: const TextStyle(color: _muted, fontSize: 13)),
            ],
          ],
        ),
      );

  Widget _emergencyTypeCards() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _emergencyTypes.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.9,
            ),
            itemBuilder: (context, index) {
              final option = _emergencyTypes[index];
              final selected = _emergencyType == option.$1;
              return Semantics(
                button: true,
                selected: selected,
                label: option.$2,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() {
                    _emergencyType = option.$1;
                    _emergencyTypeError = null;
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFFFFF1F1) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selected ? _red : _line,
                        width: selected ? 1.8 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(option.$3,
                            color: selected ? _red : _muted, size: 22),
                        const SizedBox(height: 6),
                        Text(option.$2,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _ink,
                              fontSize: 13,
                              fontWeight:
                                  selected ? FontWeight.w700 : FontWeight.w600,
                            )),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          if (_emergencyTypeError != null)
            Padding(
              padding: const EdgeInsets.only(top: 7, left: 4),
              child: Text(_emergencyTypeError!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12)),
            ),
        ],
      );

  Widget _choiceChips({
    required String label,
    required String value,
    required List<(String, String)> options,
    required ValueChanged<String> onSelected,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: _ink, fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: options
                .map((option) => ChoiceChip(
                      label: Text(option.$2),
                      selected: value == option.$1,
                      onSelected: (_) => setState(() => onSelected(option.$1)),
                      selectedColor: const Color(0xFFFFE5E6),
                      backgroundColor: Colors.white,
                      side:
                          BorderSide(color: value == option.$1 ? _red : _line),
                      labelStyle: TextStyle(
                        color: value == option.$1 ? _red : _ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ))
                .toList(),
          ),
        ],
      );

  Widget _locationCard() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(
                _coordinates == null
                    ? Icons.location_searching
                    : Icons.location_on,
                color: _coordinates == null ? _muted : const Color(0xFF16805D),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _locationLoading
                            ? 'Getting GPS location…'
                            : _coordinates == null
                                ? (_locationError ?? 'GPS location unavailable')
                                : 'GPS location captured',
                        style: const TextStyle(
                            color: _ink, fontWeight: FontWeight.w700),
                      ),
                      if (_coordinates != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          '${_coordinates!.latitude.toStringAsFixed(5)}, ${_coordinates!.longitude.toStringAsFixed(5)}${_coordinates!.accuracyMeters == null ? '' : '  ·  ±${_coordinates!.accuracyMeters!.round()} m'}',
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                      ],
                    ]),
              ),
              if (_locationLoading)
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                IconButton(
                  tooltip: 'Retry GPS location',
                  onPressed: _captureLocation,
                  icon: const Icon(Icons.refresh),
                ),
            ]),
            const SizedBox(height: 14),
            TextFormField(
              controller: _landmarkController,
              maxLength: 160,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Landmark or location description',
                hintText: 'Street, building, floor, nearby landmark',
                prefixIcon: Icon(Icons.place_outlined),
              ),
            ),
            const Text('SOS can be saved even when GPS is unavailable.',
                style: TextStyle(color: _muted, fontSize: 12)),
          ],
        ),
      );

  @override
  void dispose() {
    _landmarkController.dispose();
    _detailsController.dispose();
    _peopleController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
        data: Theme.of(context).copyWith(
          scaffoldBackgroundColor: const Color(0xFFF5F6F8),
          colorScheme: Theme.of(context).colorScheme.copyWith(
                primary: _red,
                error: _red,
              ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _line)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _line)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _red, width: 1.5)),
            counterStyle: const TextStyle(color: _muted, fontSize: 11),
          ),
        ),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Create SOS'),
            backgroundColor: const Color(0xFFF5F6F8),
            foregroundColor: _ink,
            elevation: 0,
          ),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    controller: _scrollController,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF1F1),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFF4D3D5)),
                        ),
                        child: const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.shield_outlined, color: _red),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Share only what rescuers need. Your SOS saves on this phone first and can be sent to nearby phones over Bluetooth.',
                                style: TextStyle(
                                    color: _ink, height: 1.35, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      _sectionTitle('Emergency type', hint: 'Required'),
                      _emergencyTypeCards(),
                      const SizedBox(height: 24),
                      _sectionTitle('Location',
                          hint: 'GPS is optional; add a landmark if useful.'),
                      _locationCard(),
                      const SizedBox(height: 24),
                      _sectionTitle('Medical condition'),
                      _choiceChips(
                        label: 'Injury type',
                        value: _injuryType,
                        options: _injuryTypes,
                        onSelected: (value) => _injuryType = value,
                      ),
                      const SizedBox(height: 16),
                      _choiceChips(
                        label: 'Injury severity',
                        value: _injurySeverity,
                        options: _injurySeverityOptions,
                        onSelected: (value) => _injurySeverity = value,
                      ),
                      const SizedBox(height: 16),
                      _choiceChips(
                        label: 'Bleeding',
                        value: _bleeding,
                        options: _bleedingOptions,
                        onSelected: (value) => _bleeding = value,
                      ),
                      const SizedBox(height: 16),
                      _choiceChips(
                        label: 'Consciousness',
                        value: _consciousness,
                        options: _consciousnessOptions,
                        onSelected: (value) => _consciousness = value,
                      ),
                      const SizedBox(height: 16),
                      _choiceChips(
                        label: 'Trapped',
                        value: _trappedStatus,
                        options: _trappedOptions,
                        onSelected: (value) => _trappedStatus = value,
                      ),
                      const SizedBox(height: 24),
                      _sectionTitle('People needing help', hint: 'Optional'),
                      TextFormField(
                        controller: _peopleController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Number of people affected',
                          prefixIcon: Icon(Icons.groups_outlined),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return null;
                          }
                          final count = int.tryParse(value.trim());
                          if (count == null || count < 1 || count > 999) {
                            return 'Enter a number from 1 to 999.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      _sectionTitle('Additional details', hint: 'Optional'),
                      TextFormField(
                        controller: _detailsController,
                        maxLength: 800,
                        maxLines: 4,
                        minLines: 3,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'What should rescuers know?',
                          hintText:
                              'Access instructions, immediate hazards, or other useful details',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 56,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: _red,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                            textStyle: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w800),
                          ),
                          icon: _saving
                              ? const SizedBox(
                                  width: 19,
                                  height: 19,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.sos),
                          label: Text(_saving ? 'SAVING SOS…' : 'CREATE SOS'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Saved locally first. Delivery may remain pending until another phone acknowledges receipt.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
