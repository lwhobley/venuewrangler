import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/transport_failure.dart';

/// A team-management failure with a message that is safe to show as-is.
class TeamException implements Exception {
  const TeamException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Maps the errors raised by the team RPCs (`remove_member`, `change_member_role`,
/// `transfer_ownership`, `team_members`) to friendly messages: `42501` forbidden and the
/// `P0001` codes `last_owner`, `cannot_modify_self`, `role_not_allowed`.
TeamException teamExceptionFrom(Object error) {
  if (error is TeamException) return error;
  if (error is PostgrestException) {
    final text = '${error.message} ${error.details} ${error.hint}';
    if (text.contains('last_owner')) {
      return const TeamException(
        'An organization needs at least one owner. Make someone else an owner '
        'first.',
      );
    }
    if (text.contains('mfa_required')) {
      return const TeamException(
        'Turn on two-factor authentication (Settings) and sign in with your '
        'code before changing access.',
      );
    }
    if (text.contains('target_not_a_member')) {
      return const TeamException(
        'Ownership can only go to someone who is already a member of this '
        'organization.',
      );
    }
    if (text.contains('cannot_modify_self')) {
      return const TeamException(
        "You can't change your own membership here. To leave, delete your "
        'account from Settings.',
      );
    }
    if (text.contains('role_not_allowed')) {
      return const TeamException("That role isn't allowed for this member.");
    }
    if (error.code == '42501' || text.contains('forbidden')) {
      return const TeamException("You don't have permission to do that.");
    }
    if (error.code == 'P0002' || text.contains('not_found')) {
      return const TeamException(
        'That member no longer exists. Pull to refresh the list.',
      );
    }
  }
  if (isTransportFailure(error)) {
    return const TeamException(
      'Could not reach the server. Check your connection.',
    );
  }
  return const TeamException('Something went wrong. Please try again.');
}
