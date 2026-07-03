import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

import '../theme/aurora_colors.dart';

class PipPlayerScreen extends StatefulWidget {
  final String url;
  final String title;
  final Map<String, String> headers;

  const PipPlayerScreen({
    super.key,
    required this.url,
    required this.title,
    this.headers = const {},
  });

  @override
  State<PipPlayerScreen> createState() => _PipPlayerScreenState();
}

class _PipPlayerScreenState extends State<PipPlayerScreen> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  String? _error;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null || !uri.hasScheme) {
      setState(() {
        _error = 'Invalid video URL';
        _initialized = true;
      });
      return;
    }
    try {
      final controller = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: widget.headers,
      );
      _videoController = controller;
      await controller.initialize();
      final chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        allowPlaybackSpeedChanging: true,
        showControls: true,
        showControlsOnInitialize: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: AuroraColors.accent,
          handleColor: AuroraColors.accent,
          backgroundColor: Colors.white24,
          bufferedColor: Colors.white12,
        ),
      );
      _chewieController = chewie;
      if (mounted) {
        setState(() => _initialized = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not play this media: $e';
          _initialized = true;
        });
      }
    }
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Toggle fullscreen',
            icon: const Icon(Icons.fullscreen),
            onPressed: () {
              _chewieController?.enterFullScreen();
            },
          ),
        ],
      ),
      body: _initialized
          ? (_error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  )
                : (_chewieController == null
                      ? const Center(child: CircularProgressIndicator())
                      : Chewie(controller: _chewieController!)))
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
