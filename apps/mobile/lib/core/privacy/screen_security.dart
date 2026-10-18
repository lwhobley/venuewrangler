import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Asks the host platform to hide the app's window contents from screenshots, screen recording
/// and the recents thumbnail. Only Android can do this (`FLAG_SECURE`, see `MainActivity.kt`);
/// on iOS the app-switcher snapshot is covered by `PrivacyOverlay` instead, and elsewhere this
/// is a no-op.
///
/// Several screens may want protection at once (a screen pushed over another one), so requests
/// are counted: the flag is set by the first [acquire] and cleared by the last [release].
class ScreenSecurityService {
  ScreenSecurityService({
    MethodChannel? channel,
    bool Function()? isSupported,
  })  : _channel = channel ??
            const MethodChannel('com.venuewrangler.app/screen_security'),
        _isSupported = isSupported ??
            (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool Function() _isSupported;
  int _holders = 0;

  @visibleForTesting
  int get holders => _holders;

  Future<void> acquire() async {
    _holders++;
    if (_holders == 1) await _apply(true);
  }

  Future<void> release() async {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) await _apply(false);
  }

  Future<void> _apply(bool secure) async {
    if (!_isSupported()) return;
    try {
      await _channel.invokeMethod<void>('setSecure', {'secure': secure});
    } on PlatformException catch (error) {
      debugPrint('Screen security could not be applied: $error');
    } on MissingPluginException {
      // Host without the channel (a test host, an older embedder): nothing to protect.
    }
  }
}

final screenSecurityServiceProvider =
    Provider<ScreenSecurityService>((ref) => ScreenSecurityService());

/// Wrap a screen that shows HR records, pay, documents or incident evidence. While the screen is
/// actually visible (not merely kept alive in a background tab or under another route) the
/// window is marked secure.
class SecureScreen extends ConsumerStatefulWidget {
  const SecureScreen({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends ConsumerState<SecureScreen> {
  late final ScreenSecurityService _service;
  bool _held = false;

  @override
  void initState() {
    super.initState();
    // Captured now: `ref` must not be used from dispose().
    _service = ref.read(screenSecurityServiceProvider);
  }

  void _sync(bool visible) {
    if (visible == _held) return;
    _held = visible;
    if (visible) {
      _service.acquire();
    } else {
      _service.release();
    }
  }

  @override
  void dispose() {
    _sync(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Disabled for routes covered by an opaque route and for inactive shell branches, which
    // stay mounted but cannot be seen.
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _held) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync(TickerMode.valuesOf(context).enabled);
      });
    }
    return widget.child;
  }
}
