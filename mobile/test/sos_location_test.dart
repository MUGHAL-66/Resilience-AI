import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resilience_ai/database/app_database.dart';
import 'package:resilience_ai/models/emergency_case.dart';
import 'package:resilience_ai/repositories/emergency_repository.dart';
import 'package:resilience_ai/screens/sos_form_screen.dart';
import 'package:resilience_ai/services/location_service.dart';

class FakeLocationService implements LocationService {
  FakeLocationService(this.result);
  final Future<Coordinates?> Function() result;

  @override
  Future<Coordinates?> currentCoordinates() => result();
}

class FakeEmergencyRepository extends EmergencyRepository {
  FakeEmergencyRepository() : super(AppDatabase());
  final saved = <EmergencyCase>[];

  @override
  Future<void> save(EmergencyCase emergency) async => saved.add(emergency);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeEmergencyRepository repository;
  setUp(() => repository = FakeEmergencyRepository());

  Future<void> submit(WidgetTester tester, LocationService location) async {
    await tester.pumpWidget(MaterialApp(
        home:
            SosFormScreen(repository: repository, locationService: location)));
    await tester.tap(find.text('Flood / Flash Flood'));
    await tester.scrollUntilVisible(find.text('CREATE SOS'), 400,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('CREATE SOS'));
    await tester.pumpAndSettle();
  }

  testWidgets('saves SOS with captured coordinates', (tester) async {
    await submit(tester,
        FakeLocationService(() async => const Coordinates(24.86, 67.01)));
    expect(repository.saved.single.latitude, 24.86);
    expect(repository.saved.single.longitude, 67.01);
    expect(repository.saved.single.emergencyType, 'flood');
    expect(repository.saved.single.trappedStatus, 'unknown');
  });

  testWidgets('saves SOS when location is unavailable', (tester) async {
    await submit(tester, FakeLocationService(() async => null));
    expect(repository.saved.single.latitude, isNull);
    expect(repository.saved.single.longitude, isNull);
  });

  testWidgets('location failure does not prevent local saving', (tester) async {
    await submit(tester,
        FakeLocationService(() async => throw Exception('permission denied')));
    expect(repository.saved, hasLength(1));
  });

  testWidgets('requires emergency type before saving', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SosFormScreen(
        repository: repository,
        locationService: FakeLocationService(() async => null),
      ),
    ));
    await tester.scrollUntilVisible(find.text('CREATE SOS'), 400,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('CREATE SOS'));
    await tester.pumpAndSettle();
    expect(find.text('Select the type of emergency.'), findsOneWidget);
    expect(repository.saved, isEmpty);
  });

  testWidgets(
      'persists medical selections, count, and landmark when GPS is absent',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SosFormScreen(
        repository: repository,
        locationService: FakeLocationService(() async => null),
      ),
    ));
    await tester.tap(find.text('Medical / Injury'));
    await tester.scrollUntilVisible(find.text('Fracture'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Fracture'));
    await tester.scrollUntilVisible(
        find.text('Landmark or location description'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Landmark or location description'),
        'North clinic entrance');
    await tester.scrollUntilVisible(find.text('Number of people affected'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Number of people affected'), '3');
    await tester.scrollUntilVisible(find.text('CREATE SOS'), 400,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('CREATE SOS'));
    await tester.pumpAndSettle();

    final saved = repository.saved.single;
    expect(saved.emergencyType, 'medical');
    expect(saved.injuryType, 'unknown');
    expect(saved.injuryDetail, 'fracture');
    expect(saved.peopleAffected, 3);
    expect(saved.description, contains('North clinic entrance'));
    expect(saved.latitude, isNull);
  });
}
