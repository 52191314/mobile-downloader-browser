/// FFmpeg Studio — Ultra-only media processing UI.
///
/// Provides compress, trim, audio extract, and GIF operations on completed
/// downloads. All operations are gated behind [ProFeature.ffmpegSuite].
///
/// Gate: Ultra tier only. Free/Pro users see an upsell.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../premium/ffmpeg/ffmpeg_job.dart';
import '../../premium/ffmpeg/ffmpeg_module_loader.dart';
import '../../premium/ffmpeg/ffmpeg_service.dart';
import '../../premium/pro_entitlement.dart';
import '../../premium/pro_features.dart';
import '../../premium/pro_upsell_sheet.dart';
import '../../platform/public_downloads_service.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/aurora_palette.dart';
import '../notifications/aurora_snackbar.dart';
import '../widgets/panel.dart';

/// Full-screen FFmpeg Studio for processing completed downloads.
class FfmpegStudioPage extends StatefulWidget {
  final FfmpegService ffmpegService;
  final ProEntitlement proEntitlement;
  final List<FfmpegStudioItem> items;
  final void Function(FfmpegStudioItem item, String outputPath)?
      onOperationComplete;

  const FfmpegStudioPage({
    super.key,
    required this.ffmpegService,
    required this.proEntitlement,
    required this.items,
    this.onOperationComplete,
  });

  @override
  State<FfmpegStudioPage> createState() => _FfmpegStudioPageState();
}

/// An item available for FFmpeg operations — typically a completed download.
class FfmpegStudioItem {
  final String id;
  final String name;
  final String filePath;
  final int fileSizeBytes;

  const FfmpegStudioItem({
    required this.id,
    required this.name,
    required this.filePath,
    this.fileSizeBytes = 0,
  });
}

/// MediaStore RELATIVE_PATH for FFmpeg Studio outputs
/// (same destination root as downloads/auto-backups).
const String _ffmpegOutputRelativePath = 'Download/Aurora Downloader/FFmpeg';

/// User-facing label for the output destination (`Downloads/...`).
const String _ffmpegOutputLabel = 'Downloads/Aurora Downloader/FFmpeg';

class _FfmpegStudioPageState extends State<FfmpegStudioPage> {
  FfmpegOp _selectedOp = FfmpegOp.compress;
  int _selectedItemIndex = 0;

  // Compress params
  int _crf = 28;
  String _preset = 'fast';

  // Trim params
  final _startController = TextEditingController(text: '0');
  final _endController = TextEditingController(text: '');

  // Audio extract format
  String _audioFormat = 'm4a';

  // GIF params
  int _gifFps = 10;
  int _gifWidth = 320;
  final _gifStartController = TextEditingController(text: '0');
  final _gifDurationController = TextEditingController(text: '5');

  /// Job ids whose output has already been published to public Downloads.
  final Set<String> _publishedJobIds = {};

  @override
  void dispose() {
    widget.ffmpegService.removeListener(_onServiceChanged);
    _startController.dispose();
    _endController.dispose();
    _gifStartController.dispose();
    _gifDurationController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.ffmpegService.addListener(_onServiceChanged);
  }

