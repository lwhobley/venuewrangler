import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_providers.dart';
import '../../../core/offline/pending_mutation.dart';
import '../data/incidents_repository.dart';
import '../domain/incident.dart';

final incidentsRepositoryProvider = Provider<IncidentsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseIncidentsRepository(client);
});

final incidentsForVenueProvider =
    FutureProvider.autoDispose.family<List<Incident>, String>((ref, venueId) {
  return ref.watch(incidentsRepositoryProvider).fetchIncidentsForVenue(venueId);
});

/// Mutation kind for an incident report drafted while offline. Payload: `incidentId`
/// (client-generated, for idempotent retries), `venueId`, `title`, `description`, `severity`
/// (IncidentSeverity.toDb() string). Like checklist completions, this is an insert with
/// nothing to conflict with, so the handler just retries until it succeeds.
const String kIncidentReportMutationKind = 'incident_report';

PendingMutation buildIncidentReportMutation({
  required String incidentId,
  required String venueId,
  required String title,
  String? description,
  required IncidentSeverity severity,
  String? userId,
}) {
  return PendingMutation(
    id: incidentId,
    kind: kIncidentReportMutationKind,
    createdAt: DateTime.now(),
    userId: userId,
    payload: {
      'incidentId': incidentId,
      'venueId': venueId,
      'title': title,
      if (description != null) 'description': description,
      'severity': severity.toDb(),
    },
  );
}

final incidentMutationHandlersProvider =
    Provider<Map<String, MutationHandler>>((ref) {
  final repo = ref.watch(incidentsRepositoryProvider);

  Future<MutationResult> handleReport(Map<String, dynamic> payload) async {
    try {
      await repo.reportIncident(
        incidentId: payload['incidentId'] as String,
        venueId: payload['venueId'] as String,
        title: payload['title'] as String,
        description: payload['description'] as String?,
        severity: IncidentSeverity.fromDb(payload['severity'] as String),
      );
      return const MutationResult(MutationOutcome.applied);
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        return const MutationResult(
          MutationOutcome.conflict,
          message:
              'You no longer have permission to report incidents for this venue.',
        );
      }
      rethrow; // network/5xx-shaped failures are retried by the queue controller.
    }
  }

  return {kIncidentReportMutationKind: handleReport};
});
