import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Covers the app with a plain branded surface whenever it is not the foreground app, so the
/// snapshot the OS shows in the app switcher (and on Android's recents screen) never contains
/// schedules, pay, HR records or incident photos.
///
/// iOS takes that snapshot when the app becomes `inactive`, so the overlay goes up on the first
/// non-resumed state and comes down only on `resumed`. It is only active on iOS and Android: on
/// web and desktop, `inactive` just means the window lost focus and hiding the app would be
/// an annoyance, not a protection.
class PrivacyOverlay extends StatefulWidget {
  const PrivacyOverlay({super.key, required this.child, bool? enabled})
      : _enabled = enabled;

  final Widget child;
  final bool? _enabled;

  static bool get _platformSupportsSwitcherSnapshot =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  State<PrivacyOverlay> createState() => _PrivacyOverlayState();
}

class _PrivacyOverlayState extends State<PrivacyOverlay>
    with WidgetsBindingObserver {
  bool _obscured = false;

  bool get _enabled =>
      widget._enabled ?? PrivacyOverlay._platformSupportsSwitcherSnapshot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final obscure = state != AppLifecycleState.resumed;
    if (obscure != _obscured && mounted) setState(() => _obscured = obscure);
  }

  @override
  Widget build(BuildContext context) {
    // Always a Stack, with the app at a fixed position, so showing and hiding the cover never
    // re-parents the Navigator below (that would discard every route's state).
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_enabled && _obscured)
          const Positioned.fill(child: _PrivacyCover()),
      ],
    );
  }
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Venue Wrangler is hidden',
      child: ExcludeSemantics(
        child: ColoredBox(
          key: const ValueKey('privacy-overlay'),
          color: scheme.surface,
          child: Center(
            child: Icon(
              Icons.lock_outline,
              size: 48,
              color: scheme.onSurface.withAlpha(90),
            ),
          ),
        ),
      ),
    );
  }
}
