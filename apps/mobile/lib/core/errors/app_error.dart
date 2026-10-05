/// Error categories every feature screen's loading/empty/error/retry/permission-denied state
/// switches on, per the migration plan's accessibility requirement. Kept intentionally small
/// in Phase 1; features add their own domain errors as they're built in Phase 2, but every
/// one of them should ultimately map to one of these for the shared error-state widgets.
sealed class AppError {
  const AppError(this.message);

  final String message;
}

final class NetworkError extends AppError {
  const NetworkError([
    super.message = 'Could not reach the server. Check your connection.',
  ]);
}

final class AuthError extends AppError {
  const AuthError(super.message);
}

final class PermissionDeniedError extends AppError {
  const PermissionDeniedError([
    super.message = 'You do not have access to do this.',
  ]);
}

final class NotFoundError extends AppError {
  const NotFoundError([super.message = 'That item could not be found.']);
}

/// The `ai-assistant` Edge Function declined the request for a reason the user can
/// understand and act on (monthly AI budget exhausted, too many requests in a short window) —
/// distinct from [UnknownError] so screens can show this verbatim instead of a generic
/// "something went wrong", and distinct from [PermissionDeniedError] since it's not an
/// authorization failure. Every AI feature must still have a manual, non-AI fallback per
/// features/ai/README.md, so this is always recoverable by the user doing the task by hand.
final class AiUnavailableError extends AppError {
  const AiUnavailableError(super.message);
}

final class UnknownError extends AppError {
  const UnknownError(super.message);
}
