/// Watcher settings page — manage RSS/page watch rules.
///
/// Gate: [ProFeature.watcher] (Ultra tier only).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../premium/pro_entitlement.dart';
import '../../premium/pro_features.dart';
import '../../premium/pro_upsell_sheet.dart';
import '../../premium/watcher/watcher_models.dart';
import '../../premium/watcher/watcher_service.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/aurora_palette.dart';
import '../widgets/panel.dart';

class WatcherPage extends StatefulWidget {
  final WatcherService watcherService;
  final ProEntitlement proEntitlement;

  const WatcherPage({
    super.key,
    required this.watcherService,
    required this.proEntitlement,
  });

  @override
  State<WatcherPage> createState() => _WatcherPageState();
}

class _WatcherPageState extends State<WatcherPage> {
  @override
  void initState() {
    super.initState();
    widget.watcherService.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.watcherService.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!ProFeatures.allows(ProFeature.watcher, widget.proEntitlement.tier)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // The route may have been popped between build and callback.
        if (!mounted) return;
        Navigator.of(context).pop();
        if (!mounted) return;
        showProUpsell(context, ProFeature.watcher);
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final rules = widget.watcherService.rules;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)?.lblWatcherTitle ?? 'Aurora Watcher'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Watch'),
            onPressed: () => _showRuleDialog(),
          ),
        ],
      ),
      body: rules.isEmpty
          ? _buildEmptyState()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildStatusHeader(),
                const SizedBox(height: 16),
                PanelHeader(
                    icon: Icons.rss_feed,
                    title: '${rules.length} watch rule${rules.length == 1 ? '' : 's'}'),
                const SizedBox(height: 8),
                Panel(
                  child: Column(
                    children: [
                      for (int i = 0; i < rules.length; i++)
                        _buildRuleTile(rules[i],
                            isLast: i == rules.length - 1),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rss_feed, size: 64, color: context.ac.textTertiary),
            const SizedBox(height: 16),
            Text(
              'No watch rules yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.ac.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Create a watch rule to monitor an RSS feed or web page '
              'and auto-enqueue new downloads.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: context.ac.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add your first watch'),
              onPressed: () => _showRuleDialog(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.ac.accentPurple.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.ac.accentPurple.withOpacity(0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            widget.watcherService.isRunning
                ? Icons.rss_feed
                : Icons.rss_feed_outlined,
            color: context.ac.accentPurple,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.watcherService.isRunning
                  ? 'Watcher is active. Rules checked every 5 minutes.'
                  : 'Watcher is paused.',
              style: TextStyle(
                fontSize: 13,
                color: context.ac.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleTile(WatchRule rule, {bool isLast = false}) {
    final isDue = rule.isDue;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(
            rule.kind == WatchKind.rss
                ? Icons.rss_feed
                : Icons.language,
            color: rule.enabled
                ? context.ac.accentFrost
                : context.ac.textTertiary,
            size: 24,
          ),
          title: Text(
            rule.label ?? rule.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: rule.enabled
                  ? context.ac.textPrimary
                  : context.ac.textTertiary,
            ),
          ),
          subtitle: Text(
            '${rule.kind == WatchKind.rss ? 'RSS' : 'Page'} · '
            '${rule.minInterval.inMinutes}m interval'
            '${rule.lastCheckedAt != null ? ' · Last: ${_formatTime(rule.lastCheckedAt!)}' : ''}'
            ' · ${rule.seenIds.length} seen',
            style: TextStyle(
              fontSize: 11,
              color: context.ac.textSecondary,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isDue && rule.enabled)
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Check now',
                  onPressed: () => widget.watcherService.checkNow(rule.id),
                ),
              IconButton(
                icon: Icon(
                  rule.enabled
                      ? Icons.toggle_on
                      : Icons.toggle_off_outlined,
                  color: rule.enabled
                      ? context.ac.statusSuccess
                      : context.ac.textTertiary,
                  size: 22,
                ),
                tooltip: rule.enabled ? 'Enabled' : 'Disabled',
                onPressed: () =>
                    widget.watcherService.toggleRule(rule.id),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                tooltip: 'Edit',
                onPressed: () => _showRuleDialog(existing: rule),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 18, color: context.ac.statusError),
                tooltip: 'Delete',
                onPressed: () => _confirmDelete(rule),
              ),
            ],
          ),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        if (!isLast)
          Divider(
              height: 1, indent: 56, color: context.ac.glassBorder),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _showRuleDialog({WatchRule? existing}) async {
    final isEditing = existing != null;
    final urlController = TextEditingController(text: existing?.url ?? '');
    final labelController = TextEditingController(text: existing?.label ?? '');
    final regexController =
        TextEditingController(text: existing?.matchRegex ?? '');

    var kind = existing?.kind ?? WatchKind.rss;
    var interval = existing?.minInterval.inMinutes ?? 60;
    var enabled = existing?.enabled ?? true;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(isEditing ? 'Edit Watch Rule' : 'Add Watch Rule'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: labelController,
                    decoration: const InputDecoration(
                      labelText: 'Label (optional)',
                      hintText: 'e.g. My Podcast Feed',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: urlController,
                    decoration: const InputDecoration(
                      labelText: 'URL',
                      hintText: 'https://example.com/feed.xml',
                      isDense: true,
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<WatchKind>(
                    value: kind,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Type',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                          value: WatchKind.rss, child: Text('RSS Feed')),
                      DropdownMenuItem(
                          value: WatchKind.page,
                          child: Text('Web Page')),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialogState(() => kind = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: regexController,
                    decoration: const InputDecoration(
                      labelText: 'Match filter (regex, optional)',
                      hintText: 'e.g. 1080p|2160p',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    value: interval,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Check interval',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 30, child: Text('30 minutes')),
                      DropdownMenuItem(value: 60, child: Text('1 hour')),
                      DropdownMenuItem(value: 120, child: Text('2 hours')),
                      DropdownMenuItem(value: 180, child: Text('3 hours')),
                      DropdownMenuItem(value: 360, child: Text('6 hours')),
                      DropdownMenuItem(value: 720, child: Text('12 hours')),
                      DropdownMenuItem(value: 1440, child: Text('24 hours')),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialogState(() => interval = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    title: const Text('Enabled'),
                    value: enabled,
                    onChanged: (v) =>
                        setDialogState(() => enabled = v),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final url = urlController.text.trim();
                  if (url.isEmpty) return;

                  final now = DateTime.now();
                  final rule = WatchRule(
                    id: existing?.id ??
                        now.microsecondsSinceEpoch.toString(),
                    kind: kind,
                    url: url,
                    label: labelController.text.trim().isEmpty
                        ? null
                        : labelController.text.trim(),
                    matchRegex: regexController.text.trim().isEmpty
                        ? null
                        : regexController.text.trim(),
                    minInterval: Duration(minutes: interval),
                    enabled: enabled,
                    createdAt: existing?.createdAt ?? now,
                  );

                  if (isEditing) {
                    widget.watcherService.updateRule(rule);
                  } else {
                    widget.watcherService.addRule(rule);
                  }

                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
                child: Text(isEditing ? 'Save' : 'Add'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(WatchRule rule) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Watch Rule'),
        content: Text('Delete "${rule.label ?? rule.url}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: context.ac.statusError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      widget.watcherService.removeRule(rule.id);
    }
  }
}
