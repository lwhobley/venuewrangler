import '../../../core/widgets/home_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../../venues/application/venues_providers.dart';
import '../application/floor_providers.dart';
import '../domain/floor_table.dart';
import '../domain/table_status_style.dart';

class FloorPlanScreen extends ConsumerStatefulWidget {
  const FloorPlanScreen({super.key});

  @override
  ConsumerState<FloorPlanScreen> createState() => _FloorPlanScreenState();
}

class _FloorPlanScreenState extends ConsumerState<FloorPlanScreen> {
  final Set<String> _selectedTableIds = {};

  @override
  Widget build(BuildContext context) {
    final activeVenue = ref.watch(activeVenueProvider);
    final tablesStreamAsync = ref.watch(floorTablesStreamProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const HomeButton(),
        title: const Text('Floor Plan'),
        actions: [
          if (ref.watch(canManageActiveVenueProvider).valueOrNull ?? false)
            IconButton(
              icon: const Icon(Icons.edit_location_alt_outlined),
              tooltip: 'Edit layout',
              onPressed: () => context.push('/floor/edit'),
            ),
          if (_selectedTableIds.length >= 2 && activeVenue != null)
            IconButton(
              icon: const Icon(Icons.merge_type),
              tooltip: 'Merge Selected Tables',
              onPressed: () async {
                final tableIds = _selectedTableIds.toList();
                await ref.read(floorRepositoryProvider).mergeTables(
                      venueId: activeVenue.id,
                      tableIds: tableIds,
                    );
                setState(() => _selectedTableIds.clear());
              },
            ),
          if (_selectedTableIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Clear Selection',
              onPressed: () => setState(() => _selectedTableIds.clear()),
            ),
        ],
      ),
      body: tablesStreamAsync.when(
        data: (tables) {
          if (tables.isEmpty) {
            return const EmptyState(
              icon: Icons.table_restaurant,
              message: 'No tables found for this venue',
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.0,
            ),
            itemCount: tables.length,
            itemBuilder: (context, index) {
              final table = tables[index];
              final isSelected = _selectedTableIds.contains(table.id);

              return _TableGridTile(
                table: table,
                isSelected: isSelected,
                onTap: () {
                  if (_selectedTableIds.isNotEmpty) {
                    setState(() {
                      if (isSelected) {
                        _selectedTableIds.remove(table.id);
                      } else {
                        _selectedTableIds.add(table.id);
                      }
                    });
                  } else {
                    _showTableActionSheet(context, table);
                  }
                },
                onLongPress: () {
                  setState(() {
                    if (isSelected) {
                      _selectedTableIds.remove(table.id);
                    } else {
                      _selectedTableIds.add(table.id);
                    }
                  });
                },
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) =>
            ErrorState(message: 'Failed to load floor tables: $err'),
      ),
    );
  }

  void _showTableActionSheet(BuildContext context, FloorTable table) {
    final activeVenue = ref.read(activeVenueProvider);
    if (activeVenue == null) return;

    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Table ${table.label}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                'Status: ${table.status.toUpperCase()} | Capacity: ${table.capacity}p',
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.check_circle_outline,
                color: sheetCtx.ops.success.fg,
              ),
              title: const Text('Mark Available'),
              onTap: () async {
                Navigator.of(sheetCtx).pop();
                await ref.read(floorRepositoryProvider).updateTableStatus(
                      venueId: activeVenue.id,
                      tableId: table.id,
                      status: 'available',
                    );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.event_seat_outlined,
                color: sheetCtx.ops.info.fg,
              ),
              title: const Text('Mark Seated'),
              onTap: () async {
                Navigator.of(sheetCtx).pop();
                await ref.read(floorRepositoryProvider).updateTableStatus(
                      venueId: activeVenue.id,
                      tableId: table.id,
                      status: 'seated',
                    );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.cleaning_services_outlined,
                color: sheetCtx.ops.warning.fg,
              ),
              title: const Text('Mark Dirty (Needs Bussing)'),
              onTap: () async {
                Navigator.of(sheetCtx).pop();
                await ref.read(floorRepositoryProvider).updateTableStatus(
                      venueId: activeVenue.id,
                      tableId: table.id,
                      status: 'dirty',
                    );
              },
            ),
            if (table.isMerged)
              ListTile(
                leading: Icon(Icons.call_split, color: sheetCtx.ops.vip.fg),
                title: const Text('Split Merged Tables'),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  await ref.read(floorRepositoryProvider).splitTables(
                        venueId: activeVenue.id,
                        mergeGroupId: table.mergeGroupId!,
                      );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _TableGridTile extends StatelessWidget {
  const _TableGridTile({
    required this.table,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
  });

  final FloorTable table;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final statusTone = context.ops.of(TableStatusStyle.of(table.status).tone);
    final statusColor = statusTone.fg;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: statusTone.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : statusColor,
            width: isSelected ? 3.0 : 1.5,
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    table.label,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${table.capacity} seats',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        TableStatusStyle.of(table.status).icon,
                        size: 12,
                        color: statusColor,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        table.status.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (table.isMerged)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(Icons.link, size: 16, color: statusColor),
              ),
            if (isSelected)
              Positioned(
                top: 4,
                left: 4,
                child: Icon(
                  Icons.check_circle,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
