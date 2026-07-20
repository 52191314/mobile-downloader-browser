import 'package:flutter/material.dart';

import '../theme/aurora_palette.dart';
import 'free_taste.dart';
import 'lan_file_server.dart';
import 'pro_entitlement.dart';
import 'pro_features.dart';
import 'pro_upsell_sheet.dart';
import 'upsell_controller.dart';

/// Bottom sheet for the P6 "Send to PC" feature.
///
/// Resolves the completed file(s), enforces free taste via [FreeTaste]
/// (20 files/day), starts [LanFileServer], and shows per-file LAN share links.
/// Pro+ users are unlimited. Free quota is consumed **only after** the server
/// starts successfully so failed Wi-Fi/bind attempts do not burn taste.
class SendToPcSheet extends StatefulWidget {
  const SendToPcSheet({
    super.key,
    required this.filePaths,
    required this.tier,
  });

  final List<String> filePaths;
  final EntitlementTier tier;

  /// Shows the sheet. Returns true if sharing was started.
  static Future<bool> show(
    BuildContext context, {
    required List<String> filePaths,
    required EntitlementTier tier,
  }) async {
    if (filePaths.isEmpty) return false;
    final ent = proUpsellEntitlement;
    final effectiveTier = ent?.tier ?? tier;
    final isUnlimited =
        ProFeatures.allows(ProFeature.sendToPc, effectiveTier);

    // Peek free capacity first (do not consume yet).
    if (!isUnlimited) {
      final peek = await FreeTaste.evaluate(
        feature: ProFeature.sendToPc,
        tier: effectiveTier,
        n: filePaths.length,
        consume: false,
      );
      if (!peek.allowed) {
        if (context.mounted) {
          await UpsellController.show(
            context,
            feature: ProFeature.sendToPc,
            userTier: effectiveTier,
          );
        }
        return false;
      }
    }

    if (!context.mounted) return false;

    // Server re-checks tier + free-taste peek and path allowlist.
    final started =
        await LanFileServer.start(filePaths, tier: effectiveTier);
    if (!started) {
      if (context.mounted) {
        _showStartError(context);
      }
      return false;
    }

    // Consume only after a successful start.
    if (!isUnlimited) {
      await FreeTaste.evaluate(
        feature: ProFeature.sendToPc,
        tier: effectiveTier,
        n: filePaths.length,
        consume: true,
      );
    }

    if (!context.mounted) return false;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: context.ac.surfacePanel,
      builder: (ctx) =>
          SendToPcSheet(filePaths: filePaths, tier: effectiveTier),
    );
    return true;
  }

  @override
  State<SendToPcSheet> createState() => _SendToPcSheetState();

  /// Shows a snackbar when the server fails to start (e.g. Wi-Fi unavailable,
  /// bind failure). Does NOT mention Pro since permission was already granted.
  static void _showStartError(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not start LAN server. Make sure you are connected to Wi-Fi.',
        ),
      ),
    );
  }
}

class _SendToPcSheetState extends State<SendToPcSheet> {
  bool _starting = true;
  String? _error;
  String? _baseUrl;
  final Map<String, String> _links = {};

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // Server was already started by [SendToPcSheet.show] before the sheet
    // opened. Just collect the links.
    final base = LanFileServer.baseUrl;
    if (base == null) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = 'Could not start the LAN server. '
              'Make sure you are connected to Wi-Fi.';
        });
      }
      return;
    }
    final links = <String, String>{};
    for (final path in widget.filePaths) {
      final url = LanFileServer.issueToken(path);
      if (url != null) links[path] = url;
    }
    if (mounted) {
      setState(() {
        _starting = false;
        _baseUrl = base;
        _links.addAll(links);
      });
    }
  }

  Future<void> _stop() async {
    await LanFileServer.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.computer_outlined, color: ac.accentFrost),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Send to PC',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: ac.textPrimary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_starting)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Text(_error!, style: TextStyle(color: ac.statusError))
          else ...[
            Text(
              'Open these links on a PC on the same Wi-Fi. Each link works '
              'once. Sharing stops after 10 minutes idle or 15 minutes max. '
              'Traffic is plain HTTP on your LAN only.',
              style: TextStyle(color: ac.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (_baseUrl != null)
              SelectableText(
                _baseUrl!,
                style: TextStyle(color: ac.accentFrost, fontSize: 13),
              ),
            const SizedBox(height: 8),
            ..._links.entries.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.key.split('/').last,
                      style: TextStyle(
                        color: ac.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SelectableText(
                      e.value,
                      style: TextStyle(color: ac.accentFrost, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop sharing'),
              onPressed: _stop,
            ),
          ],
        ],
      ),
    );
  }
}
