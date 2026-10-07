/// Matches `public.create_workspace`, which rejects an organization/venue name longer than this
/// (and one that's blank once trimmed). Validating the same limit client-side means a long name
/// is caught while the form is still on screen, not after sign-up when there is nowhere to fix it.
const kWorkspaceNameMaxLength = 120;

/// Form validator for a workspace/venue name; null when valid.
String? workspaceNameProblem(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return 'Enter your venue name';
  if (trimmed.length > kWorkspaceNameMaxLength) {
    return 'Use $kWorkspaceNameMaxLength characters or fewer';
  }
  return null;
}