  @override
  void didUpdateWidget(covariant FfmpegStudioPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ffmpegService != widget.ffmpegService) {
      oldWidget.ffmpegService.removeListener(_onServiceChanged);
      widget.ffmpegService.addListener(_onServiceChanged);
    }
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
    _publishCompletedOutput();
  }

  /// Publishes a just-completed job's output into public Downloads
  /// (`Downloads/Aurora Downloader/FFmpeg/…`) and deletes the private scratch
  /// copy. FFmpeg itself must write to a real local path, so outputs are
  /// produced next to the (private) source and only moved to MediaStore once
  /// the job succeeds.
  Future<void> _publishCompletedOutput() async {
    final job = widget.ffmpegService.current;
    if (job == null ||
        job.state != FfmpegJobState.completed ||
        _publishedJobIds.contains(job.id)) {
      return;
    }
    final outputPath = job.outputPath;
    final outputFile = File(outputPath);
    if (!outputFile.existsSync()) return;
    _publishedJobIds.add(job.id);

    final displayName = outputPath.replaceAll('\\', '/').split('/').last;
    final uri = await PublicDownloadsService.publishToPublicDownloads(
      sourcePath: outputPath,
      displayName: displayName,
      relativePath: _ffmpegOutputRelativePath,
      mimeType: PublicDownloadsService.mimeTypeForName(outputPath),
    );

    if (uri != null) {
      // Published — drop the private scratch copy.
      try {
        await outputFile.delete();
      } catch (_) {}
      if (mounted) {
        AuroraSnackbar.show(context, 'Saved to $_ffmpegOutputLabel/$displayName');
      }
    } else {
      if (mounted) {
        AuroraSnackbar.show(
          context,
          'Couldn\'t publish to $_ffmpegOutputLabel — output kept at $outputPath',
        );
      }
    }
  }

  /// Ensures the FFmpeg on-demand module is installed (Play) or ready (GitHub).
  /// Returns `true` if the module is ready to use.
  Future<bool> _ensureModuleReady(BuildContext context) async {
    final loader = FeatureModuleLoader.instance;
    final status = loader.statusFor('ffmpeg');
    if (status == FeatureModuleStatus.ready ||
        status == FeatureModuleStatus.notNeeded) {
      return true;
    }

    if (status == FeatureModuleStatus.downloading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('FFmpeg module is still downloading…')),
      );
      return false;
    }

    // Show download confirmation.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download FFmpeg tools?'),
        content: const Text(
          'FFmpeg media tools need a one-time download (~10 MB). '
          'Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    if (!mounted) return false;

    final ok = await loader.ensureInstalled('ffmpeg');
    if (!mounted) return false;

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('FFmpeg tools ready.')),
      );
      return true;
    }

    // Failure — offer retry.
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download failed'),
        content: const Text(
          'Could not download the FFmpeg module. '
          'Check your network and try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
    if (retry == true && mounted) {
      return _ensureModuleReady(context);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Gate check — redirect to upsell if not Ultra
    if (!ProFeatures.allows(ProFeature.ffmpegSuite, widget.proEntitlement.tier)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pop();
          showProUpsell(context, ProFeature.ffmpegSuite);
        }
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    if (widget.items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(AppLocalizations.of(context)?.lblFfmpegStudioTitle ?? 'FFmpeg Studio')),
        body: Center(
          child: Text(
            'No completed downloads available.',
            style: TextStyle(color: context.ac.textSecondary),
          ),
        ),
      );
    }

    final item = _selectedItemIndex < widget.items.length
        ? widget.items[_selectedItemIndex]
        : widget.items.last;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)?.lblFfmpegStudioTitle ?? 'FFmpeg Studio'),
      ),
      body: ListenableBuilder(
        listenable: widget.ffmpegService,
        builder: (context, _) {
          final running = widget.ffmpegService.isRunning;
          final job = widget.ffmpegService.current;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // File selector
              PanelHeader(icon: Icons.video_file_outlined, title: AppLocalizations.of(context)!.ffmpegSourceFile),
              const SizedBox(height: 8),
              Panel(
                child: _buildItemSelector(item),
              ),
              const SizedBox(height: 16),

              // Operation selector
              PanelHeader(icon: Icons.tune, title: AppLocalizations.of(context)!.ffmpegOperation),
              const SizedBox(height: 8),
              Panel(
                child: Column(
                  children: [
                    _buildOperationSelector(),
                    const Divider(height: 1),
                    _buildOperationParams(),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Output path display
              _buildOutputPreview(item),

              const SizedBox(height: 24),

              // Progress / action
              if (running && job != null)
                _buildProgressCard(job)
              else ...[
                // Start button
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _startJob(item),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(_operationLabel),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (running) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => widget.ffmpegService.cancelCurrent(),
                      icon: const Icon(Icons.stop_rounded),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.ac.statusError,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ],

              // Pending jobs
              if (widget.ffmpegService.pending.isNotEmpty) ...[
                const SizedBox(height: 20),
                PanelHeader(
                    icon: Icons.queue_play_next, title: AppLocalizations.of(context)!.ffmpegQueuedOps),
                const SizedBox(height: 8),
                Panel(
                  child: Column(
                    children: [
                      for (final j in widget.ffmpegService.pending)
                        _buildQueuedJobTile(j),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  // ── Item selector ──
  Widget _buildItemSelector(FfmpegStudioItem item) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            value: _selectedItemIndex,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'File',
              isDense: true,
            ),
            items: List.generate(widget.items.length, (i) {
              return DropdownMenuItem(
                value: i,
                child: Text(
                  widget.items[i].name,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }),
            onChanged: (v) {
              if (v != null) setState(() => _selectedItemIndex = v);
            },
          ),
          const SizedBox(height: 4),
          Text(
            item.filePath,
            style: TextStyle(
              fontSize: 11,
              color: context.ac.textTertiary,
              fontFamily: 'JetBrainsMono',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ── Operation selector ──
  String get _operationLabel {
    switch (_selectedOp) {
      case FfmpegOp.compress:
        return 'Compress Video';
      case FfmpegOp.trim:
        return 'Trim Video';
      case FfmpegOp.audioExtract:
        return 'Extract Audio';
      case FfmpegOp.remux:
        return 'Remux to MP4';
      case FfmpegOp.gif:
        return 'Create GIF';
    }
  }

  Widget _buildOperationSelector() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: DropdownButtonFormField<FfmpegOp>(
        value: _selectedOp,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Operation',
          isDense: true,
        ),
        items: [
          DropdownMenuItem(
              value: FfmpegOp.compress, child: Text('Compress Video')),
          DropdownMenuItem(value: FfmpegOp.trim, child: Text('Trim Video')),
          DropdownMenuItem(
              value: FfmpegOp.audioExtract, child: Text('Extract Audio')),
          DropdownMenuItem(value: FfmpegOp.remux, child: Text('Remux to MP4')),
          DropdownMenuItem(
              value: FfmpegOp.gif, child: Text('Create GIF')),
        ],
        onChanged: (v) {
          if (v != null) setState(() => _selectedOp = v);
        },
      ),
    );
  }

  // ── Operation-specific parameters ──
  Widget _buildOperationParams() {
    switch (_selectedOp) {
      case FfmpegOp.compress:
        return _buildCompressParams();
      case FfmpegOp.trim:
        return _buildTrimParams();
      case FfmpegOp.audioExtract:
        return _buildAudioExtractParams();
      case FfmpegOp.remux:
        return _buildRemuxParams();
      case FfmpegOp.gif:
        return _buildGifParams();
    }
  }

  Widget _buildCompressParams() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Quality (CRF): $_crf'),
          _slider(_crf.toDouble(), 18, 51, '${_crf}', (v) {
            setState(() => _crf = v.round());
          }),
          _paramHint('Lower = better quality, larger file. 18 is near-lossless.'),
          const SizedBox(height: 12),
          _label('Speed preset: $_preset'),
          DropdownButtonFormField<String>(
            value: _preset,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              DropdownMenuItem(value: 'ultrafast', child: Text('Ultrafast')),
              DropdownMenuItem(value: 'superfast', child: Text('Superfast')),
              DropdownMenuItem(value: 'veryfast', child: Text('Veryfast')),
              DropdownMenuItem(value: 'faster', child: Text('Faster')),
              DropdownMenuItem(value: 'fast', child: Text('Fast')),
              DropdownMenuItem(value: 'medium', child: Text('Medium')),
              DropdownMenuItem(value: 'slow', child: Text('Slow (better compression)')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _preset = v);
            },
          ),
          _paramHint('Faster presets reduce encoding time but produce larger files.'),
        ],
      ),
    );
  }

  Widget _buildTrimParams() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Start time (seconds)'),
          TextField(
            controller: _startController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: '0',
              isDense: true,
              suffixText: 's',
            ),
          ),
          const SizedBox(height: 12),
          _label('End time (seconds, leave empty for end of file)'),
          TextField(
            controller: _endController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: 'e.g. 30',
              isDense: true,
              suffixText: 's',
            ),
          ),
          _paramHint('Trim uses stream copy — fast and lossless.'),
        ],
      ),
    );
  }

  Widget _buildAudioExtractParams() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Output format'),
          DropdownButtonFormField<String>(
            value: _audioFormat,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              DropdownMenuItem(value: 'm4a', child: Text('M4A (AAC)')),
              DropdownMenuItem(value: 'mp3', child: Text('MP3')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _audioFormat = v);
            },
          ),
          _paramHint('Extracts audio track only — video is discarded.'),
        ],
      ),
    );
  }

  Widget _buildRemuxParams() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: _paramHint(
        'Remux converts the container format without re-encoding. '
        'Fast and lossless. Useful for .ts to .mp4 conversion.',
      ),
    );
  }

  Widget _buildGifParams() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('FPS: $_gifFps'),
          _slider(_gifFps.toDouble(), 5, 15, '${_gifFps}', (v) {
            setState(() => _gifFps = v.round());
          }),
          _paramHint('Higher FPS = smoother but larger file.'),
          const SizedBox(height: 12),
          _label('Width: $_gifWidth px'),
          _slider(_gifWidth.toDouble(), 160, 640, '${_gifWidth}', (v) {
            setState(() => _gifWidth = v.round());
          }),
          _paramHint('Width in pixels. Height scales automatically.'),
          const SizedBox(height: 12),
          _label('Start time (seconds)'),
          TextField(
            controller: _gifStartController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: '0',
              isDense: true,
              suffixText: 's',
            ),
          ),
          const SizedBox(height: 12),
          _label('Duration (max 30 seconds)'),
          TextField(
            controller: _gifDurationController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: '5',
              isDense: true,
              suffixText: 's',
            ),
          ),
        ],
      ),
    );
  }

  // ── Output preview ──
  /// Output file name (e.g. `video_compressed.mp4`) for the selected operation.
  String _outputFileName(FfmpegStudioItem item) {
    final baseName = item.name.replaceAll(RegExp(r'\.[^.]+$'), '');
    String suffix;
    switch (_selectedOp) {
      case FfmpegOp.compress:
        suffix = '_compressed.mp4';
        break;
      case FfmpegOp.trim:
        suffix = '_trimmed.mp4';
        break;
      case FfmpegOp.audioExtract:
        suffix = '.$_audioFormat';
        break;
      case FfmpegOp.remux:
        suffix = '.mp4';
        break;
      case FfmpegOp.gif:
        suffix = '.gif';
        break;
    }
    // Android filesystems cap filename components at 255 BYTES, and the
    // completed download's name is not length-bounded upstream. A long
    // video title + the operation suffix would overflow the limit and the
    // job would fail (ENAMETOOLONG) at write/publish. Truncate byte-aware
    // (UTF-8) so multibyte titles keep their tail without cutting a
    // character in half.
    final budget = 255 - utf8.encode(suffix).length;
    var name = baseName;
    while (name.isNotEmpty && utf8.encode(name).length > budget) {
      name = name.substring(0, name.length - 1);
    }
    return '$name$suffix';
  }

  Widget _buildOutputPreview(FfmpegStudioItem item) {
    final outputPath = '$_ffmpegOutputLabel/${_outputFileName(item)}';

    return Panel(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.output_outlined,
                    size: 16, color: context.ac.accentFrost),
                const SizedBox(width: 8),
                Text(
                  'Output',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.ac.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              outputPath,
              style: TextStyle(
                fontSize: 11,
                color: context.ac.textTertiary,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Progress ──
  Widget _buildProgressCard(FfmpegJob job) {
    return Panel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    job.state == FfmpegJobState.completed
                        ? 'Complete'
                        : job.state == FfmpegJobState.failed
                            ? 'Failed'
                            : 'Processing…',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: context.ac.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '${(job.progress * 100).round()}%',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: context.ac.accentFrost,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: job.progress.clamp(0.0, 1.0),
              backgroundColor: context.ac.surfaceElevated,
              color: job.state == FfmpegJobState.failed
                  ? context.ac.statusError
                  : context.ac.accentFrost,
            ),
            if (job.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                job.errorMessage!,
                style: TextStyle(
                  fontSize: 11,
                  color: context.ac.statusError,
                ),
              ),
            ],
            if (job.elapsedSeconds != null) ...[
              const SizedBox(height: 4),
              Text(
                'Elapsed: ${job.elapsedSeconds!.toStringAsFixed(1)}s',
                style: TextStyle(
                  fontSize: 11,
                  color: context.ac.textTertiary,
                ),
              ),
            ],
            if (job.state == FfmpegJobState.running) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => widget.ffmpegService.cancelCurrent(),
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('Cancel'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.ac.statusError,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Queued job ──
  Widget _buildQueuedJobTile(FfmpegJob job) {
    return ListTile(
      leading: Icon(
        Icons.movie_outlined,
        color: context.ac.textTertiary,
        size: 20,
      ),
      title: Text(
        _opNameForJob(job),
        style: TextStyle(fontSize: 13, color: context.ac.textPrimary),
      ),
      subtitle: Text(
        job.inputPath.split('/').last,
        style: TextStyle(
          fontSize: 11,
          color: context.ac.textSecondary,
          fontFamily: 'JetBrainsMono',
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        onPressed: () {
          widget.ffmpegService.cancelPending(job.id);
        },
      ),
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }

  String _opNameForJob(FfmpegJob job) {
    switch (job.operation) {
      case FfmpegOp.compress:
        return 'Compress';
      case FfmpegOp.trim:
        return 'Trim';
      case FfmpegOp.audioExtract:
        return 'Audio Extract';
      case FfmpegOp.remux:
        return 'Remux';
      case FfmpegOp.gif:
        return 'GIF';
    }
  }

  // ── Start job ──
  Future<void> _startJob(FfmpegStudioItem item) async {
    // Safety net: ensure FFmpeg module is ready before starting any job.
    // The primary check happens before navigation, but this guards against
    // edge cases where the module was uninstalled or the process was killed.
    final loader = FeatureModuleLoader.instance;
    final status = loader.statusFor('ffmpeg');
    if (status != FeatureModuleStatus.ready &&
        status != FeatureModuleStatus.notNeeded) {
      if (!mounted) return;
      final ok = await _ensureModuleReady(context);
      if (!ok || !mounted) return;
    }

    final outputPath =
        '${Directory(item.filePath).parent.path}/${_outputFileName(item)}';

    FfmpegJob job;
    switch (_selectedOp) {
      case FfmpegOp.compress:
        job = FfmpegJob(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          inputPath: item.filePath,
          outputPath: outputPath,
          operation: FfmpegOp.compress,
          compressParams: FfmpegCompressParams(crf: _crf, preset: _preset),
        );
        break;
      case FfmpegOp.trim:
        final startSec = double.tryParse(_startController.text) ?? 0;
        final endText = _endController.text.trim();
        final endSec = endText.isNotEmpty ? double.tryParse(endText) : null;
        job = FfmpegJob(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          inputPath: item.filePath,
          outputPath: outputPath,
          operation: FfmpegOp.trim,
          trimParams: FfmpegTrimParams(startSeconds: startSec, endSeconds: endSec),
        );
        break;
      case FfmpegOp.audioExtract:
        job = FfmpegJob(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          inputPath: item.filePath,
          outputPath: outputPath,
          operation: FfmpegOp.audioExtract,
        );
        break;
      case FfmpegOp.remux:
        job = FfmpegJob(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          inputPath: item.filePath,
          outputPath: outputPath,
          operation: FfmpegOp.remux,
        );
        break;
      case FfmpegOp.gif:
        final gifStart = double.tryParse(_gifStartController.text) ?? 0;
        final gifDur =
            (double.tryParse(_gifDurationController.text) ?? 5).clamp(1, 30);
        job = FfmpegJob(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          inputPath: item.filePath,
          outputPath: outputPath,
          operation: FfmpegOp.gif,
          gifParams: FfmpegGifParams(
            fps: _gifFps,
            width: _gifWidth,
            startSeconds: gifStart,
            durationSeconds: gifDur.toDouble(),
          ),
        );
        break;
    }

    widget.ffmpegService.enqueue(job);

    if (mounted) {
      AuroraSnackbar.show(context, 'FFmpeg job queued — ${_operationLabel}');
    }
  }

  // ── Widget helpers ──
  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: context.ac.textPrimary,
        ),
      ),
    );
  }

  Widget _slider(double value, double min, double max, String label,
      ValueChanged<double> onChanged) {
    return SliderTheme(
      data: SliderThemeData(
        activeTrackColor: context.ac.accentFrost,
        inactiveTrackColor: context.ac.surfaceElevated,
        thumbColor: context.ac.accentFrost,
        overlayColor: context.ac.accentFrost.withValues(alpha: 0.14),
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: (max - min).round(),
        label: label,
        onChanged: onChanged,
      ),
    );
  }

  Widget _paramHint(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: context.ac.textTertiary,
        ),
      ),
    );
  }
}
