import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/sign_out_service.dart';
import '../../../core/widgets/state_views.dart';
import '../../auth/sign_up_screen.dart';
import '../application/invites_providers.dart';

/// `/join?invite=…&email=…`: where an invitation email's link lands (see
/// supabase/functions/invite-send-email), and the "Join your team" entry on the sign-in screen.
///
/// Signed out, it is the joining variant of the sign-up form, with a way to sign in instead.
/// Signed in, it accepts the linked invitation and lands in its venue.
class JoinTeamRoute extends ConsumerWidget {
  const JoinTeamRoute({super.key, this.inviteId, this.email});

  final String? inviteId;
  final String? email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(isSignedInProvider)) {
      return SignUpScreen(
        joining: true,
        inviteId: inviteId,
        initialEmail: email,
      );
    }
    return _JoinWhileSignedIn(inviteId: inviteId, email: email);
  }
}

class _JoinWhileSignedIn extends ConsumerStatefulWidget {
  const _JoinWhileSignedIn({this.inviteId, this.email});

  final String? inviteId;
  final String? email;

  @override
  ConsumerState<_JoinWhileSignedIn> createState() => _JoinWhileSignedInState();
}

class _JoinWhileSignedInState extends ConsumerState<_JoinWhileSignedIn> {
  String? get _signedInEmail =>
      ref.read(authRepositoryProvider).currentSession?.user.email;

  /// The link was for a different address than the one signed in: accepting is impossible
  /// (the server matches the verified email), so say so instead of trying.
  bool get _wrongAccount {
    final invited = widget.email?.trim().toLowerCase();
    final current = _signedInEmail?.trim().toLowerCase();
    return invited != null &&
        invited.isNotEmpty &&
        current != null &&
        invited != current;
  }

  @override
  void initState() {
    super.initState();
    if (!_wrongAccount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _join());
    }
  }

  Future<void> _join() async {
    final venue = await ref
        .read(inviteRedemptionProvider.notifier)
        .redeem(inviteId: widget.inviteId);
    if (!mounted) return;
    if (venue != null) {
      context.go('/');
    } else if (ref.read(inviteRedemptionProvider).problem == null) {
      // Several invitations: let the person choose, the linked one first.
      context.go(
        Uri(
          path: '/invites',
          queryParameters: {
            if (widget.inviteId != null) 'invite': widget.inviteId!,
          },
        ).toString(),
      );
    }
  }

  void _continue() {
    ref.read(inviteRedemptionProvider.notifier).clearProblem();
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final redemption = ref.watch(inviteRedemptionProvider);
    final Widget body;
    if (_wrongAccount) {
      body = EmptyState(
        icon: Icons.alternate_email,
        message: 'This invitation was sent to ${widget.email}, but you are '
            'signed in as $_signedInEmail. Sign out, then sign in or create '
            'an account with ${widget.email}.',
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: () => signOutAndClearScopedData(
                ProviderScope.containerOf(context, listen: false),
              ),
              child: const Text('Sign out'),
            ),
            TextButton(onPressed: _continue, child: const Text('Not now')),
          ],
        ),
      );
    } else if (redemption.problem != null) {
      body = EmptyState(
        icon: Icons.mark_email_unread_outlined,
        message: redemption.problem!,
        action: OutlinedButton(
          onPressed: _continue,
          child: const Text('Continue'),
        ),
      );
    } else {
      body = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Joining your team…'),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Join your team'),
      ),
      body: body,
    );
  }
}
