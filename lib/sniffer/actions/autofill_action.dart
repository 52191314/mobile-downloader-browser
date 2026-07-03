// Standalone library — extracted from `sniffer_screen.dart` during Phase 5 of
// the refactorization. Provides the autofill-profile editor dialog
// (`editAutofillProfile`) and its save flow.

import 'package:flutter/material.dart';

import 'package:aurora_downloader/sniffer/autofill_store.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';

/// Shows the autofill profile editor (new or existing profile). Replaces
/// the body of `_SnifferScreenState._editAutofillProfile`.
///
/// [autofillStore] is the persistent JSON store.
/// [autofillProfiles] is the current in-memory list shown in the
/// autofill picker — when the user saves a new profile the state class
/// receives the updated list through [onProfilesChanged] and rebuilds.
Future<void> editAutofillProfile(
  BuildContext context, {
  required AutofillProfile? existing,
  required AutofillStore autofillStore,
  required List<AutofillProfile> autofillProfiles,
  required BrowserTab activeTab,
  required bool isMounted,
  required void Function(List<AutofillProfile>) onProfilesChanged,
}) async {
  // `activeTab` is currently unused by the editor but kept in the
  // signature so the call site mirrors the original method's signature
  // and a future "use page origin" enhancement can wire it in.
  // ignore: unused_local_variable
  final tab = activeTab;
  final isNew = existing == null;
  final p =
      existing ??
      AutofillProfile(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        label: 'Default',
      );
  final labelCtl = TextEditingController(text: p.label);
  final nameCtl = TextEditingController(text: p.fullName);
  final emailCtl = TextEditingController(text: p.email);
  final phoneCtl = TextEditingController(text: p.phone);
  final addr1Ctl = TextEditingController(text: p.addressLine1);
  final addr2Ctl = TextEditingController(text: p.addressLine2);
  final cityCtl = TextEditingController(text: p.city);
  final stateCtl = TextEditingController(text: p.state);
  final zipCtl = TextEditingController(text: p.postalCode);
  final countryCtl = TextEditingController(text: p.country);
  final cardNameCtl = TextEditingController(text: p.cardName);
  final cardNumCtl = TextEditingController(text: p.cardNumber);
  final cardExpCtl = TextEditingController(text: p.cardExpiry);
  var includeCard = p.includeCard;
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(isNew ? 'New autofill profile' : 'Edit profile'),
      content: StatefulBuilder(
        builder: (ctx, setLocal) => SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: labelCtl,
                  decoration: const InputDecoration(
                    labelText: 'Label',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: emailCtl,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: phoneCtl,
                  decoration: const InputDecoration(
                    labelText: 'Phone',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: addr1Ctl,
                  decoration: const InputDecoration(
                    labelText: 'Address line 1',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: addr2Ctl,
                  decoration: const InputDecoration(
                    labelText: 'Address line 2',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: cityCtl,
                        decoration: const InputDecoration(
                          labelText: 'City',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: stateCtl,
                        decoration: const InputDecoration(
                          labelText: 'State',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: zipCtl,
                        decoration: const InputDecoration(
                          labelText: 'Postal code',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: countryCtl,
                        decoration: const InputDecoration(
                          labelText: 'Country',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include card details'),
                  subtitle: const Text('CVV is never stored'),
                  value: includeCard,
                  onChanged: (value) => setLocal(() => includeCard = value),
                ),
                if (includeCard) ...[
                  TextField(
                    controller: cardNameCtl,
                    decoration: const InputDecoration(
                      labelText: 'Cardholder name',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: cardNumCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Card number',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: cardExpCtl,
                    decoration: const InputDecoration(
                      labelText: 'Card expiry (MM/YY)',
                      isDense: true,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (saved != true) {
    for (final c in [
      labelCtl,
      nameCtl,
      emailCtl,
      phoneCtl,
      addr1Ctl,
      addr2Ctl,
      cityCtl,
      stateCtl,
      zipCtl,
      countryCtl,
      cardNameCtl,
      cardNumCtl,
      cardExpCtl,
    ]) {
      c.dispose();
    }
    return;
  }
  final updated = p.copyWith(
    label: labelCtl.text.trim().isEmpty ? 'Default' : labelCtl.text.trim(),
    fullName: nameCtl.text.trim(),
    email: emailCtl.text.trim(),
    phone: phoneCtl.text.trim(),
    addressLine1: addr1Ctl.text.trim(),
    addressLine2: addr2Ctl.text.trim(),
    city: cityCtl.text.trim(),
    state: stateCtl.text.trim(),
    postalCode: zipCtl.text.trim(),
    country: countryCtl.text.trim(),
    cardName: cardNameCtl.text.trim(),
    cardNumber: cardNumCtl.text.trim(),
    cardExpiry: cardExpCtl.text.trim(),
    includeCard: includeCard,
  );
  for (final c in [
    labelCtl,
    nameCtl,
    emailCtl,
    phoneCtl,
    addr1Ctl,
    addr2Ctl,
    cityCtl,
    stateCtl,
    zipCtl,
    countryCtl,
    cardNameCtl,
    cardNumCtl,
    cardExpCtl,
  ]) {
    c.dispose();
  }
  final list = List<AutofillProfile>.from(autofillProfiles);
  if (isNew) {
    list.add(updated);
  } else {
    final idx = list.indexWhere((profile) => profile.id == updated.id);
    if (idx >= 0) {
      list[idx] = updated;
    } else {
      list.add(updated);
    }
  }
  await autofillStore.save(list);
  if (isMounted) {
    onProfilesChanged(list);
  }
}
