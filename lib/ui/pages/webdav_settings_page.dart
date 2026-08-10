import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../premium/webdav_backup_service.dart';
import '../../theme/aurora_palette.dart';

/// WebDAV backup configuration screen.
///
/// Allows Pro+ users to set up remote backup to a WebDAV-compatible server.
/// Credentials are persisted via [FlutterSecureStorage].
class WebdavSettingsPage extends StatefulWidget {
  const WebdavSettingsPage({super.key});

  @override
  State<WebdavSettingsPage> createState() => _WebdavSettingsPageState();
}

class _WebdavSettingsPageState extends State<WebdavSettingsPage> {
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = true;
  bool _testing = false;
  String? _testResult;
  bool _testSuccess = false;
  List<String> _backups = [];
  bool _loadingBackups = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await WebdavBackupService.loadSettings();
    if (settings != null) {
      _urlController.text = settings.url;
      _usernameController.text = settings.username;
      _passwordController.text = settings.password;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final settings = WebdavSettings(
      url: _urlController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );
    final urlErr = validateWebdavUrl(settings.url);
    if (urlErr != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(urlErr)),
      );
      return;
    }
    await WebdavBackupService.saveSettings(settings);
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    await _save();
    final settings = await WebdavBackupService.loadSettings();
    if (settings == null) {
      setState(() {
        _testing = false;
        _testResult = 'Please fill in all fields.';
        _testSuccess = false;
      });
      return;
    }
    final error = await WebdavBackupService.testConnection(settings);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = error ?? 'Connection successful!';
      _testSuccess = error == null;
    });
    if (error == null) {
      _loadBackups();
    }
  }

  Future<void> _loadBackups() async {
    final settings = await WebdavBackupService.loadSettings();
    if (settings == null) return;
    setState(() => _loadingBackups = true);
    final list = await WebdavBackupService.listBackups(settings);
    if (mounted) setState(() {
      _backups = list;
      _loadingBackups = false;
    });
  }

  Future<void> _uploadBackup() async {
    setState(() => _uploading = true);
    final settings = await WebdavBackupService.loadSettings();
    if (settings == null) {
      if (mounted) setState(() => _uploading = false);
      return;
    }
    final name = await WebdavBackupService.uploadBackup(settings);
    if (!mounted) return;
    setState(() => _uploading = false);
    if (name != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup uploaded: $name')),
      );
      _loadBackups();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upload failed. Check server connection.')),
      );
    }
  }

  Future<void> _restore(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(
          'This will overwrite your current queue, caps, and upsell state '
          'with the data from $name.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final settings = await WebdavBackupService.loadSettings();
    if (settings == null) return;
    final localPath = await WebdavBackupService.downloadBackup(settings, name);
    if (localPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download failed.')),
        );
      }
      return;
    }
    final ok = await WebdavBackupService.restoreFromBackup(localPath);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Restore complete.' : 'Restore failed.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    return Scaffold(
      backgroundColor: ac.surfaceField,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)?.lblWebdavTitle ?? 'WebDAV Backup'),
        backgroundColor: ac.surfacePanel,
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_upload_outlined),
            tooltip: 'Upload backup now',
            onPressed: _uploading ? null : _uploadBackup,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Server URL
                Text('Server URL',
                    style: TextStyle(
                        color: ac.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    hintText: 'https://nextcloud.example.com/remote.php/dav/files/user/',
                    hintStyle: TextStyle(color: ac.textSecondary, fontSize: 13),
                    filled: true,
                    fillColor: ac.surfacePanel,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  style: TextStyle(color: ac.textPrimary, fontSize: 14),
                ),
                const SizedBox(height: 16),

                // Username
                Text('Username',
                    style: TextStyle(
                        color: ac.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                TextField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    hintText: 'username',
                    hintStyle: TextStyle(color: ac.textSecondary, fontSize: 13),
                    filled: true,
                    fillColor: ac.surfacePanel,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  style: TextStyle(color: ac.textPrimary, fontSize: 14),
                ),
                const SizedBox(height: 16),

                // Password / App password
                Text('Password',
                    style: TextStyle(
                        color: ac.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'password or app token',
                    hintStyle: TextStyle(color: ac.textSecondary, fontSize: 13),
                    filled: true,
                    fillColor: ac.surfacePanel,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  style: TextStyle(color: ac.textPrimary, fontSize: 14),
                ),
                const SizedBox(height: 24),

                // Test connection button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.wifi_find),
                    label: Text(_testing ? 'Testing…' : 'Test connection'),
                  ),
                ),

                // Test result
                if (_testResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Icon(
                          _testSuccess
                              ? Icons.check_circle
                              : Icons.error_outline,
                          size: 18,
                          color:
                              _testSuccess ? Colors.green : Colors.red.shade300,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _testResult!,
                            style: TextStyle(
                              color: ac.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 24),

                // Backup list section
                if (_testSuccess) ...[
                  Text('Remote backups',
                      style: TextStyle(
                          color: ac.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  if (_loadingBackups)
                    const Center(child: CircularProgressIndicator())
                  else if (_backups.isEmpty)
                    Text('No backups yet. Tap the upload button to create one.',
                        style: TextStyle(
                            color: ac.textSecondary, fontSize: 13))
                  else
                    ...List.generate(_backups.length, (i) {
                      final name = _backups[i];
                      return ListTile(
                        dense: true,
                        title: Text(name,
                            style: TextStyle(
                                color: ac.textPrimary, fontSize: 13)),
                        trailing: IconButton(
                          icon: Icon(Icons.restore_outlined,
                              color: ac.accentFrost, size: 20),
                          tooltip: 'Restore',
                          onPressed: () => _restore(name),
                        ),
                      );
                    }),
                ],
              ],
            ),
    );
  }
}
