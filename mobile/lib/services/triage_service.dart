class TriageSuggestion {
  const TriageSuggestion(this.priority, this.factors);
  final String priority;
  final List<String> factors;
  String get label => 'Assistance suggestion only; human review required';
}

/// Transparent baseline rules; this is not a diagnosis or trained AI model.
class TriageService {
  TriageSuggestion suggest({required String consciousness, required String bleeding, required bool trapped}) {
    final factors = <String>[];
    if (consciousness == 'unconscious') factors.add('Person reported unconscious');
    if (bleeding == 'severe') factors.add('Severe bleeding reported');
    if (trapped) factors.add('Person reported trapped');
    return TriageSuggestion(factors.isEmpty ? 'review' : 'urgent_review', factors);
  }
}
