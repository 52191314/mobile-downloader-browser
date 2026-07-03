import 'dart:async';

import 'package:flutter/material.dart';

import '../browser_search.dart';
import '../models/address_suggestion.dart';
import '../models/browser_tab.dart';
import '../browser_library.dart';
import '../search_suggestion_service.dart';
import '../../settings/download_settings.dart';

/// Manages address bar state: expanded/collapsed, URL suggestions, debounced
/// search queries.
///
/// Dependencies are passed as method parameters rather than constructor
/// arguments to keep this controller usable without owning widgets or tabs.
class AddressBarController {
  bool addressExpanded = false;
  final List<AddressSuggestion> suggestions = [];
  Timer? _suggestionDebounce;
  int _suggestionRequestId = 0;
  final SearchSuggestionService _searchSuggestionService =
      SearchSuggestionService();

  AddressBarController();

  // ---------------------------------------------------------------------------
  // Address input
  // ---------------------------------------------------------------------------

  /// Process the typed address: resolve input, trigger URL load.
  void loadAddress(
    String address, {
    required BrowserTab tab,
    required SearchEngine searchEngine,
    required void Function(BrowserTab, Uri) loadUrl,
    required VoidCallback onRebuild,
  }) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return;

    var uri = Uri.tryParse(trimmed);
    uri ??= BrowserSearch.resolveInput(trimmed, searchEngine);
    if (!uri.hasScheme || uri.host.isEmpty) {
      uri = BrowserSearch.resolveInput(trimmed, searchEngine);
    }
    loadUrl(tab, uri);
    addressExpanded = false;
    suggestions.clear();
    onRebuild();
  }

  /// Clear all suggestions.
  void clearSuggestions() {
    _suggestionDebounce?.cancel();
    suggestions.clear();
  }

  /// Handle address text changes.
  void onAddressChanged({
    required BrowserTab tab,
    required VoidCallback rebuild,
    BrowserLibrary? library,
    SearchEngine? searchEngine,
  }) {
    if (!addressExpanded) {
      clearSuggestions();
      return;
    }
    final text = tab.addressController.text;
    if (text.trim().isEmpty) {
      suggestions.clear();
      rebuild();
      return;
    }
    _suggestionDebounce?.cancel();
    _suggestionDebounce = Timer(const Duration(milliseconds: 220), () {
      unawaited(_refreshAddressSuggestions(
        text,
        rebuild: rebuild,
        tab: tab,
        library: library,
        searchEngine: searchEngine,
      ));
    });
  }

  Future<void> _refreshAddressSuggestions(
    String raw, {
    required VoidCallback rebuild,
    required BrowserTab tab,
    BrowserLibrary? library,
    SearchEngine? searchEngine,
  }) async {
    final query = raw.trim();
    if (query.isEmpty) {
      suggestions.clear();
      rebuild();
      return;
    }
    final local = _localAddressSuggestions(query, library);
    final requestId = ++_suggestionRequestId;
    suggestions
      ..clear()
      ..addAll(local);
    rebuild();

    final looksLikeUrl =
        Uri.tryParse(query) != null &&
        (query.contains('://') || query.contains('.') || query.contains(' '));
    if (looksLikeUrl) return;

    final remote = await _searchSuggestionService.suggestions(query);
    if (requestId != _suggestionRequestId) return;
    suggestions
      ..removeWhere((s) => s.kind == AddressSuggestionKind.search)
      ..addAll(
        remote.map(
          (q) => AddressSuggestion(
            label: q,
            url: (searchEngine ?? SearchEngine.google).buildSearchUrl(q),
            kind: AddressSuggestionKind.search,
          ),
        ),
      );
    rebuild();
  }

  List<AddressSuggestion> _localAddressSuggestions(
    String query,
    BrowserLibrary? library,
  ) {
    if (library == null) return const [];
    final q = query.toLowerCase();
    final seen = <String>{};
    final out = <AddressSuggestion>[];

    void add(String label, String url, AddressSuggestionKind kind) {
      final key = url.toLowerCase();
      if (seen.add(key) && out.length < 8) {
        out.add(AddressSuggestion(label: label, url: url, kind: kind));
      }
    }

    for (final fav in library.favorites) {
      if (fav.title.toLowerCase().contains(q) ||
          fav.url.toLowerCase().contains(q)) {
        add(
          fav.title.isEmpty ? fav.url : fav.title,
          fav.url,
          AddressSuggestionKind.favorite,
        );
      }
    }
    for (final entry in library.history) {
      if (entry.title.toLowerCase().contains(q) ||
          entry.url.toLowerCase().contains(q)) {
        add(
          entry.title.isEmpty ? entry.url : entry.title,
          entry.url,
          AddressSuggestionKind.history,
        );
      }
    }
    return out;
  }

  /// Accept a suggestion from the list.
  void acceptSuggestion(
    AddressSuggestion suggestion, {
    required BrowserTab tab,
    required void Function(BrowserTab, Uri) loadUrl,
    required VoidCallback onRebuild,
  }) {
    tab.addressController.text = suggestion.url;
    final uri = Uri.tryParse(suggestion.url);
    if (uri != null) {
      loadUrl(tab, uri);
    }
    addressExpanded = false;
    suggestions.clear();
    onRebuild();
  }

  // ---------------------------------------------------------------------------
  // Display helpers
  // ---------------------------------------------------------------------------

  /// Get the display label for the address bar.
  String addressLabel(BrowserTab tab) {
    final raw = tab.addressController.text.trim();
    if (raw.isEmpty) return '';
    if (addressExpanded) return raw;
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.host.isNotEmpty) {
      // Show host + path (minus scheme) so the user can see the full URL
      // they are currently on. The Text widget handles overflow via ellipsis.
      final path = uri.path.isEmpty ? '' : uri.path;
      final query = uri.query.isEmpty ? '' : '?${uri.query}';
      final fragment = uri.fragment.isEmpty ? '' : '#${uri.fragment}';
      return '${uri.host}$path$query$fragment';
    }
    return raw;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  void dispose() {
    _suggestionDebounce?.cancel();
    _searchSuggestionService.dispose();
  }
}
