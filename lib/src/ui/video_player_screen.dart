import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Streams a video from the server (Range-enabled `/api/raw`) with native
/// controls. Auth is passed via the `X-Auth` HTTP header.
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.url,
    required this.headers,
    required this.title,
  });

  final Uri url;
  final Map<String, String> headers;
  final String title;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final video =
          VideoPlayerController.networkUrl(widget.url, httpHeaders: widget.headers);
      await video.initialize();
      if (!mounted) {
        video.dispose();
        return;
      }
      setState(() {
        _video = video;
        _chewie = ChewieController(
          videoPlayerController: video,
          autoPlay: true,
          looping: false,
          aspectRatio: video.value.aspectRatio,
          allowFullScreen: true,
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not play video:\n$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              )
            : _chewie != null
                ? Chewie(controller: _chewie!)
                : const CircularProgressIndicator(),
      ),
    );
  }
}
