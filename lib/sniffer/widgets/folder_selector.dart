import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Dropdown that lets the user pick an existing subfolder under
/// `baseDir/completed`, or create a new one.
class FolderSelector extends StatefulWidget {
  final String? baseDir;
  final ValueChanged<String?> onChanged;

  const FolderSelector({
    super.key,
    required this.baseDir,
    required this.onChanged,
  });

  @override
  State<FolderSelector> createState() => _FolderSelectorState();
}

class _FolderSelectorState extends State<FolderSelector> {
  List<String> _existingFolders = [];
  String? _selectedFolder;
  final TextEditingController _newFolderController = TextEditingController();
  bool _showNewFolderInput = false;

  @override
  void initState() {
    super.initState();
    _loadExistingFolders();
  }

  @override
  void dispose() {
    _newFolderController.dispose();
    super.dispose();
  }

  Future<void> _loadExistingFolders() async {
    try {
      final base = widget.baseDir;
      if (base != null) {
        final completedDir = Directory('$base/completed');
        if (await completedDir.exists()) {
          final List<String> folders = [];
          await for (final entity in completedDir.list()) {
            if (entity is Directory) {
              folders.add(p.basename(entity.path));
            }
          }
          folders.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          if (mounted) {
            setState(() {
              _existingFolders = folders;
            });
          }
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          isExpanded: true,
          value: _selectedFolder,
          decoration: const InputDecoration(
            labelText: 'Download Folder',
            prefixIcon: Icon(Icons.folder_open_outlined),
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<String>(
              value: null,
              child: Text(
                'Default / completed',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ..._existingFolders.map((f) => DropdownMenuItem<String>(
                  value: f,
                  child: Text(
                    f,
                    overflow: TextOverflow.ellipsis,
                  ),
                )),
            const DropdownMenuItem<String>(
              value: '_new_',
              child: Text(
                '[Create new folder...]',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          onChanged: (val) {
            setState(() {
              _selectedFolder = val;
              _showNewFolderInput = val == '_new_';
            });
            if (val != '_new_') {
              widget.onChanged(val);
            } else {
              widget.onChanged(_newFolderController.text.trim());
            }
          },
        ),
        if (_showNewFolderInput) ...[
          const SizedBox(height: 12),
          TextFormField(
            controller: _newFolderController,
            decoration: const InputDecoration(
              labelText: 'New Folder Name',
              hintText: 'e.g. Lecture Videos',
              prefixIcon: Icon(Icons.create_new_folder_outlined),
              border: OutlineInputBorder(),
            ),
            onChanged: (val) {
              widget.onChanged(val.trim());
            },
          ),
        ],
      ],
    );
  }
}
