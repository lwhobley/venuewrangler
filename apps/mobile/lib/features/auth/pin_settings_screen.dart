import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/app_lock.dart';
import '../../core/auth/auth_providers.dart';

/// `/pin`: set, change or remove the app PIN on this device (see core/auth/app_lock.dart).
class PinSettingsScreen extends ConsumerStatefulWidget {
  const PinSettingsScreen({super.key});

  @override
  ConsumerState<PinSettingsScreen> createState() => _PinSettingsScreenState();
}

class _PinSettingsScreenState extends ConsumerState<PinSettingsScreen> {
  final _current = TextEditingController();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _clearFields() {
    _current.clear();
    _pin.clear();
    _confirm.clear();
  }

  Future<bool> _checkCurrent() async {
    final ok =
        await ref.read(appLockProvider.notifier).verify(_current.text.trim());
    if (!ok && mounted) setState(() => _error = 'Current PIN is wrong.');
    return ok;
  }

  Future<void> _save({required bool replacing}) async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    final pin = _pin.text.trim();
    final problem = appPinProblem(pin);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error = "The PINs don't match.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (replacing && !await _checkCurrent()) return;
      await ref.read(appLockProvider.notifier).setPin(userId: userId, pin: pin);
      if (!mounted) return;
      _clearFields();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(replacing ? 'PIN changed.' : 'PIN set.')),
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save the PIN.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await _checkCurrent()) return;
      await ref.read(appLockProvider.notifier).removePin();
      if (!mounted) return;
      _clearFields();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN removed.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pinField(TextEditingController controller, String label, Key key) =>
      TextField(
        key: key,
        controller: controller,
        enabled: !_busy,
        obscureText: true,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        decoration: InputDecoration(labelText: label),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPin = ref.watch(appLockProvider.select((s) => s.hasPin));
    return Scaffold(
      appBar: AppBar(title: const Text('App PIN')),
      body: !appLockSupported
          ? const Center(
              child: Text('App PIN is only available in the mobile app.'),
            )
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  hasPin
                      ? 'Your PIN unlocks the app on this phone after it has been away '
                          'for ${kAppLockTimeout.inMinutes} minutes or restarted.'
                      : 'Set a 4–6 digit PIN to unlock the app on this phone instead of '
                          'staying open. It is only stored on this device; signing out removes it.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                if (hasPin) ...[
                  _pinField(_current, 'Current PIN', const Key('pin-current')),
                  const SizedBox(height: 12),
                ],
                _pinField(
                  _pin,
                  hasPin ? 'New PIN' : 'PIN',
                  const Key('pin-new'),
                ),
                const SizedBox(height: 12),
                _pinField(_confirm, 'Confirm PIN', const Key('pin-confirm')),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : () => _save(replacing: hasPin),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(hasPin ? 'Change PIN' : 'Set PIN'),
                ),
                if (hasPin) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : _remove,
                    child: const Text('Remove PIN (enter current PIN above)'),
                  ),
                ],
              ],
            ),
    );
  }
}
