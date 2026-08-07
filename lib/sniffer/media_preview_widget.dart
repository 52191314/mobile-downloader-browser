import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

import 'models/sniffed_media.dart';

class MediaPreviewWidget extends StatefulWidget {
  final SniffedMedia media;

  const MediaPreviewWidget({super.key, required this.media});

  @override
  State<MediaPreviewWidget> createState() => _MediaPreviewWidgetState();
}

class _MediaPreviewWidgetState extends State<MediaPreviewWidget> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _initialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _initPlayer() async {
    if (widget.media.type == MediaType.image) {
      setState(() => _initialized = true);
      return;
    }

    final uri = Uri.tryParse(widget.media.url);
    if (uri == null || (!uri.hasScheme)) {
      setState(() {
        _error = 'Could not open this media. The URL is not valid.';
        _initialized = true;
      });
      return;
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: widget.media.headers,
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
          playedColor: Colors.amber,
          handleColor: Colors.amber,
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
          _error = 'Could not play this media.';
          _initialized = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.media.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Download this item',
            onPressed: () => Navigator.pop(context, 'download'),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (widget.media.type == MediaType.image) {
      return InteractiveViewer(
        child: Center(
          child: Image.network(
            widget.media.url,
            headers: widget.media.headers,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(child: CircularProgressIndicator());
            },
            errorBuilder: (context, error, stack) {
              return Center(
                child: Text(
                  'Could not load this image.',
                  style: const TextStyle(color: Colors.white70),
                ),
              );
            },
          ),
        ),
      );
    }

    if (_chewieController != null &&
        _videoController != null &&
        _videoController!.value.isInitialized) {
      return Chewie(controller: _chewieController!);
    }

    return const Center(
      child: Text(
        'Preview is not available for this item.',
        style: TextStyle(color: Colors.white70),
      ),
    );
  }
}
