// Aurora theme builder.
//
// Centralizes the construction of ThemeData for both dark and light modes.
// Reads from the [AColors] token classes via [AuroraPalette] so the build is
// palette-driven. Adds a deliberate TextTheme (Inter weights, tighter
// display tracking) and a "frost line" hairline card border pattern that
// gives Light mode its quiet Scandinavian signature — no card shadow, a
// 1px accent edge instead.

import 'package:flutter/material.dart';

import '../premium/accent_pack.dart';
import 'aurora_palette.dart';
import 'aurora_tokens.dart';

/// Build the dark-mode ThemeData (Nord Aurora Glass).
///
/// When [isOled] is true the scaffold background is pure black for OLED
/// power savings.
ThemeData buildDarkTheme({bool isOled = false, AColors? colors}) {
  final c = colors ?? AColors.dark();
  final bg = isOled ? c.oledBlack : c.surfaceField;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: c.accentFrost,
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: bg,
    canvasColor: c.surfaceField,
    fontFamily: 'Inter',
    textTheme: _buildTextTheme(
      primary: c.textPrimary,
      secondary: c.textSecondary,
      tertiary: c.textTertiary,
      disabled: c.textDisabled,
      monoFamily: 'JetBrainsMono',
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.surfacePanel,
      foregroundColor: c.textPrimary,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        color: c.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.accentFrost, width: 1),
      ),
      hintStyle: TextStyle(
        fontFamily: 'Inter',
        color: c.textSecondary,
      ),
    ),
    cardTheme: CardThemeData(
      color: c.glassSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.glassBorder, width: 1),
      ),
    ),
    bottomAppBarTheme: BottomAppBarThemeData(
      color: c.dockSurface,
      elevation: 0,
      shape: const CircularNotchedRectangle(),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accentFrost,
      linearTrackColor: c.surfaceElevated,
      circularTrackColor: c.surfaceElevated,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.accentFrost,
      inactiveTrackColor: c.surfaceElevated,
      thumbColor: c.accentFrost,
      overlayColor: c.accentFrost.withValues(alpha: 0.14),
    ),
    navigationBarTheme: _buildNavigationBarTheme(c, indicatorAlpha: 0.22),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surfacePanel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.borderHairline, width: 1),
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        color: c.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      contentTextStyle: TextStyle(
        fontFamily: 'Inter',
        color: c.textSecondary,
        fontSize: 14,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surfacePanel,
      modalBackgroundColor: c.surfacePanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      showDragHandle: true,
      dragHandleColor: c.borderHairline,
    ),
    iconTheme: IconThemeData(color: c.textPrimary),
    dividerTheme: DividerThemeData(
      color: c.borderHairline,
      thickness: 1,
      space: 1,
    ),
    splashFactory: InkSparkle.splashFactory,
    splashColor: c.accentFrost.withValues(alpha: 0.16),
    highlightColor: c.accentFrost.withValues(alpha: 0.08),
  );
}

/// Build the light-mode ThemeData (Nord Snow Storm).
ThemeData buildLightTheme({AColors? colors}) {
  final c = colors ?? AColors.light();
  final colorScheme = ColorScheme.fromSeed(
    seedColor: c.accentFrost,
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: c.surfaceField,
    canvasColor: c.surfaceField,
    fontFamily: 'Inter',
    textTheme: _buildTextTheme(
      primary: c.textPrimary,
      secondary: c.textSecondary,
      tertiary: c.textTertiary,
      disabled: c.textDisabled,
      monoFamily: 'JetBrainsMono',
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.surfacePanel,
      foregroundColor: c.textPrimary,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        color: c.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.accentFrost, width: 1.2),
      ),
      hintStyle: TextStyle(
        fontFamily: 'Inter',
        color: c.textSecondary,
      ),
    ),
    cardTheme: CardThemeData(
      color: c.glassSurface,
      elevation: 0,
      // The "frost line" — 1px hairline, the structural separation that
      // replaces shadows in light mode. A faint accent tint (12%) anchors
      // cards to the brand even on white.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.borderHairline, width: 1),
      ),
    ),
    bottomAppBarTheme: BottomAppBarThemeData(
      color: c.dockSurface,
      elevation: 0,
      shape: const CircularNotchedRectangle(),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accentFrost,
      linearTrackColor: c.surfaceElevated,
      circularTrackColor: c.surfaceElevated,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.accentFrost,
      inactiveTrackColor: c.surfaceElevated,
      thumbColor: c.accentFrost,
      overlayColor: c.accentFrost.withValues(alpha: 0.14),
    ),
    navigationBarTheme: _buildNavigationBarTheme(c, indicatorAlpha: 0.14),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surfacePanel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.borderHairline, width: 1),
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        color: c.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      contentTextStyle: TextStyle(
        fontFamily: 'Inter',
        color: c.textSecondary,
        fontSize: 14,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surfacePanel,
      modalBackgroundColor: c.surfacePanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      showDragHandle: true,
      dragHandleColor: c.borderHairline,
    ),
    iconTheme: IconThemeData(color: c.textPrimary),
    dividerTheme: DividerThemeData(
      color: c.borderHairline,
      thickness: 1,
      space: 1,
    ),
    splashFactory: InkSparkle.splashFactory,
    // Restrained splash — louder was overpowering on white.
    splashColor: c.accentFrost.withValues(alpha: 0.10),
    highlightColor: c.accentFrost.withValues(alpha: 0.05),
  );
}

