/// Error categories every feature screen's loading/empty/error/retry/permission-denied state
/// switches on, per the migration plan's accessibility requirement. Kept intentionally small
/// in Phase 1; features add their own domain errors as they're built in Phase 2, but every
/// one of them should ultimately map to one of these for the shared error-state widgets.
sealed class AppError {
  const AppError(this.message);

  final String message;
}

final class NetworkError extends AppError {
  const NetworkError([super.message = 'Could not reach the server. Check your connection.']);
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

final class UnknownError extends AppError {
  const UnknownError(super.message);
}
