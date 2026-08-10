import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../downloader/download_queue.dart';
import '../../downloader/models.dart';
import '../../platform/secure_window.dart';
import '../../premium/phase2_caps.dart';
import '../../premium/pro_entitlement.dart';
import '../../premium/pro_features.dart';
import '../../premium/pro_upsell_sheet.dart';
import '../../premium/vault_service.dart';
import '../../premium/vault_sync_service.dart';
import '../../premium/webdav_backup_service.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/aurora_palette.dart';
import '../../theme/aurora_tokens.dart';
import 'webdav_settings_page.dart';

/// Channel to the native host — used to open the system lock-screen settings
/// when the device has no PIN/biometric enrolled.
const MethodChannel _kSecuritySettingsChannel =
    MethodChannel('aurora_downloader/public_downloads');

/// Vault UI — lists encrypted vault files with lock/unlock, import, export,
/// and delete.
///
/// Applies Android [FLAG_SECURE] while this page is open to block screenshots
/// and recent-app previews (including recovery-key display).
class VaultPage extends StatefulWidget {
  final VaultService vault;
  final EntitlementTier tier;

  /// Optional access to completed downloads, enabling in-page import.
  final DownloadQueue? downloadQueue;

  const VaultPage({
    super.key,
    required this.vault,
    required this.tier,
    this.downloadQueue,
  });

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> with WidgetsBindingObserver {
  List<VaultEntry> _entries = [];
  bool _loading = true;
  bool _unlocked = false;
  String? _recoveryKey;
  int _fileCount = 0;

  /// Why the last unlock attempt failed (null when unlocked or no attempt).
  VaultAuthFailure? _authErrorCode;
  String? _authError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(SecureWindow.setSecure(true));
    _initVault();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(SecureWindow.setSecure(false));
    widget.vault.lock();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Drop session key when backgrounded; user re-auths on return.
      widget.vault.lock();
      if (mounted && _unlocked) {
        setState(() {
          _unlocked = false;
          _entries = [];
        });
      }
    }
  }

  Future<void> _initVault() async {
    final ready = await widget.vault.ensureInitialized();
    if (!mounted) return;

    if (ready) {
      // Re-reads from storage so a key created in an earlier session whose
      // banner was never acknowledged is still shown (not just memory).
      _recoveryKey = await widget.vault.recoveryKeyIfUnshown();
    }

    final unlocked = await widget.vault.authenticate(reason: 'Unlock vault');
    if (!mounted) return;
    if (unlocked) {
      setState(() {
        _unlocked = true;
        _authErrorCode = null;
        _authError = null;
      });
      await _loadEntries();
    } else {
      setState(() {
        _loading = false;
        _unlocked = false;
        _authErrorCode = widget.vault.lastAuthFailure;
        _authError = widget.vault.lastAuthFailureMessage;
      });
    }
  }

  Future<void> _loadEntries() async {
    if (!mounted) return;
    setState(() => _loading = true);
    _entries = await widget.vault.list(authed: true);
    _fileCount = await widget.vault.fileCount();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _lock() async {
    widget.vault.lock();
    setState(() {
      _unlocked = false;
      _entries = [];
      _authErrorCode = null;
      _authError = null;
    });
  }

  Future<void> _unlock() async {
    final ok = await widget.vault.authenticate(reason: 'Unlock vault');
    if (!mounted) return;
    if (ok) {
      setState(() {
        _unlocked = true;
        _authErrorCode = null;
        _authError = null;
      });
      await _loadEntries();
    } else {
      setState(() {
        _authErrorCode = widget.vault.lastAuthFailure;
        _authError = widget.vault.lastAuthFailureMessage;
      });
    }
  }

  Future<void> _openLockScreenSettings() async {
    try {
      final ok = await _kSecuritySettingsChannel.invokeMethod<bool>(
        'openSecuritySettings',
      );
      if (!mounted) return;
      if (ok != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open lock screen settings. '
                'Set a PIN or biometric in your device Settings > Security.'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open lock screen settings: $e'),
        ),
      );
    }
  }

  Future<void> _export(VaultEntry entry) async {
    final docs = await getApplicationDocumentsDirectory();
    final safe = VaultService.sanitizeVaultName(entry.name) ?? 'export.vault';
    final dest = p.join(docs.path, 'vault_export', safe);
    final ok = await widget.vault.export(entry.name, dest, authed: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Exported to $dest' : 'Export failed'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _delete(VaultEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.vaultDeleteFromVault),
        content: Text('Permanently delete ${entry.name}?\n'
            'This cannot be undone without the recovery key.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await widget.vault.delete(entry.name);
      await _loadEntries();
    }
  }

  /// Encrypts the user's selected completed downloads into the vault.
  Future<void> _importFromDownloads() async {
    final tasks = (widget.downloadQueue?.completedTasks ?? const <DownloadTask>[])
        .where((t) => File(t.savePath).existsSync())
        .toList();

    if (tasks.isEmpty) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(AppLocalizations.of(context)!.vaultNothingToImport),
          content: const Text(
              'No completed downloads found on disk. Finish a download first, '
              'then import it here.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final selected = <String>{};
    var deleteOriginal = true;
    var importing = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(AppLocalizations.of(context)!.vaultImportTitle),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: tasks.length,
                    itemBuilder: (context, i) {
                      final t = tasks[i];
                      final name = p.basename(t.savePath);
                      return CheckboxListTile(
                        value: selected.contains(t.id),
                        onChanged: importing
                            ? null
                            : (v) => setDialogState(() {
                                  if (v == true) {
                                    selected.add(t.id);
                                  } else {
                                    selected.remove(t.id);
                                  }
                                }),
                        title: Text(name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          _formatSize(_safeFileSize(t.savePath)),
                          style: const TextStyle(fontSize: 12),
                        ),
                        dense: true,
                      );
                    },
                  ),
                ),
                CheckboxListTile(
                  value: deleteOriginal,
                  onChanged: importing
                      ? null
                      : (v) => setDialogState(() => deleteOriginal = v ?? true),
                  title: Text(AppLocalizations.of(context)!.vaultDeleteOriginal),
                  dense: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: importing ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: importing || selected.isEmpty
                  ? null
                  : () async {
                      setDialogState(() => importing = true);
                      final results = await _encryptSelectedTasks(
                        tasks.where((t) => selected.contains(t.id)).toList(),
                        deleteOriginal: deleteOriginal,
                      );
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      if (!mounted) return;
                      await _loadEntries();
                      final ok = results.where((r) => r).length;
                      final failed = results.length - ok;
                      if (!mounted) return;
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(
                          content: Text(failed == 0
                              ? 'Imported $ok file${ok == 1 ? '' : 's'} '
                                  'into the vault.'
                              : 'Imported $ok, failed $failed.'),
                        ),
                      );
                    },
              child: const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }

  /// Encrypts [tasks] into the vault; returns per-task success flags.
  Future<List<bool>> _encryptSelectedTasks(
    List<DownloadTask> tasks, {
    required bool deleteOriginal,
  }) async {
    final results = <bool>[];
    for (final t in tasks) {
      final file = File(t.savePath);
      if (!file.existsSync()) {
        results.add(false);
        continue;
      }
      if (!await widget.vault.canAccept(widget.tier)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(widget.tier.isAtLeastPro
                  ? 'Vault could not accept this file.'
                  : 'Vault is full (max ${Phase2Caps.maxFreeVaultItems} '
                      'for free). Delete items or upgrade to Pro+.'),
            ),
          );
        }
        results.add(false);
        // The cap is global — the rest of the batch cannot fit either.
        break;
      }
      final vaultName = await widget.vault.store(file, tier: widget.tier);
      if (vaultName != null) {
        if (deleteOriginal) {
          try {
            await file.delete();
          } catch (_) {
            // Already encrypted — no plaintext leak.
          }
        }
        results.add(true);
      } else {
        final fail = widget.vault.lastAuthFailureMessage;
        if (fail != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Not imported: $fail')),
          );
        }
        results.add(false);
        // An auth failure blocks the rest of the batch.
        if (widget.vault.lastAuthFailure != null) break;
      }
    }
    return results;
  }

  int _safeFileSize(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _syncWebdavVault() async {
    if (!VaultSyncService.isAllowed(widget.tier)) {
      showProUpsell(context, ProFeature.vaultSync);
      return;
    }

    final webdavSettings = await WebdavBackupService.loadSettings();
    if (webdavSettings == null || webdavSettings.url.trim().isEmpty || webdavSettings.username.trim().isEmpty) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('WebDAV Not Configured'),
          content: const Text(
              'Please configure your WebDAV URL and credentials in WebDAV Settings before syncing.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const WebdavSettingsPage(),
                  ),
                );
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      return;
    }

    final passphraseController = TextEditingController();
    int actionType = 0; // 0 = upload, 1 = restore, 2 = delete remote

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('WebDAV Encrypted Vault Sync'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Sync your encrypted vault items to your private WebDAV server using AES-GCM encryption.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                RadioListTile<int>(
                  title: const Text('Upload Local Vault to WebDAV'),
                  value: 0,
                  groupValue: actionType,
                  onChanged: (v) => setDialogState(() => actionType = v!),
                  dense: true,
                ),
                RadioListTile<int>(
                  title: const Text('Restore Vault from WebDAV'),
                  value: 1,
                  groupValue: actionType,
                  onChanged: (v) => setDialogState(() => actionType = v!),
                  dense: true,
                ),
                RadioListTile<int>(
                  title: const Text('Delete Remote Vault Backup'),
                  value: 2,
                  groupValue: actionType,
                  onChanged: (v) => setDialogState(() => actionType = v!),
                  dense: true,
                ),
                if (actionType != 2) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: passphraseController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Sync Passphrase',
                      hintText: 'Enter passphrase for encryption key',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Proceed'),
            ),
          ],
        ),
      ),
    );

    if (confirm != true || !mounted) return;

    final passphrase = passphraseController.text.trim();
    if (actionType != 2 && passphrase.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sync passphrase cannot be empty.')),
      );
      return;
    }

    final syncService = VaultSyncService(
      webdavBaseUrl: webdavSettings.url,
      webdavUsername: webdavSettings.username,
      webdavPassword: webdavSettings.password,
    );

    setState(() => _loading = true);
    try {
      if (actionType == 0) {
        final map = <String, dynamic>{
          'entries': _entries
              .map((e) => {
                    'name': e.name,
                    'size': e.size,
                    'modified': e.modified.toIso8601String(),
                  })
              .toList(),
        };
        final ok = await syncService.uploadVault(
          passphrase: passphrase,
          vaultData: map,
        );
        if (ok) {
          final vaultDir = await widget.vault.vaultDir;
          final files = await vaultDir.list().toList();
          for (final f in files.whereType<File>()) {
            final name = f.uri.pathSegments.last;
            if (name.endsWith('.vault')) {
              await syncService.uploadVaultBlob(
                passphrase: passphrase,
                vaultName: name,
                vaultFile: f,
              );
            }
          }
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok
                ? 'Vault & files successfully uploaded to WebDAV'
                : 'Failed to upload vault to WebDAV'),
          ),
        );
      } else if (actionType == 1) {
        final restored = await syncService.downloadVault(passphrase: passphrase);
        if (!mounted) return;
        if (restored != null) {
          final entries = restored['entries'] as List? ?? [];
          final vaultDir = await widget.vault.vaultDir;
          int restoredCount = 0;
          for (final entry in entries) {
            final name = entry['name'] as String?;
            if (name != null &&
                await syncService.downloadAndRestoreVaultBlob(
                  passphrase: passphrase,
                  vaultName: name,
                  vaultDir: vaultDir,
                )) {
              restoredCount++;
            }
          }
          await _loadEntries();
          // The restore loop + _loadEntries can take seconds; the page may
          // have been disposed while iterating (user backed out mid-restore).
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Vault restored: $restoredCount files from WebDAV.'),
            ),
          );
        } else {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to restore vault (incorrect passphrase or no remote backup).'),
            ),
          );
        }
      } else if (actionType == 2) {
        final ok = await syncService.deleteRemoteVault();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok
                ? 'Remote vault backup deleted from WebDAV'
                : 'Failed to delete remote vault backup'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    return Scaffold(
      backgroundColor: ac.surfaceField,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)?.lblVaultTitle ?? 'Private Vault'),
        backgroundColor: ac.surfacePanel,
        actions: [
          if (_unlocked) ...[
            IconButton(
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: 'Import downloads',
              onPressed: _importFromDownloads,
            ),
            IconButton(
              icon: const Icon(Icons.cloud_sync_outlined),
              tooltip: 'WebDAV Vault Sync',
              onPressed: _syncWebdavVault,
            ),
            IconButton(
              icon: const Icon(Icons.lock_outline),
              tooltip: 'Lock vault',
              onPressed: _lock,
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.lock_open),
              tooltip: 'Unlock vault',
              onPressed: _unlock,
            ),
        ],
      ),
      body: _buildBody(ac),
    );
  }

  Widget _buildBody(AColors AC) {
    // First-time recovery key.
    if (_recoveryKey != null) {
      return _buildRecoveryBanner(AC);
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_unlocked) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock, size: 64, color: AC.textSecondary),
              const SizedBox(height: 16),
              Text('Vault is locked',
                  style: TextStyle(
                      color: AC.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                _authError ??
                    'Authenticate with biometric or device PIN to view vault files',
                textAlign: TextAlign.center,
                style: TextStyle(color: AC.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _unlock,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock'),
              ),
              if (_authErrorCode == VaultAuthFailure.noCredential) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _openLockScreenSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Open lock screen settings'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield_outlined, size: 64, color: AC.textSecondary),
              const SizedBox(height: 16),
              Text('Vault is empty',
                  style: TextStyle(
                      color: AC.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('Move downloaded files here to keep them private',
                  style: TextStyle(color: AC.textSecondary, fontSize: 14)),
              const SizedBox(height: 8),
              Text('$_fileCount / ${Phase2Caps.maxFreeVaultItems} items',
                  style: TextStyle(
                      color: AC.accentFrost,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _importFromDownloads,
                icon: const Icon(Icons.file_upload_outlined),
                label: Text(AppLocalizations.of(context)!.vaultAddFiles),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Inventory counter
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text('$_fileCount items',
                  style: TextStyle(color: AC.textSecondary, fontSize: 13)),
              const Spacer(),
              if (!widget.tier.isAtLeastPro)
                Text('Max ${Phase2Caps.maxFreeVaultItems} (free)',
                    style: TextStyle(
                        color: AC.accentAmber, fontSize: 12)),
            ],
          ),
        ),
        // File list
        Expanded(
          child: ListView.builder(
            itemCount: _entries.length,
            itemBuilder: (context, i) {
              final entry = _entries[i];
              return ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(entry.name,
                    style: TextStyle(color: AC.textPrimary, fontSize: 14)),
                subtitle: Text(
                  '${_formatSize(entry.size)} · ${_formatDate(entry.modified)}',
                  style: TextStyle(color: AC.textSecondary, fontSize: 12),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'export':
                        _export(entry);
                      case 'delete':
                        _delete(entry);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'export',
                        child: Text('Export / Decrypt')),
                    PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete')),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRecoveryBanner(AColors AC) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 48, color: AC.accentAmber),
          const SizedBox(height: 16),
          const Text(
            'Vault Recovery Key',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'This is your ONLY recovery key. If you lose it, vault files '
            'cannot be recovered. Write it down and keep it safe.\n\n'
            'No one at Aurora can recover this key for you.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AC.surfacePanel,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _recoveryKey!,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              widget.vault.markRecoveryKeyShown();
              setState(() => _recoveryKey = null);
              _unlock();
            },
            child: const Text('I\'ve saved my recovery key'),
          ),
        ],
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }
}
