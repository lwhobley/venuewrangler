import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/auth_providers.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/errors/app_error.dart';
import '../../core/theme/app_radii.dart';
import '../../core/theme/ops_colors.dart';
import '../invites/application/invites_providers.dart';
import '../organizations/domain/workspace_name.dart';
import '../organizations/domain/workspace_timezones.dart';
import 'legal_acceptance_field.dart';

/// "Launch Workspace" — the marketing site's entry point for a brand-new customer starting
/// their own organization from scratch (as opposed to SignInScreen, for someone already
/// invited into an existing one). Submitting calls [AuthRepository.signUpWithPassword] with
/// the chosen workspace name stashed as pending user metadata; the actual organization/venue
/// creation happens in `pendingWorkspaceCreationTriggerProvider`
/// (features/organizations/application/workspace_provisioning.dart) once a session exists —
/// immediately here if this project doesn't require email confirmation, or later (possibly a
/// different app launch) once the user confirms their email and signs in.
///
/// With [joining] it is "Join your team" instead (launch review A1: invited staff had only the
/// workspace form): no venue fields, and the account is marked as joining (plus the
/// invitation link's [inviteId]) so the invitation is accepted as soon as a verified session
/// exists, see inviteRedemptionTriggerProvider.
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({
    super.key,
    this.joining = false,
    this.inviteId,
    this.initialEmail,
  });

  final bool joining;
  final String? inviteId;
  final String? initialEmail;

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _workspaceController = TextEditingController();
  late final _emailController =
      TextEditingController(text: widget.initialEmail);
  final _passwordController = TextEditingController();

  bool _isSubmitting = false;
  bool _checkYourEmail = false;
  AppError? _error;

  /// Pre-selected from the device when it can be told apart, otherwise the person picks.
  /// Becomes the venue's `timezone`, which the time clock reads server-side.
  String? _timezone = guessWorkspaceTimezone();

  @override
  void dispose() {
    _workspaceController.dispose();
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

    if (widget.inviteId != null) {
      ref.read(pendingInviteLinkProvider.notifier).state = widget.inviteId;
    }
    try {
      final hasSession =
          await ref.read(authRepositoryProvider).signUpWithPassword(
                email: _emailController.text.trim(),
                password: _passwordController.text,
                data: widget.joining
                    ? {
                        kJoiningTeamMetadataKey: true,
                        if (widget.inviteId != null)
                          kPendingInviteMetadataKey: widget.inviteId,
                      }
                    : {
                        'pending_workspace_name':
                            _workspaceController.text.trim(),
                        'pending_timezone': _timezone,
                      },
              );
      if (!mounted) return;
      if (hasSession) {
        // isSignedInProvider flips true and go_router's redirect (app/router.dart) takes the
        // app from here — pendingWorkspaceCreationTriggerProvider finishes the workspace
        // creation this same tick, before the switcher screen would otherwise show.
      } else {
        setState(() => _checkYourEmail = true);
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = AuthError(error.message));
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = const AuthError(
            'Could not create the account. Please try again.',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  String _withInvite(String path) => Uri(
        path: path,
        queryParameters: {
          if (widget.inviteId != null) 'invite': widget.inviteId!,
          if (_emailController.text.trim().isNotEmpty)
            'email': _emailController.text.trim(),
        },
      ).toString();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final joining = widget.joining;

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
                        child: _checkYourEmail
                            ? _CheckYourEmailPanel(
                                email: _emailController.text.trim(),
                                joining: joining,
                                signInLocation: _withInvite('/sign-in'),
                              )
                            : Form(
                                key: _formKey,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      joining
                                          ? 'Join your team'
                                          : 'Launch your workspace',
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.headlineSmall,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      joining
                                          ? 'Use the email address your manager invited. '
                                              'Once you confirm it, you go straight to your venue.'
                                          : 'Bring your team, your floor, and your next big night together.',
                                      textAlign: TextAlign.center,
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    if (!joining) ...[
                                      TextFormField(
                                        controller: _workspaceController,
                                        textCapitalization:
                                            TextCapitalization.words,
                                        autofillHints: const [
                                          AutofillHints.organizationName,
                                        ],
                                        decoration: const InputDecoration(
                                          labelText: 'Venue name',
                                          hintText: 'The name above your door',
                                          prefixIcon:
                                              Icon(Icons.storefront_outlined),
                                        ),
                                        validator: workspaceNameProblem,
                                      ),
                                      const SizedBox(height: 12),
                                      DropdownButtonFormField<String>(
                                        initialValue: _timezone,
                                        isExpanded: true,
                                        decoration: const InputDecoration(
                                          labelText: 'Time zone',
                                          prefixIcon: Icon(Icons.schedule),
                                        ),
                                        items: [
                                          for (final zone
                                              in kWorkspaceTimezones)
                                            DropdownMenuItem(
                                              value: zone.id,
                                              child: Text(zone.label),
                                            ),
                                        ],
                                        onChanged: (value) =>
                                            setState(() => _timezone = value),
                                        validator: (value) => value == null
                                            ? 'Select your time zone'
                                            : null,
                                      ),
                                      const SizedBox(height: 12),
                                    ],
                                    TextFormField(
                                      controller: _emailController,
                                      keyboardType: TextInputType.emailAddress,
                                      autofillHints: const [
                                        AutofillHints.email,
                                      ],
                                      decoration: InputDecoration(
                                        labelText:
                                            joining ? 'Email' : 'Work email',
                                        prefixIcon:
                                            const Icon(Icons.mail_outline),
                                      ),
                                      validator: (value) => (value == null ||
                                              !value.contains('@'))
                                          ? 'Enter a valid email'
                                          : null,
                                    ),
                                    const SizedBox(height: 12),
                                    TextFormField(
                                      controller: _passwordController,
                                      obscureText: true,
                                      autofillHints: const [
                                        AutofillHints.newPassword,
                                      ],
                                      decoration: const InputDecoration(
                                        labelText: 'Password',
                                        prefixIcon: Icon(Icons.lock_outline),
                                      ),
                                      validator: (value) =>
                                          passwordPolicyProblem(value ?? ''),
                                    ),
                                    const SizedBox(height: 12),
                                    const LegalAcceptanceField(),
                                    const SizedBox(height: 4),
                                    const LocationPunchNotice(),
                                    if (_error != null) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        _error!.message,
                                        style: TextStyle(
                                          color: theme.colorScheme.error,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 20),
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
                                          : Text(
                                              joining
                                                  ? 'Create my account'
                                                  : "Let's get you in command",
                                            ),
                                    ),
                                    const SizedBox(height: 8),
                                    TextButton(
                                      onPressed: _isSubmitting
                                          ? null
                                          : () => context
                                              .go(_withInvite('/sign-in')),
                                      child: Text(
                                        joining
                                            ? 'Already have an account? Sign in'
                                            : 'Already have a workspace? Sign in',
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: _isSubmitting
                                          ? null
                                          : () => context.go(
                                                joining
                                                    ? '/sign-up'
                                                    : _withInvite('/join'),
                                              ),
                                      child: Text(
                                        joining
                                            ? 'Opening a new venue? Launch your workspace'
                                            : 'Invited by your manager? Join your team',
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

class _CheckYourEmailPanel extends StatelessWidget {
  const _CheckYourEmailPanel({
    required this.email,
    required this.joining,
    required this.signInLocation,
  });

  final String email;
  final bool joining;
  final String signInLocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.mark_email_read_outlined,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Text(
          'Check your email',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          joining
              ? 'We sent a confirmation link to $email. Open it, then come '
                  'back and sign in: you join your team the moment you do.'
              : 'We sent a confirmation link to $email. Open it, then come back '
                  'and sign in — your workspace is created the moment you do.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: () => context.go(signInLocation),
          child: const Text('Back to sign in'),
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
          style: theme.textTheme.headlineMedium,
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
/// Kept in sync with SignInScreen's private widget of the same name/shape (not shared) — see
/// that file if the glass styling changes.
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, required this.isDark});

  final Widget child;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fill = Theme.of(context)
        .colorScheme
        .surfaceContainerLow
        .withValues(alpha: isDark ? 0.6 : 0.72);
    final edge = context.ops.panelBorder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppRadii.card),
            border: Border.all(color: edge),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _GlassBackdrop extends StatelessWidget {
  const _GlassBackdrop({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surface;
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
          Positioned(top: -90, left: -80, child: orb(scheme.primary, 340)),
          Positioned(
            bottom: -110,
            right: -90,
            child: orb(scheme.secondary, 380),
          ),
          Positioned(
            top: 280,
            right: -60,
            child: orb(scheme.tertiary, 220),
          ),
        ],
      ),
    );
  }
}
