import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Plays the branded intro video once when the app opens, then calls [onFinished].
/// Tapping anywhere skips straight to [onFinished] in case the video fails to load or
/// the person just doesn't want to wait.
class IntroVideoScreen extends StatefulWidget {
  const IntroVideoScreen({required this.onFinished, super.key});

  final VoidCallback onFinished;

  @override
  State<IntroVideoScreen> createState() => _IntroVideoScreenState();
}

class _IntroVideoScreenState extends State<IntroVideoScreen> {
  late final VideoPlayerController _controller;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset('assets/video/intro.mp4')
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        _controller.play();
      }).catchError((_) {
        // A corrupt asset or unsupported codec on this device must not block app launch.
        _finish();
      });
    _controller.addListener(_onTick);
  }

  void _onTick() {
    final value = _controller.value;
    if (value.isInitialized &&
        !value.isPlaying &&
        value.position >= value.duration &&
        value.duration > Duration.zero) {
      _finish();
    }
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    widget.onFinished();
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _finish,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: _controller.value.isInitialized
              ? AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                )
              : const CircularProgressIndicator(color: Colors.white),
        ),
      ),
    );
  }
}
