import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/aurora_tokens.dart';
import 'pro_entitlement.dart';

/// A predefined accent colour pack applied on top of the base Aurora palette.
///
/// Free users can use the default pack; Pro+ unlocks the rest. Each pack
/// defines dark + light primary/secondary/tertiary hues that recolor:
/// accents, media-type chips, tab-group hues, and a light surface tint.
///
/// ## Adding a new accent pack
/// 1. Add a new [AccentPack] const here with dark and light colours.
/// 2. Register it in [kProAccentPacks] (or free list if ungated).
/// 3. Gate via [ProFeature.themePack] unless free.
class AccentPack {
  final String id;
  final String label;

  /// Primary action / frost role (dark mode).
  final Color primary;

  /// Secondary / purple role (dark mode).
  final Color secondary;

  /// Tertiary / amber role (dark mode).
  final Color tertiary;

  /// Primary on light surfaces (deepened for AA on white).
  final Color primaryLight;

  /// Secondary on light surfaces.
  final Color secondaryLight;

  /// Tertiary on light surfaces.
  final Color tertiaryLight;

  const AccentPack({
    required this.id,
    required this.label,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.primaryLight,
    required this.secondaryLight,
    required this.tertiaryLight,
  });

  Color primaryFor(bool isLight) => isLight ? primaryLight : primary;
  Color secondaryFor(bool isLight) => isLight ? secondaryLight : secondary;
  Color tertiaryFor(bool isLight) => isLight ? tertiaryLight : tertiary;

  /// Swatch colors for the Appearance picker (dark-mode hues).
  List<Color> get swatchColors => [primary, secondary, tertiary];
}

/// Default accent — matches [AColors.dark] / [AColors.light] accents exactly
/// so selecting it is identity (no tint drift).
const AccentPack kDefaultAccent = AccentPack(
  id: 'frost',
  label: 'Nord Frost',
  primary: Color(0xFF88C0D0), // nord8 — matches dark accentFrost
  secondary: Color(0xFFB48EAD), // nord15
  tertiary: Color(0xFFEBCB8B), // nord13
  primaryLight: Color(0xFF3D6C9A),
  secondaryLight: Color(0xFF8F6A85),
  tertiaryLight: Color(0xFFA35A00),
);

/// Pro-only accent packs — designed families, not raw Nord dumps.
const List<AccentPack> kProAccentPacks = [
  // Green primary + frost teal secondary + gold tertiary.
  // (Previously mis-paired green with error red as secondary.)
  AccentPack(
    id: 'aurora',
    label: 'Aurora Green',
    primary: Color(0xFFA3BE8C), // nord14
    secondary: Color(0xFF88C0D0), // nord8 teal
    tertiary: Color(0xFFEBCB8B), // nord13 gold
    primaryLight: Color(0xFF4F7A3A),
    secondaryLight: Color(0xFF3D6C9A),
    tertiaryLight: Color(0xFFA35A00),
  ),
  AccentPack(
    id: 'sunset',
    label: 'Warm Sunset',
    primary: Color(0xFFD08770), // nord12 orange
    secondary: Color(0xFFEBCB8B), // nord13 gold
    tertiary: Color(0xFFBF616A), // nord11 coral (accent, not status)
    primaryLight: Color(0xFFC45C3E),
    secondaryLight: Color(0xFFA35A00),
    tertiaryLight: Color(0xFFA12D2D),
  ),
  AccentPack(
    id: 'deep_purple',
    label: 'Deep Purple',
    primary: Color(0xFFB48EAD), // nord15
    secondary: Color(0xFF81A1C1), // nord9 blue
    tertiary: Color(0xFFD4778E), // soft pink
    primaryLight: Color(0xFF8F6A85),
    secondaryLight: Color(0xFF3D6C9A),
    tertiaryLight: Color(0xFFB04868),
  ),
];

String? _activeAccentId;

/// Top-level notifier for accent pack changes. Fired when the user selects
/// a new accent pack so [MyApp] can rebuild [AuroraTheme] live.
final ValueNotifier<String?> appAccentPackNotifier =
    ValueNotifier<String?>(_activeAccentId);

