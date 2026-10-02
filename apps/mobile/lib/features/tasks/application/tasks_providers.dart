import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/tasks_repository.dart';
import '../domain/operational_task.dart';

final tasksRepositoryProvider = Provider<TasksRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseTasksRepository(client);
});

final tasksForVenueProvider =
    FutureProvider.autoDispose.family<List<OperationalTask>, String>((ref, venueId) {
  return ref.watch(tasksRepositoryProvider).fetchTasksForVenue(venueId);
});
