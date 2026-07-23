// Aurora tokens — semantic color palette shared across both light and dark
// themes. Replaces the historic `AuroraColors` / `AuroraColorsLight` flat
// classes with a single value-object whose fields keep their identity (a
// `textPrimary` is always *text-primary* regardless of brightness) and whose
// factory constructors produce the dark or light value set.
//
// All hex values were chosen to clear WCAG AA at the surface they sit on;
// accents were deepened only as much as was required.

import 'package:flutter/material.dart';

@immutable
class AColors {
  // --- Surfaces ---
  /// Outermost scaffold field. Cold Nordic snow in light, deep slate in dark.
  final Color surfaceField;

  /// Primary panel (toolbars, appbar, dock).
  final Color surfacePanel;

  /// Card surface. Same value as [surfacePanel] in dark; distinct pure white
  /// in light so cards lift off the snowfield with a 1px hairline.
  final Color surfaceCard;

  /// Active tab strip, slider track, hovered chip.
  final Color surfaceElevated;

  /// Floating pill dock surface.
  final Color dockSurface;

  /// True black (OLED splash, fullscreen reader). Dark-only; light reuses
  /// `surfaceField`.
  final Color oledBlack;

  // --- Borders / dividers ---
  /// 1px hairline that separates cards, pills, and dialogs from the field.
  /// In dark: 6% white. In light: 10% of the dark-text hex.
  final Color borderHairline;

  /// Stronger divider, e.g. slider inactive track.
  final Color borderStrong;

  // --- Overlays (semi-transparent) ---
  /// Modal sheet scrim.
  final Color overlay;

  /// Modal sheet surface tint.
  final Color overlaySurface;

  // --- Gradients ---
  /// Sheet gradient top stop.
  final Color gradientSheetTop;

  /// Sheet gradient bottom stop.
  final Color gradientSheetBottom;

  /// Sheet gradient mid stop.
  final Color gradientMid;

  // --- Glass ---
  /// Glass surface — semantic alias for the panel surface.
  final Color glassSurface;

  /// Glass border — kept distinct from [borderHairline] so the dock can use
  /// a slightly fainter edge than the cards.
  final Color glassBorder;

  // --- Accents ---
  /// Primary action accent (Nord Frost cyan / deep Nordic blue).
  final Color accentFrost;

  /// Secondary accent (purple).
  final Color accentPurple;

  /// Tertiary accent (amber) for throttle / pause / warning.
  final Color accentAmber;

  // --- Text ---
  /// Highest-contrast text on surfaces.
  final Color textPrimary;

  /// Secondary text — same hex in both modes for cross-mode stability.
  final Color textSecondary;

  /// Tertiary text — captions, footnotes.
  final Color textTertiary;

  /// Disabled text and icons.
  final Color textDisabled;

  // --- Semantic status ---
  /// Completed download / success state.
  final Color statusSuccess;

  /// Failed download / error state.
  final Color statusError;

  // --- Media type chips ---
  final Color mediaVideo;
  final Color mediaAudio;
  final Color mediaImage;
  final Color mediaHls;
  final Color mediaOther;
  /// Torrent type accent — deep teal (not amber, not frost cyan).
  final Color mediaTorrent;

  // --- Tab-group palette (8 distinct hues) ---
  final Color groupCyan;
  final Color groupAmber;
  final Color groupPurple;
  final Color groupGreen;
  final Color groupRed;
  final Color groupOrange;
  final Color groupBlue;
  final Color groupPink;

  const AColors({
    required this.surfaceField,
    required this.surfacePanel,
    required this.surfaceCard,
    required this.surfaceElevated,
    required this.dockSurface,
    required this.oledBlack,
    required this.borderHairline,
    required this.borderStrong,
    required this.overlay,
    required this.overlaySurface,
    required this.gradientSheetTop,
    required this.gradientSheetBottom,
    required this.gradientMid,
    required this.glassSurface,
    required this.glassBorder,
    required this.accentFrost,
    required this.accentPurple,
    required this.accentAmber,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.statusSuccess,
    required this.statusError,
    required this.mediaVideo,
    required this.mediaAudio,
    required this.mediaImage,
    required this.mediaHls,
    required this.mediaOther,
    required this.mediaTorrent,
    required this.groupCyan,
    required this.groupAmber,
    required this.groupPurple,
    required this.groupGreen,
    required this.groupRed,
    required this.groupOrange,
    required this.groupBlue,
    required this.groupPink,
  });

