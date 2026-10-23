import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/time_entry.dart';

class TimeReviewRepository {
  const TimeReviewRepository(this.client);
  final SupabaseClient client;

  Future<List<TimeEntry>> entries(
    String venueId,
    DateTime from,
    DateTime to,
  ) async {
    final entries = <TimeEntry>[];
    for (var offset = 0;; offset += 500) {
      final rows = await client
          .from('time_entries')
          .select()
          .eq('venue_id', venueId)
          .gte('clock_in_at', from.toUtc().toIso8601String())
          .lt('clock_in_at', to.toUtc().toIso8601String())
          .order('clock_in_at')
          .order('id')
          .range(offset, offset + 499);
      entries.addAll(rows.map(TimeEntry.fromJson));
      if (rows.length < 500) return entries;
    }
  }

  Future<void> correct(String id, DateTime out, String reason) async {
    await client.rpc(
      'correct_time_entry',
      params: {
        'p_entry_id': id,
        'p_clock_out_at': out.toUtc().toIso8601String(),
        'p_reason': reason,
      },
    );
  }
}

String hoursCsv(
  List<TimeEntry> entries,
  Map<String, String> names,
  String Function(DateTime) format,
) {
  String cell(String value) {
    final safe = RegExp(r'^[=+@\-\t\r]').hasMatch(value) ? "'$value" : value;
    return '"${safe.replaceAll('"', '""')}"';
  }

  return [
    'Name,User ID,Clock in,Clock out,Worked hours,Status',
    for (final e in entries)
      [
        names[e.userId] ?? 'Team member',
        e.userId,
        format(e.clockInAt),
        e.clockOutAt == null ? '' : format(e.clockOutAt!),
        (e.workedDuration.inMinutes / 60).toStringAsFixed(2),
        e.isOpen ? 'Open - provisional' : 'Closed',
      ].map(cell).join(','),
  ].join('\r\n');
}
