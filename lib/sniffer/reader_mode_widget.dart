import 'dart:convert';
import 'package:flutter/material.dart';

import '../theme/aurora_palette.dart';
import 'browser_controller.dart';

class ReaderModeWidget extends StatefulWidget {
  final SnifferBrowserController controller;

  const ReaderModeWidget({super.key, required this.controller});

  @override
  State<ReaderModeWidget> createState() => _ReaderModeWidgetState();
}

class _ReaderModeWidgetState extends State<ReaderModeWidget> {
  String? _title;
  String? _content;
  bool _loading = true;
  String? _error;
  double _fontSize = 16.0;

  @override
  void initState() {
    super.initState();
    _extractContent();
  }

  Future<void> _extractContent() async {
    try {
      final title = await widget.controller.pageTitle();
      final result = await widget.controller.evaluateJavaScript('''
(function() {
  function getText(root, depth) {
    if (depth > 20) return "";
    var tag = (root.tagName || "").toLowerCase();
    if (tag === "script" || tag === "style" || tag === "noscript" ||
        tag === "iframe" || tag === "svg" || tag === "nav" ||
        tag === "footer" || tag === "header") return "";
    if (tag === "p" || tag === "h1" || tag === "h2" || tag === "h3" ||
        tag === "h4" || tag === "h5" || tag === "h6" || tag === "li" ||
        tag === "td" || tag === "th" || tag === "blockquote" || tag === "pre") {
      var text = (root.textContent || "").trim();
      return text ? tag + "::" + text + "\\n\\n" : "";
    }
    var result = "";
    var children = root.childNodes;
    for (var i = 0; i < children.length; i++) {
      result += getText(children[i], depth + 1);
    }
    return result;
  }
  var article = document.querySelector("article") ||
      document.querySelector("main") ||
      document.querySelector('[role="main"]') ||
      document.querySelector(".content") ||
      document.body;
  return JSON.stringify({
    title: document.title || "",
    html: getText(article, 0).substring(0, 50000)
  });
})()
''');

      if (mounted) {
        setState(() {
          _loading = false;
          _title = title ?? 'Reader';
          if (result != null) {
            final str = result.toString();
            final decoded = _jsonDecodeSafe(str);
            if (decoded.isNotEmpty) {
              _content = decoded['html']?.toString();
              final decodedTitle = decoded['title']?.toString();
              if (decodedTitle != null && decodedTitle.trim().isNotEmpty) {
                _title = decodedTitle;
              }
            } else {
              _content = str;
            }
          }
          if (_content == null || _content!.trim().isEmpty) {
            _error = 'No readable content found on this page.';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Reader mode failed: $e';
        });
      }
    }
  }

  Map<String, dynamic> _jsonDecodeSafe(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    try {
      dynamic decoded = jsonDecode(trimmed);
      if (decoded is String) {
        decoded = jsonDecode(decoded.trim());
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Fallback for non-JSON strings
    }
    return <String, dynamic>{};
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      backgroundColor: ac.surfaceField,
      appBar: AppBar(
        title: Text(_title ?? 'Reader'),
        actions: [
          if (_content != null) ...[
            IconButton(
              icon: const Icon(Icons.text_decrease),
              tooltip: 'Smaller text',
              onPressed: _fontSize > 12.0
                  ? () => setState(
                        () => _fontSize = (_fontSize - 2.0).clamp(12.0, 28.0),
                      )
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.text_increase),
              tooltip: 'Larger text',
              onPressed: _fontSize < 28.0
                  ? () => setState(
                        () => _fontSize = (_fontSize + 2.0).clamp(12.0, 28.0),
                      )
                  : null,
            ),
          ],
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _buildStructuredContent(),
            ),
    );
  }

  Widget _buildStructuredContent() {
    final ac = context.ac;
    if (_content == null) return const SizedBox.shrink();
    final blocks = _content!.split('\n\n');
    final widgets = <Widget>[];

    for (final block in blocks) {
      final trimmed = block.trim();
      if (trimmed.isEmpty) continue;

      final separatorIdx = trimmed.indexOf('::');
      if (separatorIdx == -1) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              trimmed,
              style: TextStyle(
                fontSize: _fontSize,
                height: 1.6,
                color: ac.textPrimary,
              ),
            ),
          ),
        );
        continue;
      }

      final tag = trimmed.substring(0, separatorIdx).toLowerCase();
      final text = trimmed.substring(separatorIdx + 2);

      switch (tag) {
        case 'h1':
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                text,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontSize: _fontSize * 1.5,
                  fontWeight: FontWeight.w700,
                  color: ac.textPrimary,
                ),
              ),
            ),
          );
          break;
        case 'h2':
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                text,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontSize: _fontSize * 1.3,
                  fontWeight: FontWeight.w700,
                  color: ac.textPrimary,
                ),
              ),
            ),
          );
          break;
        case 'h3':
        case 'h4':
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                text,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: _fontSize * 1.15,
                  fontWeight: FontWeight.w600,
                  color: ac.textPrimary,
                ),
              ),
            ),
          );
          break;
        case 'blockquote':
          widgets.add(
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: ac.accentFrost, width: 3),
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: _fontSize,
                  fontStyle: FontStyle.italic,
                  color: ac.textSecondary,
                ),
              ),
            ),
          );
          break;
        case 'pre':
          widgets.add(
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ac.surfacePanel,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: _fontSize * 0.85,
                  height: 1.5,
                ),
              ),
            ),
          );
          break;
        default:
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: _fontSize,
                  height: 1.6,
                  color: ac.textPrimary,
                ),
              ),
            ),
          );
      }
    }

    if (widgets.isEmpty) {
      return const Text('No content extracted.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