/// Loads stored accent pack preference from disk.
Future<void> loadSavedAccentPack() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/accent_pack.json');
    if (await file.exists()) {
      final text = await file.readAsString();
      final data = jsonDecode(text);
      if (data is Map && data['accent_id'] is String) {
        _activeAccentId = data['accent_id'] as String;
        appAccentPackNotifier.value = _activeAccentId;
      }
    }
  } catch (_) {}
}

/// Saves the selected accent pack preference to disk.
Future<void> saveAccentPack(String id) async {
  _activeAccentId = id;
  appAccentPackNotifier.value = id;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/accent_pack.json');
    await file.writeAsString(jsonEncode({'accent_id': id}));
  } catch (_) {}
}

/// All packs shown in Appearance. Free users see Pro packs locked.
List<AccentPack> availableAccentPacks(EntitlementTier tier) {
  // Always list every pack so Free users can see (and upsell) Pro options.
  // Selection is gated at the picker via [ProFeature.themePack].
  return [kDefaultAccent, ...kProAccentPacks];
}

/// Returns the currently active accent pack, falling back to [kDefaultAccent].
AccentPack activeAccentPack() {
  if (_activeAccentId == null) return kDefaultAccent;
  final all = [kDefaultAccent, ...kProAccentPacks];
  return all.firstWhere(
    (p) => p.id == _activeAccentId,
    orElse: () => kDefaultAccent,
  );
}

String? get activeAccentId => _activeAccentId;

set activeAccentId(String? id) {
  _activeAccentId = id;
}

Color _tint(Color base, Color accent, double amount) =>
    Color.lerp(base, accent, amount)!;

/// Builds light or dark [AColors] with [pack] applied across accents,
/// media chips, tab groups, and a subtle surface/gradient tint.
///
/// Semantic status colors (success / error) stay fixed for accessibility.
AColors colorsForAccentPack(AccentPack pack, {required bool isLight}) {
  final base = isLight ? AColors.light() : AColors.dark();
  // Identity: default pack matches the base factories bit-for-bit.
  if (pack.id == kDefaultAccent.id) return base;

  final p = pack.primaryFor(isLight);
  final s = pack.secondaryFor(isLight);
  final t = pack.tertiaryFor(isLight);

  // Surface tint strength: keep light mode quieter for AA on snowfields.
  final surfaceAmt = isLight ? 0.05 : 0.09;
  final borderAmt = isLight ? 0.10 : 0.16;
  final gradientAmt = isLight ? 0.04 : 0.08;

  return base.copyWithAccent(
    accentFrost: p,
    accentPurple: s,
    accentAmber: t,
    // Media chips — follow the pack family so the radar / queue feel themed.
    mediaVideo: p,
    mediaAudio: s,
    mediaHls: t,
    mediaImage: _tint(base.mediaImage, p, 0.45),
    mediaOther: _tint(base.mediaOther, p, 0.35),
    mediaTorrent: _tint(base.mediaTorrent, s, 0.40),
    // Tab groups — recolor the accent-adjacent slots; keep red/green
    // distinguishable for status-like group labels.
    groupCyan: p,
    groupPurple: s,
    groupAmber: t,
    groupBlue: _tint(p, s, 0.35),
    groupOrange: _tint(t, p, 0.30),
    groupPink: _tint(s, t, 0.40),
    groupGreen: _tint(base.groupGreen, p, 0.25),
    groupRed: _tint(base.groupRed, t, 0.20),
    // Quiet chrome shift so panels / sheets feel on-pack.
    surfaceElevated: _tint(base.surfaceElevated, p, surfaceAmt),
    borderStrong: _tint(base.borderStrong, p, borderAmt),
    gradientSheetTop: _tint(base.gradientSheetTop, p, gradientAmt),
    gradientSheetBottom: _tint(base.gradientSheetBottom, p, gradientAmt + 0.02),
    gradientMid: _tint(base.gradientMid, p, gradientAmt),
    glassBorder: _tint(base.glassBorder, p, isLight ? 0.08 : 0.12),
  );
}
