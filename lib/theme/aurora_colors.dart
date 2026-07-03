import 'package:flutter/material.dart';

/// Aurora's "Aurora Glass" dark color palette.
///
/// All UI colors should reference these constants instead of hardcoding
/// hex values. Add new semantic names rather than duplicating literals.
class AuroraColors {
  AuroraColors._();

  // --- Surfaces ---
  /// Deepest background (e.g. reader mode, scaffold).
  static const Color background = Color(0xFF0A0F14);

  /// Primary surface (e.g. panels, toolbars).
  static const Color surface = Color(0xFF141B23);

  /// Slightly lighter surface variant (e.g. active tab strip).
  static const Color surfaceVariant = Color(0xFF1F2B38);

  /// Card surface (e.g. capture media tile).
  static const Color surfaceCard = Color(0xFF18212B);

  /// Glass-surface semantic alias (same value as [surface]).
  static const Color glassSurface = Color(0xFF141B23);

  /// Dock / nav bar surface.
  static const Color dockSurface = Color(0xFF1A2330);

  /// True black (e.g. OLED splash, fullscreen reader).
  static const Color oledBlack = Color(0xFF000000);

  /// Glass border: white at 6% opacity.
  static const Color glassBorder = Color(0x0FFFFFFF);

  // --- Gradients ---
  static const Color gradientSheetTop = Color(0xFF0D1520);
  static const Color gradientSheetBottom = Color(0xFF1A2332);
  static const Color gradientMid = Color(0xFF1A2332);

  // --- Borders / dividers ---
  static const Color border = Color(0xFF263241);

  // --- Overlays (semi-transparent) ---
  static const Color overlaySurface = Color(0xEE141B23);
  static const Color overlay = Color(0xEE0A0F14);

  // --- Accent (cyan — Nord "frost" color) ---
  static const Color accent = Color(0xFF88C0D0);

  // --- Secondary accents (Nord Aurora palette) ---
  static const Color accentPurple = Color(0xFFB48EAD);
  static const Color accentAmber = Color(0xFFEBCB8B);

  // --- Text ---
  static const Color text = Color(0xFFE5E9F0);
  static const Color mutedText = Color(0xFF9AA7B3);
  static const Color mutedTextAlt = Color(0xFF9AA7B9);
  static const Color mutedDeep = Color(0xFF6C7A89);
  static const Color disabledText = Color(0xFF4A5568);

  // --- Semantic status (Nord Aurora palette) ---
  /// Nord green — success / completed.
  static const Color nordGreen = Color(0xFFA3BE8C);

  /// Nord red — error / failed.
  static const Color nordRed = Color(0xFFBF616A);
}
