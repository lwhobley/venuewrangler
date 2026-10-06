import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/sign_out_service.dart';
import '../../../core/theme/ops_colors.dart';
import '../../venues/application/venues_providers.dart';

class _Item {
  const _Item(this.icon, this.label, this.route) : subtitle = null;

  final IconData icon;
  final String label;
  final String route;
  final String? subtitle;
}

const _sections = <(String, List<_Item>)>[
  (
    'Service',
    [
      _Item(Icons.event_seat_outlined, 'Reservations', '/reservations'),
      _Item(Icons.timer_outlined, 'Time clock', '/time-clock'),
      _Item(Icons.fact_check_outlined, 'Checklists', '/checklists'),
      _Item(Icons.report_outlined, 'Incidents', '/incidents'),
    ],
  ),
  (
    'Team',
    [
      _Item(Icons.chat_bubble_outline, 'Team chat', '/chat'),
      _Item(Icons.groups_outlined, 'Staff', '/workforce'),
      _Item(Icons.assignment_outlined, 'Staff requests', '/staff-requests'),
      _Item(Icons.lightbulb_outline, 'Shift insights', '/shift-insights'),
    ],
  ),
  (
    'Business',
    [
      _Item(Icons.event_outlined, 'Events', '/events'),
      _Item(Icons.inventory_2_outlined, 'Inventory', '/inventory'),
      _Item(Icons.handshake_outlined, 'CRM', '/crm'),
      _Item(Icons.folder_outlined, 'Documents', '/documents'),
      _Item(Icons.point_of_sale_outlined, 'POS', '/pos'),
    ],
  ),
  (
    'Account',
    [
      _Item(Icons.auto_awesome_outlined, 'Ask Wrangler', '/wrangler'),
      _Item(Icons.credit_card_outlined, 'Billing', '/billing'),
      _Item(Icons.extension_outlined, 'Integrations', '/integrations'),
      _Item(Icons.settings_outlined, 'Settings', '/settings'),
    ],
  ),
];

/// Routes registered under the More tab's branch in app/router.dart.
const _moreTabRoutes = {
  '/chat',
  '/inventory',
  '/events',
  '/crm',
  '/documents',
  '/pos',
  '/billing',
  '/integrations',
  '/settings',
};

/// Everything that isn't one of the four main tabs, grouped by what it's for.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final venue = ref.watch(activeVenueProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          for (final (title, items) in _sections) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Text(
                title.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.8),
              ),
            ),
            _Group(
              children: [
                for (final item in items)
                  ListTile(
                    leading: Icon(item.icon, color: theme.colorScheme.primary),
                    title: Text(item.label),
                    trailing: const Icon(Icons.chevron_right),
                    // Screens that belong to this tab are pushed so Back returns here;
                    // ones that live under another tab switch to that tab.
                    onTap: () => _moreTabRoutes.contains(item.route)
                        ? context.push(item.route)
                        : context.go(item.route),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          _Group(
            children: [
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Switch venue'),
                subtitle: venue == null ? null : Text(venue.name),
                onTap: () =>
                    ref.read(activeVenueProvider.notifier).state = null,
              ),
              ListTile(
                leading: Icon(Icons.logout, color: context.ops.danger.fg),
                title: Text(
                  'Sign out',
                  style: TextStyle(color: context.ops.danger.fg),
                ),
                onTap: () => signOutAndClearScopedData(ref),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.ops.panelBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(height: 1, indent: 56, color: context.ops.panelBorder),
            children[i],
          ],
        ],
      ),
    );
  }
}
