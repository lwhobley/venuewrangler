import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../domain/data_catalogue.dart';

/// Rows returned by one catalogue metric: aggregates only (see
/// supabase/migrations/20261024120002_ask_data_metrics.sql).
class MetricResult {
  const MetricResult(this.rows);

  final List<Map<String, Object?>> rows;

  /// Column names in the order the metric returned them.
  List<String> get columns =>
      rows.isEmpty ? const [] : rows.first.keys.toList();
}

/// Runs validated catalogue calls as the signed-in user. Each `ask_data_*` function checks that
/// the caller manages the venue, so this never widens what someone may see.
abstract interface class AskDataRepository {
  Future<MetricResult> run({
    required String venueId,
    required ValidatedDataCall call,
  });
}

class SupabaseAskDataRepository implements AskDataRepository {
  const SupabaseAskDataRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<MetricResult> run({
    required String venueId,
    required ValidatedDataCall call,
  }) async {
    try {
      final result = await _client.rpc<dynamic>(
        call.metric.rpcName,
        params: call.rpcParams(venueId),
      );
      final rows = result is List
          ? result
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (r) => <String, Object?>{
                  for (final e in r.entries) '${e.key}': e.value,
                },
              )
              .take(kMaxDataRows)
              .toList(growable: false)
          : const <Map<String, Object?>>[];
      return MetricResult(rows);
    } on PostgrestException catch (e) {
      throw _map(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  AppError _map(PostgrestException e) {
    if (e.code == '42501') {
      return const PermissionDeniedError(
        'Only managers of this venue can ask about its data.',
      );
    }
    if (e.code == '22023') {
      return const UnknownError('That date range or option is not supported.');
    }
    return const UnknownError('Could not look that up right now.');
  }
}
