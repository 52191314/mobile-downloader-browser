import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';

/// Coalesces rapid-duplicate snackbar messages so bursts of the same
/// notification don't spam the screen.
///
/// - First occurrence shows immediately.
/// - Duplicates within ~1.2 s are silently suppressed; the counter is bumped.
/// - If a *different* message follows the burst, the old message is briefly
///   replaced with `message (×N)` before the new message appears, giving
///   the user a hint that earlier taps registered.
/// - Action-required snackbars (Undo / Open once / Cancel) bypass coalescing.
///
/// No `Timer` / `FakeAsync` issues — all time-windowing uses `DateTime.now()`.
class AuroraSnackbar {
  AuroraSnackbar._();

  static String? _lastMessage;
  static int _count = 0;
  static DateTime? _burstStart;

  static const Duration _window = Duration(milliseconds: 1200);

  /// Shows or coalesces a snackbar on [context].
  static void show(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    SnackBar Function(String text)? builder,
  }) {
    if (!context.mounted) return;

    // Action-required snackbars are never coalesced.
    if (actionLabel != null) {
      _reset();
      _showNow(context, message,
          actionLabel: actionLabel, onAction: onAction, builder: builder);
      return;
    }

    final now = DateTime.now();
    final withinWindow =
        _burstStart != null && now.difference(_burstStart!) < _window;

    if (message == _lastMessage && withinWindow) {
      // Duplicate inside the burst window — suppress, bump counter.
      _count++;
      return;
    }

    // If the previous burst had duplicates and this is a new type of
    // action, flash the coalesced count before moving on.
    if (_count > 1 &&
        _lastMessage != null &&
        message != _lastMessage &&
        context.mounted) {
      _showNow(context, '$_lastMessage (×$_count)', builder: builder);
    }

    // Fresh message (or window expired).
    _count = 1;
    _lastMessage = message;
    _burstStart = now;
    _showNow(context, message, builder: builder);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static void _showNow(
    BuildContext context,
    String text, {
    String? actionLabel,
    VoidCallback? onAction,
    SnackBar Function(String text)? builder,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    final ac = context.ac;
    final isLight = context.isLight;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      builder != null
          ? builder(text)
          : SnackBar(
              content: Text(
                text,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: ac.textPrimary,
                ),
              ),
              backgroundColor: ac.surfacePanel,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: ac.accentFrost.withValues(alpha: isLight ? 0.4 : 0.3),
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              duration: const Duration(seconds: 4),
              action: actionLabel != null && onAction != null
                  ? SnackBarAction(
                      label: actionLabel,
                      textColor: ac.accentFrost,
                      onPressed: onAction,
                    )
                  : null,
            ),
    );
  }

  /// Resets in-memory coalescing state. Safe to call in tests.
  static void _reset() {
    _lastMessage = null;
    _count = 0;
    _burstStart = null;
  }
}
