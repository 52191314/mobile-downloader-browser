part of '../sniffer_screen.dart';

class _RenameFileDialog extends StatefulWidget {
  final String initialValue;
  final Key? textFieldKey;
  final Key? okButtonKey;

  const _RenameFileDialog({
    required this.initialValue,
    this.textFieldKey,
    this.okButtonKey,
  });

  @override
  State<_RenameFileDialog> createState() => _RenameFileDialogState();
}

class _RenameFileDialogState extends State<_RenameFileDialog> {
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
      title: const Text('Rename File'),
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
            if (_controller.text.length > 120) ...[
              const SizedBox(height: 8),
              const Text(
                '⚠️ Filename exceeds 120 characters. It will be auto-truncated to fit on save, or you can cut it manually.',
                style: TextStyle(
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
              final finalName = _SnifferScreenState.truncateFilename(
                _controller.text.trim(),
                maxLength: 120,
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
