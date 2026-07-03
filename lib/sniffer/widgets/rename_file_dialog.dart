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
        child: TextFormField(
          key: widget.textFieldKey ?? const Key('dialog_filename_input'),
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Filename',
            border: OutlineInputBorder(),
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return 'Filename cannot be empty';
            }
            return null;
          },
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
              Navigator.pop(context, _controller.text.trim());
            }
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}
