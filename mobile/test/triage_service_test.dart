import 'package:flutter_test/flutter_test.dart';
import 'package:resilience_ai/services/triage_service.dart';

void main() {
  test('unknown inputs do not trigger high-risk claims', () {
    final result = TriageService().suggest(consciousness: 'unknown', bleeding: 'unknown', trapped: false);
    expect(result.priority, 'review');
    expect(result.factors, isEmpty);
    expect(result.label, contains('human review'));
  });
}
