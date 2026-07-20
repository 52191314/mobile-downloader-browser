import 'package:flutter/material.dart';

import 'pro_entitlement.dart';
import 'pro_features.dart';

/// A predefined accent colour pack that can be applied on top of the base
/// Aurora palette.  Free users get a single accent (Nord Frost/cyan).
/// Pro+ unlocks additional accent packs.
///
/// ## Adding a new accent pack
/// 1. Add a new [AccentPack] const here with your colours.
/// 2. Add its [ProFeature] entry (or reuse themePack for all extras).
/// 3. Register in [availableAccentPacks].
class AccentPack {
  final String id;
  final String label;
  final Color primary;
  final Color secondary;

  const AccentPack({
    required this.id,
    required this.label,
    required this.primary,
    required this.secondary,
  });
}

/// The default accent (always available, no gate).
const AccentPack kDefaultAccent = AccentPack(
  id: 'frost',
  label: 'Nord Frost',
  primary: Color(0xFF5E81AC), // nord10
  secondary: Color(0xFF88C0D0), // nord8
);

/// Pro-only accent packs.
const List<AccentPack> kProAccentPacks = [
  AccentPack(
    id: 'aurora',
    label: 'Aurora Green',
    primary: Color(0xFFA3BE8C), // nord14
    secondary: Color(0xFFBF616A), // nord11
  ),
  AccentPack(
    id: 'sunset',
    label: 'Warm Sunset',
    primary: Color(0xFFD08770), // nord12
    secondary: Color(0xFFEBCB8B), // nord13
  ),
  AccentPack(
    id: 'deep_purple',
    label: 'Deep Purple',
    primary: Color(0xFFB48EAD), // nord15
    secondary: Color(0xFF81A1C1), // nord9
  ),
];

/// Returns all accent packs visible to the current user.  Free users get
/// only [kDefaultAccent]; Pro+ users see all.
List<AccentPack> availableAccentPacks(EntitlementTier tier) {
  if (tier.isAtLeastPro) {
    return [kDefaultAccent, ...kProAccentPacks];
  }
  return [kDefaultAccent];
}

/// Persisted accent pack id.  Null = use default.
/// TODO(P13): wire into AColors factory and AuroraPalette construction.
String? _activeAccentId;

String? get activeAccentId => _activeAccentId;

set activeAccentId(String? id) {
  _activeAccentId = id;
  // TODO(P13): persist via DownloadSettingsStore or dedicated
  // accent_settings.json; rebuild AuroraPalette by updating MaterialApp.
}
