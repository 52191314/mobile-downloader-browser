// AuroraPalette — palette resolution layer.
//
// Wraps a widget subtree with a single source-of-truth color palette that
// depends on the current `Theme.brightness`. Widgets read colors via
// `AuroraPalette.of(context).accentFrost` or the `context.ac` extension.
//
// The InheritedWidget is updated when the user toggles the theme via
// Settings: the `MaterialApp` rebuilds with the new ThemeData and the
// InheritedWidget value, which ripples to every leaf.

import 'package:flutter/material.dart';

import 'aurora_tokens.dart';

/// Single subtree-scoped palette container. Place at the root under
/// `MaterialApp.builder` so all descendants can resolve colors.
class AuroraPalette extends InheritedWidget {
  /// Resolved color set for the current `Brightness`.
  final AColors colors;

  /// Convenience flag — true when light theme is active.
  final bool isLight;

  const AuroraPalette({
    super.key,
    required this.colors,
    required this.isLight,
    required super.child,
  });

  /// Resolve the palette for `context`. Asserts presence to surface wiring
  /// bugs early.
  static AColors of(BuildContext context) {
    final palette = context
        .dependOnInheritedWidgetOfExactType<AuroraPalette>();
    assert(
      palette != null,
      'AuroraPalette not found in widget tree. Wrap your app with '
      'AuroraPalette(...).',
    );
    return palette!.colors;
  }

  /// True if the palette is the light variant. Forwards [AuroraPalette.of]
  /// so dependents are tracked.
  static bool isLightPalette(BuildContext context) {
    final palette = context
        .dependOnInheritedWidgetOfExactType<AuroraPalette>();
    return palette?.isLight ?? false;
  }

  /// ColorScheme derived from the palette. Useful for Material 3 widgets
  /// (chips, switches, FAB) that expect a ColorScheme.
  static ColorScheme colorSchemeOf(BuildContext context) {
    final palette = of(context);
    final isLight = AuroraPalette.isLightPalette(context);
    return ColorScheme(
      brightness: isLight ? Brightness.light : Brightness.dark,
      primary: palette.accentFrost,
      onPrimary: isLight
          ? palette.surfacePanel
          : palette.surfaceField,
      secondary: palette.accentPurple,
      onSecondary: isLight
          ? palette.surfacePanel
          : palette.surfaceField,
      error: palette.statusError,
      onError: palette.surfacePanel,
      surface: palette.surfacePanel,
      onSurface: palette.textPrimary,
      surfaceContainerHighest: palette.surfaceElevated,
      outline: palette.borderStrong,
      outlineVariant: palette.borderHairline,
    );
  }

  @override
  bool updateShouldNotify(AuroraPalette oldWidget) =>
      colors != oldWidget.colors || isLight != oldWidget.isLight;
}

/// Convenience getter — `context.ac.textPrimary`.
extension AuroraContextX on BuildContext {
  AColors get ac => AuroraPalette.of(this);

  /// The light/dark flag for the current palette.
  bool get isLight => AuroraPalette.isLightPalette(this);

  /// Material 3 ColorScheme derived from the palette.
  ColorScheme get auroraColorScheme => AuroraPalette.colorSchemeOf(this);
}
