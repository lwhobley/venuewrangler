import '../../../core/widgets/home_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../venues/application/venues_providers.dart';
import '../application/checklists_providers.dart';

class ChecklistListScreen extends ConsumerWidget {
  const ChecklistListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final templatesAsync =
        ref.watch(checklistTemplatesForVenueProvider(venue.id));

    return Scaffold(
      appBar: AppBar(
        leading: const HomeButton(),
        title: Text('Checklists — ${venue.name}'),
      ),
      body: templatesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Could not load checklists.'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref
                    .invalidate(checklistTemplatesForVenueProvider(venue.id)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (templates) {
          if (templates.isEmpty) {
            return const Center(
              child: Text('No checklists set up for this venue yet.'),
            );
          }
          return ListView.builder(
            itemCount: templates.length,
            itemBuilder: (context, index) {
              final template = templates[index];
              return ListTile(
                leading: const Icon(Icons.checklist_outlined),
                title: Text(template.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(
                  '/checklists/${template.id}',
                  extra: template.title,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
