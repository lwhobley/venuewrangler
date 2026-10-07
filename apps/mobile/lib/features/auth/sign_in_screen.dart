import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_providers.dart';
import '../../core/errors/app_error.dart';
import '../../core/theme/app_colors.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isSubmitting = false;
  AppError? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).signInWithPassword(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
      // On success, go_router's redirect (app/router.dart) takes over once
      // isSignedInProvider flips to true via the auth-state-change stream.
    } catch (error) {
      setState(() => _error = AuthError(error.toString()));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _forgotPassword() async {
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) => _ForgotPasswordDialog(
        initialEmail: _emailController.text.trim(),
      ),
    );
    if (sent == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'If that email has an account, a reset link is on its way.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _GlassBackdrop(isDark: isDark),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _BrandMark(),
                      const SizedBox(height: 28),
                      _GlassCard(
                        isDark: isDark,
                        child: Form(
                          key: _formKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Welcome back',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 20),
                              TextFormField(
                                controller: _emailController,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                decoration: const InputDecoration(
                                  labelText: 'Email',
                                  prefixIcon: Icon(Icons.mail_outline),
                                ),
                                validator: (value) =>
                                    (value == null || !value.contains('@'))
                                        ? 'Enter a valid email'
                                        : null,
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _passwordController,
                                obscureText: true,
                                autofillHints: const [AutofillHints.password],
                                decoration: const InputDecoration(
                                  labelText: 'Password',
                                  prefixIcon: Icon(Icons.lock_outline),
                                ),
                                validator: (value) =>
                                    (value == null || value.isEmpty)
                                        ? 'Enter your password'
                                        : null,
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed:
                                      _isSubmitting ? null : _forgotPassword,
                                  child: const Text('Forgot password?'),
                                ),
                              ),
                              if (_error != null) ...[
                                Text(
                                  _error!.message,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                              FilledButton(
                                onPressed: _isSubmitting ? null : _submit,
                                child: _isSubmitting
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text('Sign in'),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: _isSubmitting
                                    ? null
                                    : () => context.go('/sign-up'),
                                child: const Text(
                                  'New here? Launch your workspace',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ForgotPasswordDialog extends ConsumerStatefulWidget {
  const _ForgotPasswordDialog({required this.initialEmail});

  final String initialEmail;

  @override
  ConsumerState<_ForgotPasswordDialog> createState() =>
      _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends ConsumerState<_ForgotPasswordDialog> {
  late final _controller = TextEditingController(text: widget.initialEmail);
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _controller.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter a valid email');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).sendPasswordResetEmail(email);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = AuthError(error.toString()).message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reset password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Enter your email and we'll send you a reset link."),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.emailAddress,
            autofocus: true,
            decoration: InputDecoration(labelText: 'Email', errorText: _error),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: const Text('Send link'),
        ),
      ],
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.primary,
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: 0.45),
                blurRadius: 32,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(
            Icons.grid_view_rounded,
            size: 40,
            color: theme.colorScheme.onPrimary,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Venue Wrangler',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          'Run the whole floor from one place',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Frosted panel: blurs the gradient orbs behind it and adds a translucent fill + hairline edge.
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, required this.isDark});

  final Widget child;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fill = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.62);
    final edge = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.85);
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: edge),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Soft coral/cobalt orbs on the workspace colour — gives the glass something to blur.
class _GlassBackdrop extends StatelessWidget {
  const _GlassBackdrop({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surface;
    Widget orb(Color color, double size) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: isDark ? 0.55 : 0.45),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        );
    return DecoratedBox(
      decoration: BoxDecoration(color: base),
      child: Stack(
        children: [
          Positioned(top: -90, left: -80, child: orb(AppColors.coral, 340)),
          Positioned(
            bottom: -110,
            right: -90,
            child: orb(AppColors.cobalt, 380),
          ),
          Positioned(
            top: 280,
            right: -60,
            child: orb(AppColors.purpleOnDark, 220),
          ),
        ],
      ),
    );
  }
}
