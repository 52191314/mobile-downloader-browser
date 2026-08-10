import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

import '../../downloader/filename_service.dart';
import '../filename_utils.dart';

/// Simple dialog that lets the user rename a filename.  The result is
/// returned via [Navigator.pop] — either the confirmed string or `null`
/// when cancelled.  Names exceeding Android's byte limit are
/// auto-truncated.
class RenameFileDialog extends StatefulWidget {
  final String initialValue;
  final Key? textFieldKey;
  final Key? okButtonKey;

  const RenameFileDialog({
    super.key,
    required this.initialValue,
    this.textFieldKey,
    this.okButtonKey,
  });

  @override
  State<RenameFileDialog> createState() => _RenameFileDialogState();
}

class _RenameFileDialogState extends State<RenameFileDialog> {
  late TextEditingController _controller;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppLocalizations.of(context)!.btnRenameFile),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              key: widget.textFieldKey ?? const Key('dialog_filename_input'),
              controller: _controller,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Filename',
                border: OutlineInputBorder(),
              ),
              onChanged: (val) {
                setState(() {});
              },
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Filename cannot be empty';
                }
                return null;
              },
            ),
            if (FilenameService.utf8ByteLength(_controller.text) >
                FilenameService.defaultMaxFileNameBytes) ...[
              const SizedBox(height: 8),
              Text(
                'Filename exceeds Android\'s ${FilenameService.defaultMaxFileNameBytes}-byte limit. It will be auto-truncated on save, or you can shorten it manually.',
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: widget.okButtonKey ?? const Key('dialog_rename_ok_button'),
          onPressed: () {
            if (_formKey.currentState?.validate() ?? false) {
              final finalName = truncateFilename(
                _controller.text.trim(),
                maxLength: FilenameService.defaultMaxFileNameBytes,
              );
              Navigator.pop(context, finalName);
            }
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// Convenience wrapper that shows [RenameFileDialog] and returns the
/// confirmed name, or `null` if cancelled.
Future<String?> showRenameFileDialog(
  BuildContext context, {
  required String initialValue,
  Key? textFieldKey,
  Key? okButtonKey,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => RenameFileDialog(
      initialValue: initialValue,
      textFieldKey: textFieldKey,
      okButtonKey: okButtonKey,
    ),
  );
}