  /// Nord Aurora Glass — the historic dark identity.
  factory AColors.dark() => const AColors(
        // Surfaces
        surfaceField: Color(0xFF0A0F14),
        surfacePanel: Color(0xFF141B23),
        surfaceCard: Color(0xFF18212B),
        surfaceElevated: Color(0xFF1F2B38),
        dockSurface: Color(0xFF1A2330),
        oledBlack: Color(0xFF000000),
        // Borders
        borderHairline: Color(0x14FFFFFF), // 8% white
        borderStrong: Color(0xFF263241),
        // Overlays
        overlay: Color(0xEE0A0F14),
        overlaySurface: Color(0xEE141B23),
        // Gradients
        gradientSheetTop: Color(0xFF0D1520),
        gradientSheetBottom: Color(0xFF1A2332),
        gradientMid: Color(0xFF1A2332),
        // Glass
        glassSurface: Color(0xFF141B23),
        glassBorder: Color(0x0FFFFFFF), // 6% white (legacy)
        // Accents (Nord palette)
        accentFrost: Color(0xFF88C0D0),
        accentPurple: Color(0xFFB48EAD),
        accentAmber: Color(0xFFEBCB8B),
        // Text
        textPrimary: Color(0xFFE5E9F0),
        textSecondary: Color(0xFF9AA7B3),
        textTertiary: Color(0xFF6C7A89),
        textDisabled: Color(0xFF4A5568),
        // Status
        statusSuccess: Color(0xFFA3BE8C),
        statusError: Color(0xFFBF616A),
        // Media
        mediaVideo: Color(0xFF5E81AC),
        mediaAudio: Color(0xFFB48EAD),
        mediaImage: Color(0xFF4F7A3A),
        mediaHls: Color(0xFFD08770),
        mediaOther: Color(0xFF3D6C9A),
        mediaTorrent: Color(0xFF3D8B84),
        // Tab groups
        groupCyan: Color(0xFF88C0D0),
        groupAmber: Color(0xFFEBCB8B),
        groupPurple: Color(0xFFB48EAD),
        groupGreen: Color(0xFFA3BE8C),
        groupRed: Color(0xFFBF616A),
        groupOrange: Color(0xFFD08770),
        groupBlue: Color(0xFF5E81AC),
        groupPink: Color(0xFFD4778E),
      );