/// Shared shell bottom-nav theme: always-show labels, frost selection.
NavigationBarThemeData _buildNavigationBarTheme(
  AColors c, {
  required double indicatorAlpha,
}) {
  return NavigationBarThemeData(
    backgroundColor: c.dockSurface,
    indicatorColor: c.accentFrost.withValues(alpha: indicatorAlpha),
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    height: 64,
    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    labelTextStyle: WidgetStateProperty.resolveWith((states) {
      final selected = states.contains(WidgetState.selected);
      return TextStyle(
        fontFamily: 'Inter',
        fontSize: 11,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        color: selected ? c.accentFrost : c.textSecondary,
      );
    }),
    iconTheme: WidgetStateProperty.resolveWith((states) {
      final selected = states.contains(WidgetState.selected);
      return IconThemeData(
        size: 24,
        color: selected
            ? c.accentFrost
            : c.textSecondary.withValues(alpha: 0.7),
      );
    }),
  );
}

TextTheme _buildTextTheme({
  required Color primary,
  required Color secondary,
  required Color tertiary,
  required Color disabled,
  required String monoFamily,
}) {
  return TextTheme(
    displayLarge: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 40,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.0,
    ),
    displayMedium: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.8,
    ),
    displaySmall: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 26,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.6,
    ),
    headlineLarge: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
    ),
    headlineMedium: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    ),
    headlineSmall: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 18,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    titleLarge: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 17,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    titleMedium: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 15,
      fontWeight: FontWeight.w400,
    ),
    bodyMedium: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 14,
      fontWeight: FontWeight.w400,
    ),
    bodySmall: TextStyle(
      fontFamily: 'Inter',
      color: secondary,
      fontSize: 12,
      fontWeight: FontWeight.w400,
    ),
    labelLarge: TextStyle(
      fontFamily: 'Inter',
      color: primary,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: TextStyle(
      fontFamily: 'Inter',
      color: secondary,
      fontSize: 11,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: TextStyle(
      fontFamily: 'Inter',
      color: tertiary,
      fontSize: 10,
      fontWeight: FontWeight.w500,
    ),
  );
}

/// Convenience wrapper that overlays an [AuroraPalette] onto any subtree.
/// Use as `MaterialApp(builder: (ctx, child) => AuroraTheme(child: child!))`
/// so every descendant can resolve the current palette from `BuildContext`.
class AuroraTheme extends StatelessWidget {
  final Widget child;
  final bool isLight;
  final AColors? paletteOverride;

  const AuroraTheme({
    super.key,
    required this.child,
    required this.isLight,
    this.paletteOverride,
  });

  @override
  Widget build(BuildContext context) {
    // Prefer an explicit override (e.g. from MyApp after accent-pack
    // resolution) so Material ThemeData and InheritedWidget share one
    // palette instance.  Fall back to brightness + active pack.
    final AColors baseColors = paletteOverride ??
        colorsForAccentPack(activeAccentPack(), isLight: isLight);
    return AuroraPalette(
      isLight: isLight,
      colors: baseColors,
      child: child,
    );
  }
}
