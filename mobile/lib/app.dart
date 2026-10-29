import 'package:flutter/material.dart';
import 'database/app_database.dart';
import 'repositories/emergency_repository.dart';
import 'screens/home_screen.dart';

class ResilienceApp extends StatelessWidget {
  const ResilienceApp({super.key, this.repository});

  final EmergencyRepository? repository;

  @override
  Widget build(BuildContext context) {
    final emergencyRepository = repository ?? EmergencyRepository(AppDatabase.instance);
    return MaterialApp(
      title: 'Resilience AI',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B5961), brightness: Brightness.light), useMaterial3: true),
      home: HomeScreen(repository: emergencyRepository),
    );
  }
}
