class AddressSuggestion {
  final String label;
  final String url;
  final AddressSuggestionKind kind;

  const AddressSuggestion({
    required this.label,
    required this.url,
    required this.kind,
  });
}

enum AddressSuggestionKind { history, favorite, search }
