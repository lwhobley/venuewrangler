import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/app_lock.dart';

/// Covers the whole app with [AppLockScreen] while [appLockProvider] is locked.
///
/// Sits in `MaterialApp.builder`, above the router's Navigator, so the screen the person was on
/// (a half-filled form, an open dialog, a pending notification route) stays mounted underneath
/// and is exactly where they left it after unlocking. While locked that subtree is not painted,
/// takes no input and is hidden from accessibility services.
class AppLockGate extends ConsumerWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = ref.watch(appLockProvider.select((s) => s.locked));
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Visibility(
          visible: !locked,
          maintainState: true,
          child: child,
        ),
        if (locked)
          // Own Navigator so the PIN field has an Overlay (selection handles, menus).
          // HeroControllerScope.none: the app's Navigator already owns MaterialApp's one.
          Positioned.fill(
            child: HeroControllerScope.none(
              child: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => const AppLockScreen(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class AppLockScreen extends ConsumerStatefulWidget {
  const AppLockScreen({super.key});

  @override
  ConsumerState<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<AppLockScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pin.text.trim();
    if (pin.length < 4) {
      setState(() => _error = 'Enter your PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref.read(appLockProvider.notifier).unlock(pin);
    if (!mounted) return;
    _pin.clear();
    setState(() {
      _busy = false;
      _error = switch (result) {
        AppUnlockResult.wrongPin => _wrongPinMessage(),
        AppUnlockResult.signOutFailed =>
          'Too many wrong PINs. Connect to the internet and tap '
              '"Sign in with password".',
        _ => null,
      };
    });
  }

  String _wrongPinMessage() {
    final left = ref.read(appLockProvider).attemptsLeft;
    return left == 1
        ? 'Wrong PIN. 1 try left before you are signed out.'
        : 'Wrong PIN. $left tries left.';
  }

  Future<void> _usePassword() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref.read(appLockProvider.notifier).signOut();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result == AppUnlockResult.signOutFailed) {
        _error = 'Could not sign out. Check your connection and try again.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exhausted = ref.watch(appLockProvider).attemptsLeft == 0;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Enter your PIN',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('app-lock-pin'),
                      controller: _pin,
                      autofocus: true,
                      enabled: !_busy && !exhausted,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                      decoration: const InputDecoration(labelText: 'PIN'),
                      onSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy || exhausted ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Unlock'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _usePassword,
                      child: const Text('Forgot PIN? Sign in with password'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
