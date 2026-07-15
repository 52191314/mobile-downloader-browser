// Standalone library — extracted from `sniffer_screen.dart` during Phase 5 of
// the refactorization. Provides the page-translation flow
// (`translatePage`) which routes the active tab through Google Translate
// using the user's preferred target language.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Translates the active tab's URL through `translate.google.com` using
/// the currently selected target language. Replaces the body of
/// `_SnifferScreenState._translatePage`.
///
/// [currentSettings] must be the live `widget.settings` instance; the
/// new `translateTargetLang` is written back into a copy and pushed via
/// [onSettingsChanged]. Passing the full current settings (instead of
/// just the language string) preserves every other user preference.
Future<void> translatePage(
  BuildContext context, {
  required BrowserTab activeTab,
  required DownloadSettings currentSettings,
  required ValueChanged<DownloadSettings> onSettingsChanged,
  required Future<void> Function(Uri uri) onLoadUrl,
  required void Function(String message) onShowSnack,
  required bool isMounted,
}) async {
  final ac = context.ac;
  final tab = activeTab;
  final url = await tab.controller.currentUrl();
  if (url == null || url.isEmpty) return;
  if (!isMounted) return;
  final picked = await showModalBottomSheet<String>(
    // ignore: use_build_context_synchronously
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Translate page to',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            for (final lang in kTranslateLanguages)
              ListTile(
                leading: Icon(
                  lang.id == currentSettings.translateTargetLang
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: ac.accentFrost,
                ),
                title: Text(lang.label),
                onTap: () => Navigator.of(ctx).pop(lang.id),
              ),
          ],
        ),
      );
    },
  );
  if (picked == null) return;
  onSettingsChanged(
    currentSettings.copyWith(translateTargetLang: picked),
  );
  final target = translateLanguageById(picked);
  final translateUrl =
      'https://translate.google.com/translate?hl=${target.id}&sl=auto&u='
      '${Uri.encodeComponent(url)}';
  unawaited(onLoadUrl(Uri.parse(translateUrl)));
  onShowSnack('Translating to ${target.label}…');
}
