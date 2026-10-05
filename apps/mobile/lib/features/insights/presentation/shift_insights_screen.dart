import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_error.dart';
import '../../venues/application/venues_providers.dart';
import '../application/insights_providers.dart';
import '../domain/shift_insight.dart';

class ShiftInsightsScreen extends ConsumerWidget {
  const ShiftInsightsScreen({super.key, this.shiftId});

  final String? shiftId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(
        body: Center(
          child: Text('No venue selected.'),
        ),
      );
    }

    final insightsAsync = shiftId != null
        ? ref.watch(
            shiftInsightsForShiftProvider(
              (venueId: venue.id, shiftId: shiftId!),
            ),
          )
        : ref.watch(shiftInsightsForVenueProvider(venue.id));

    return Scaffold(
      appBar: AppBar(
        title: Text('Shift Insights — ${venue.name}'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (shiftId != null) {
            ref.invalidate(
              shiftInsightsForShiftProvider(
                (venueId: venue.id, shiftId: shiftId!),
              ),
            );
          } else {
            ref.invalidate(shiftInsightsForVenueProvider(venue.id));
          }
        },
        child: insightsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(),
          ),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load shift insights.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    if (shiftId != null) {
                      ref.invalidate(
                        shiftInsightsForShiftProvider(
                          (venueId: venue.id, shiftId: shiftId!),
                        ),
                      );
                    } else {
                      ref.invalidate(shiftInsightsForVenueProvider(venue.id));
                    }
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (insights) {
            if (insights.isEmpty) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.auto_awesome,
                              size: 48,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'No shift insights yet.',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Tap the button below to generate AI operational insights for your shift roster.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: insights.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final insight = insights[index];
                return _ShiftInsightCard(
                  insight: insight,
                  venueId: venue.id,
                  shiftId: shiftId,
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showGenerateDialog(context, ref, venue.id, shiftId),
        icon: const Icon(Icons.auto_awesome),
        label: const Text('Generate AI Insights'),
      ),
    );
  }

  void _showGenerateDialog(
    BuildContext context,
    WidgetRef ref,
    String venueId,
    String? shiftId,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => _GenerateInsightsDialog(
        venueId: venueId,
        shiftId: shiftId,
      ),
    );
  }
}

class _ShiftInsightCard extends ConsumerWidget {
  const _ShiftInsightCard({
    required this.insight,
    required this.venueId,
    this.shiftId,
  });

  final ShiftInsight insight;
  final String venueId;
  final String? shiftId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final (icon, color) = _kindMeta(insight.kind);

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withAlpha(50)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: color.withAlpha(30),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        insight.kind.displayLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                      Text(
                        insight.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Delete Insight',
                  onPressed: () => _confirmDelete(context, ref),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              insight.body,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _formatTimestamp(insight.createdAt),
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  (IconData, Color) _kindMeta(ShiftInsightKind kind) => switch (kind) {
        ShiftInsightKind.rushPrep => (
            Icons.local_fire_department,
            Colors.amber.shade800
          ),
        ShiftInsightKind.coverageWarning => (
            Icons.warning_amber_rounded,
            Colors.red.shade700
          ),
        ShiftInsightKind.laborEfficiency => (
            Icons.trending_up,
            Colors.green.shade700
          ),
        ShiftInsightKind.fatigueRisk => (Icons.bedtime, Colors.deepOrange),
        ShiftInsightKind.stationBalance => (Icons.balance, Colors.teal),
        ShiftInsightKind.complianceNote => (Icons.gavel, Colors.purple),
        ShiftInsightKind.shiftSummary => (Icons.insights, Colors.blue),
      };

  String _formatTimestamp(DateTime dt) {
    final local = dt.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} $hour:$minute';
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Insight?'),
        content:
            const Text('Are you sure you want to remove this shift insight?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref
          .read(insightsRepositoryProvider)
          .deleteInsight(insightId: insight.id);
      if (shiftId != null) {
        ref.invalidate(
          shiftInsightsForShiftProvider((venueId: venueId, shiftId: shiftId!)),
        );
      } else {
        ref.invalidate(shiftInsightsForVenueProvider(venueId));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete insight: $e')),
        );
      }
    }
  }
}

class _GenerateInsightsDialog extends ConsumerStatefulWidget {
  const _GenerateInsightsDialog({
    required this.venueId,
    this.shiftId,
  });

  final String venueId;
  final String? shiftId;

  @override
  ConsumerState<_GenerateInsightsDialog> createState() =>
      _GenerateInsightsDialogState();
}

class _GenerateInsightsDialogState
    extends ConsumerState<_GenerateInsightsDialog> {
  final _contextController = TextEditingController();
  bool _isGenerating = false;
  String? _errorMessage;

  @override
  void dispose() {
    _contextController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final text = _contextController.text.trim();
    if (text.isEmpty) {
      setState(
        () => _errorMessage = 'Please provide shift or operational context.',
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(insightsRepositoryProvider);
      await repo.generateAndSaveShiftInsights(
        venueId: widget.venueId,
        shiftId: widget.shiftId,
        shiftContext: text,
      );

      if (widget.shiftId != null) {
        ref.invalidate(
          shiftInsightsForShiftProvider(
            (venueId: widget.venueId, shiftId: widget.shiftId!),
          ),
        );
      } else {
        ref.invalidate(shiftInsightsForVenueProvider(widget.venueId));
      }

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Shift insights generated successfully.'),
          ),
        );
      }
    } on AppError catch (e) {
      setState(() {
        _errorMessage = e.message;
        _isGenerating = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Could not generate shift insights: $e';
        _isGenerating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.auto_awesome, color: Colors.blue),
          SizedBox(width: 8),
          Text('Generate Shift Insights'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the shift schedule, roster notes, or operational parameters (e.g. expected covers, station assignments, peak hours):',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contextController,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText:
                    'e.g. Friday evening shift 5pm-11pm. 5 floor servers, 2 bartenders, 1 host. Projected 190 covers between 6:30pm and 8:30pm.',
                border: OutlineInputBorder(),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isGenerating ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isGenerating ? null : _generate,
          child: _isGenerating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Generate'),
        ),
      ],
    );
  }
}
