import 'package:supabase_flutter/supabase_flutter.dart';

/// Called when an `update`/`delete` ... `.select('id').maybeSingle()` came back empty. An empty
/// result alone does not say why: RLS can refuse the write while the row exists (a real denial,
/// code 42501), or the row may no longer exist at all (deleted by someone else). Re-check by id
/// without the write's filters to tell them apart, and throw the matching error.
///
/// [rowExists] is the re-check (see [rowExistsById]). Always throws.
Future<Never> throwForUnappliedUpdate({
  required Future<bool> Function() rowExists,
  required String denialMessage,
}) async {
  if (!await rowExists()) {
    throw const PostgrestException(
      message: 'This record no longer exists.',
      code: 'PGRST116',
    );
  }
  throw PostgrestException(message: denialMessage, code: '42501');
}

/// Whether [table] still has a row with [id], selected without any write filters.
Future<bool> rowExistsById(
  SupabaseClient client,
  String table,
  String id,
) async {
  final row = await client.from(table).select('id').eq('id', id).maybeSingle();
  return row != null;
}
