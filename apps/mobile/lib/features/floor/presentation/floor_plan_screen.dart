import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../venues/application/venues_providers.dart';
import '../application/floor_providers.dart';
import '../domain/floor_table.dart';

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
        title: const Text('Floor Plan'),
        actions: [
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
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.table_restaurant, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No tables found for this venue',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
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
        error: (err, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 8),
              Text('Failed to load floor tables: $err', textAlign: TextAlign.center),
            ],
          ),
        ),
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
              title: Text('Table ${table.label}', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Status: ${table.status.toUpperCase()} | Capacity: ${table.capacity}p'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
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
              leading: const Icon(Icons.airline_seat_recline_normal, color: Colors.blue),
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
              leading: const Icon(Icons.cleaning_services, color: Colors.orange),
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
                leading: const Icon(Icons.call_split, color: Colors.purple),
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

  Color _statusColor(String status) {
    switch (status) {
      case 'available':
        return Colors.green.shade600;
      case 'seated':
        return Colors.blue.shade600;
      case 'dirty':
        return Colors.amber.shade700;
      case 'reserved':
        return Colors.purple.shade600;
      case 'held':
        return Colors.indigo.shade600;
      default:
        return Colors.grey.shade600;
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor(table.status);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: statusColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Theme.of(context).colorScheme.primary : statusColor,
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
                child: Icon(Icons.check_circle, size: 18, color: Theme.of(context).colorScheme.primary),
              ),
          ],
        ),
      ),
    );
  }
}