  /// Nord Snow Storm — the new light identity. Inverts the field, keeps
  /// accents recognizable but darkened for AA contrast on white.
  factory AColors.light() => const AColors(
        // Surfaces
        surfaceField: Color(0xFFF4F6FA),
        surfacePanel: Color(0xFFFFFFFF),
        surfaceCard: Color(0xFFFFFFFF),
        surfaceElevated: Color(0xFFE5E9F0),
        dockSurface: Color(0xFFFFFFFF),
        oledBlack: Color(0xFF000000),
        // Borders
        borderHairline: Color(0x1A2E3440), // 10% of dark-text hex
        borderStrong: Color(0xFFCBD5E0),
        // Overlays
        overlay: Color(0xEEF4F6FA),
        overlaySurface: Color(0xFFFFFFFF),
        // Gradients
        gradientSheetTop: Color(0xFFF4F6FA),
        gradientSheetBottom: Color(0xFFE5E9F0),
        gradientMid: Color(0xFFF4F6FA),
        // Glass
        glassSurface: Color(0xFFFFFFFF),
        glassBorder: Color(0x1A2E3440),
        // Accents
        accentFrost: Color(0xFF3D6C9A),
        accentPurple: Color(0xFF8F6A85),
        accentAmber: Color(0xFFA35A00),
        // Text
        textPrimary: Color(0xFF2E3440),
        textSecondary: Color(0xFF4C566A),
        textTertiary: Color(0xFF6C7A89),
        textDisabled: Color(0xFF9AA7B3),
        // Status
        statusSuccess: Color(0xFF4F7A3A),
        statusError: Color(0xFFA12D2D),
        // Media
        mediaVideo: Color(0xFF1E5A8C),
        mediaAudio: Color(0xFF8F6A85),
        mediaImage: Color(0xFF4F7A3A),
        mediaHls: Color(0xFFC45C3E),
        mediaOther: Color(0xFF5A6B7D),
        mediaTorrent: Color(0xFF2F6F6F),
        // Tab groups
        groupCyan: Color(0xFF3D6C9A),
        groupAmber: Color(0xFFA35A00),
        groupPurple: Color(0xFF8F6A85),
        groupGreen: Color(0xFF4F7A3A),
        groupRed: Color(0xFFA12D2D),
        groupOrange: Color(0xFFA35A00),
        groupBlue: Color(0xFF3D6C9A),
        groupPink: Color(0xFFB04868),
      );
  /// Returns a copy of [AColors] with accent-family colors applied.
  ///
  /// Used by accent packs to recolor primary/secondary/tertiary accents,
  /// media chips, tab-group hues, and optional surface/gradient tints.
  /// Semantic [statusSuccess] / [statusError] are intentionally not
  /// overridable here (pass-through only if you ever need tests).
  AColors copyWithAccent({
    Color? accentFrost,
    Color? accentPurple,
    Color? accentAmber,
    Color? mediaVideo,
    Color? mediaAudio,
    Color? mediaImage,
    Color? mediaHls,
    Color? mediaOther,
    Color? mediaTorrent,
    Color? groupCyan,
    Color? groupAmber,
    Color? groupPurple,
    Color? groupGreen,
    Color? groupRed,
    Color? groupOrange,
    Color? groupBlue,
    Color? groupPink,
    Color? surfaceElevated,
    Color? borderStrong,
    Color? gradientSheetTop,
    Color? gradientSheetBottom,
    Color? gradientMid,
    Color? glassBorder,
    Color? statusSuccess,
    Color? statusError,
  }) {
    return AColors(
      surfaceField: surfaceField,
      surfacePanel: surfacePanel,
      surfaceCard: surfaceCard,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      dockSurface: dockSurface,
      oledBlack: oledBlack,
      borderHairline: borderHairline,
      borderStrong: borderStrong ?? this.borderStrong,
      overlay: overlay,
      overlaySurface: overlaySurface,
      gradientSheetTop: gradientSheetTop ?? this.gradientSheetTop,
      gradientSheetBottom: gradientSheetBottom ?? this.gradientSheetBottom,
      gradientMid: gradientMid ?? this.gradientMid,
      glassSurface: glassSurface,
      glassBorder: glassBorder ?? this.glassBorder,
      accentFrost: accentFrost ?? this.accentFrost,
      accentPurple: accentPurple ?? this.accentPurple,
      accentAmber: accentAmber ?? this.accentAmber,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      textTertiary: textTertiary,
      textDisabled: textDisabled,
      statusSuccess: statusSuccess ?? this.statusSuccess,
      statusError: statusError ?? this.statusError,
      mediaVideo: mediaVideo ?? this.mediaVideo,
      mediaAudio: mediaAudio ?? this.mediaAudio,
      mediaImage: mediaImage ?? this.mediaImage,
      mediaHls: mediaHls ?? this.mediaHls,
      mediaOther: mediaOther ?? this.mediaOther,
      mediaTorrent: mediaTorrent ?? this.mediaTorrent,
      groupCyan: groupCyan ?? this.groupCyan,
      groupAmber: groupAmber ?? this.groupAmber,
      groupPurple: groupPurple ?? this.groupPurple,
      groupGreen: groupGreen ?? this.groupGreen,
      groupRed: groupRed ?? this.groupRed,
      groupOrange: groupOrange ?? this.groupOrange,
      groupBlue: groupBlue ?? this.groupBlue,
      groupPink: groupPink ?? this.groupPink,
    );
  }
}
